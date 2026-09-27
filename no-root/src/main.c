#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include "proto.h"

#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void usage(void)
{
	fprintf(stderr,
		"spdhost — Unisoc download-mode client (one USB device per run)\n"
		"\n"
		"Desktop:\n"
		"  spdhost [--vid 1782 --pid 4d00] <commands>\n"
		"Termux (fd comes from termux-usb -E):\n"
		"  spdhost-usb <commands>\n"
		"  spdhost --usb-fd \"$TERMUX_USB_FD\" <commands>\n"
		"\n"
		"Options:\n"
		"  --usb-fd N          adopt an already-open usbfs descriptor\n"
		"  --vid/--pid         desktop enumeration (default 1782:4d00)\n"
		"  --timeout MS        bulk timeout (default 1000)\n"
		"  --step N            partition chunk size (default 4096, max 65024)\n"
		"  --no-line-state     skip the smartphone line-state control transfer\n"
		"  --yes               do not prompt before write-part / erase-part\n"
		"  --verbose\n"
		"  --self-test         framing check, no device\n"
		"\n"
		"Commands, run in order on the same connection:\n"
		"  ping [--fdl]                 BootROM hello, or FDL hello with --fdl\n"
		"  fdl FILE ADDR                send one loader and execute it\n"
		"  parts [FILE]                 list partitions (FILE or '-' optional)\n"
		"  read-part NAME OFF SIZE OUT\n"
		"  write-part NAME FILE\n"
		"  erase-part NAME\n"
		"  chip-uid\n"
		"  reset\n"
		"  power-off\n"
		"\n"
		"ADDR, OFF and SIZE accept a 0x hex prefix and a K/M/G suffix.\n"
		"The first fdl talks to BootROM (CRC-16). A second fdl talks to FDL1\n"
		"(additive checksum). Loaders are files you already have. This program\n"
		"keeps a single file descriptor: if the phone resets USB, the run ends.\n");
}

static uint64_t parse_size(const char *str)
{
	char *end = NULL;
	unsigned long long n;
	int shift = 0;

	errno = 0;
	n = strtoull(str, &end, 0);
	if (end == str || errno)
		goto bad;
	if (*end) {
		if (strcmp(end, "K") == 0 || strcmp(end, "k") == 0)
			shift = 10;
		else if (strcmp(end, "M") == 0 || strcmp(end, "m") == 0)
			shift = 20;
		else if (strcmp(end, "G") == 0 || strcmp(end, "g") == 0)
			shift = 30;
		else
			goto bad;
	}
	if (shift && n > (~0ull >> shift))
		goto bad;
	return (uint64_t)(n << shift);
bad:
	fprintf(stderr, "bad size: %s\n", str);
	exit(1);
}

static void confirm(int yes, const char *verb, const char *name)
{
	char buf[16];
	if (yes)
		return;
	if (!isatty(STDIN_FILENO)) {
		fprintf(stderr, "refusing to %s %s without --yes (stdin is not a terminal)\n", verb, name);
		exit(1);
	}
	fprintf(stderr, "type yes to %s '%s': ", verb, name);
	fflush(stderr);
	if (!fgets(buf, sizeof(buf), stdin) || strcmp(buf, "yes\n") != 0) {
		fprintf(stderr, "not confirmed\n");
		exit(1);
	}
}

static int is_command(const char *s)
{
	return strcmp(s, "ping") == 0 || strcmp(s, "fdl") == 0 ||
		strcmp(s, "parts") == 0 || strcmp(s, "read-part") == 0 ||
		strcmp(s, "write-part") == 0 || strcmp(s, "erase-part") == 0 ||
		strcmp(s, "chip-uid") == 0 || strcmp(s, "reset") == 0 ||
		strcmp(s, "power-off") == 0;
}

static int need(int argc, int i, int n, const char *what)
{
	if (i + n >= argc) {
		fprintf(stderr, "%s: missing argument\n", what);
		exit(1);
	}
	return 0;
}

static void do_fdl(struct spd *io, int line, const char *path, uint32_t addr)
{
	if (io->fdl_stage == 0) {
		io->flags |= SPD_F_CRC16 | SPD_F_TRANSCODE;
		if (line && spd_usb_line_state(&io->usb))
			exit(1);
		if (spd_check_baud(io, 1, 4))
			exit(1);
		if (spd_connect(io))
			exit(1);
		spd_send_loader(io, path, addr);
		if (spd_exec(io, io->usb.timeout_ms > 3000 ? io->usb.timeout_ms : 3000, 0))
			exit(1);
		io->flags &= ~SPD_F_CRC16;
		if (spd_check_baud(io, 4, 10))
			exit(1);
		if (spd_connect(io))
			exit(1);
		io->fdl_stage = 1;
		fprintf(stderr, "FDL1 is running\n");
	} else if (io->fdl_stage == 1) {
		spd_send_loader(io, path, addr);
		if (spd_exec(io, 15000, 1))
			exit(1);
		io->fdl_stage = 2;
		fprintf(stderr, "FDL2 is running\n");
	} else {
		fprintf(stderr, "only two fdl stages are supported in one run\n");
		exit(1);
	}
}

static void do_ping(struct spd *io, int line, int fdl)
{
	io->flags |= SPD_F_TRANSCODE;
	if (fdl)
		io->flags &= ~SPD_F_CRC16;
	else
		io->flags |= SPD_F_CRC16;
	if (line && spd_usb_line_state(&io->usb))
		exit(1);
	if (spd_check_baud(io, fdl ? 4 : 1, 4))
		exit(1);
	if (spd_connect(io))
		exit(1);
}

int main(int argc, char **argv)
{
	static const struct option opts[] = {
		{"usb-fd", required_argument, NULL, 'f'},
		{"vid", required_argument, NULL, 'V'},
		{"pid", required_argument, NULL, 'P'},
		{"timeout", required_argument, NULL, 't'},
		{"step", required_argument, NULL, 's'},
		{"verbose", no_argument, NULL, 'v'},
		{"yes", no_argument, NULL, 'y'},
		{"no-line-state", no_argument, NULL, 'L'},
		{"self-test", no_argument, NULL, 'T'},
		{"help", no_argument, NULL, 'h'},
		{NULL, 0, NULL, 0}
	};
	int fd = -1, verbose = 0, yes = 0, line = 1, selftest = 0;
	int timeout = 1000, step = 4096;
	unsigned vid = 0x1782, pid = 0x4d00;
	int c, i;
	struct spd *io;
	const char *envfd;

	while ((c = getopt_long(argc, argv, "h", opts, NULL)) != -1) {
		switch (c) {
		case 'f':
			fd = atoi(optarg);
			break;
		case 'V':
			vid = (unsigned)strtoul(optarg, NULL, 0);
			break;
		case 'P':
			pid = (unsigned)strtoul(optarg, NULL, 0);
			break;
		case 't':
			timeout = atoi(optarg);
			break;
		case 's':
			step = atoi(optarg);
			break;
		case 'v':
			verbose = 1;
			break;
		case 'y':
			yes = 1;
			break;
		case 'L':
			line = 0;
			break;
		case 'T':
			selftest = 1;
			break;
		default:
			usage();
			return c == 'h' ? 0 : 2;
		}
	}
	if (selftest)
		return spd_selftest();
	if (optind >= argc) {
		usage();
		return 2;
	}

	envfd = getenv("TERMUX_USB_FD");
	if (fd < 0 && envfd && envfd[0])
		fd = atoi(envfd);

	if (step < 64 || step > 65024) {
		fprintf(stderr, "--step must be between 64 and 65024\n");
		return 2;
	}

	io = spd_new(verbose, step);
	io->usb.timeout_ms = timeout;
	spd_usb_open(&io->usb, fd, vid, pid, timeout);

	for (i = optind; i < argc; ) {
		const char *cmd = argv[i];
		if (strcmp(cmd, "ping") == 0) {
			int fdl = 0;
			if (i + 1 < argc && strcmp(argv[i + 1], "--fdl") == 0) {
				fdl = 1;
				i++;
			}
			do_ping(io, line, fdl);
			line = 0;
			i++;
		} else if (strcmp(cmd, "fdl") == 0) {
			need(argc, i, 2, "fdl");
			{
				uint64_t addr = parse_size(argv[i + 2]);
				if (addr > 0xffffffffull) {
					fprintf(stderr, "fdl address does not fit in 32 bits\n");
					return 1;
				}
				do_fdl(io, line, argv[i + 1], (uint32_t)addr);
			}
			line = 0;
			i += 3;
		} else if (strcmp(cmd, "parts") == 0) {
			const char *out = NULL;
			if (i + 1 < argc && !is_command(argv[i + 1])) {
				out = argv[i + 1];
				i++;
			}
			if (spd_list_parts(io, out))
				return 1;
			i++;
		} else if (strcmp(cmd, "read-part") == 0) {
			need(argc, i, 4, "read-part");
			if (spd_read_part(io, argv[i + 1], parse_size(argv[i + 2]),
				parse_size(argv[i + 3]), argv[i + 4]))
				return 1;
			i += 5;
		} else if (strcmp(cmd, "write-part") == 0) {
			need(argc, i, 2, "write-part");
			confirm(yes, "write", argv[i + 1]);
			if (spd_write_part(io, argv[i + 1], argv[i + 2]))
				return 1;
			i += 3;
		} else if (strcmp(cmd, "erase-part") == 0) {
			need(argc, i, 1, "erase-part");
			confirm(yes, "erase", argv[i + 1]);
			if (spd_erase_part(io, argv[i + 1]))
				return 1;
			i += 2;
		} else if (strcmp(cmd, "chip-uid") == 0) {
			if (spd_chip_uid(io))
				return 1;
			i++;
		} else if (strcmp(cmd, "reset") == 0) {
			if (spd_simple(io, 0x05))
				return 1;
			i++;
		} else if (strcmp(cmd, "power-off") == 0) {
			if (spd_simple(io, 0x17))
				return 1;
			i++;
		} else {
			fprintf(stderr, "unknown command: %s\n", cmd);
			return 2;
		}
	}

	spd_usb_close(&io->usb);
	spd_free(io);
	return 0;
}
