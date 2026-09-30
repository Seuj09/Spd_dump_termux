#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include "proto.h"
#include "dumpcmd.h"

#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

volatile sig_atomic_t spd_interrupted = 0;

/* SIGINT/SIGTERM: set a flag and return. Everything unsafe to call from a
 * signal handler (libusb, fprintf) happens later, at a checkpoint the caller
 * already visits between tries/chunks — never here. A second signal restores
 * the default action, so a stuck loop can still be force-killed by hitting
 * Ctrl-C twice. */
static void on_interrupt(int sig)
{
	spd_interrupted = 1;
	signal(sig, SIG_DFL);
}

static void install_signal_handlers(void)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_interrupt;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = 0; /* no SA_RESTART: let a blocked syscall return EINTR */
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
}

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
"  env TERMUX_USB_FD / SPD_USB_FD  same as --usb-fd when unset\n"
		"  --vid/--pid         desktop enumeration (default 1782:4d00)\n"
		"  --timeout MS        bulk timeout (default 1000)\n"
		"  --step N            partition chunk size, decimal or 0x hex\n"
		"                      (default 4096; 0xf800 after an fdl at 0x5500 or\n"
		"                      0x65000800, like spd_dump's highspeed blk_size)\n"
		"  --keep-going        a failed read-part is logged and the next command\n"
		"                      runs; exit status is 1 and failures are listed\n"
		"  --no-line-state     skip the smartphone line-state control transfer\n"
		"  --yes               do not prompt before write-part / erase-part / reboot-*\n"
		"  --verbose\n"
		"  --self-test         framing check, no device\n"
		"  --dry-run           no USB: fake ACK/VER replies, print each packet\n"
		"                      (DRY <cmd> addr/len) to stdout; for sequence tests\n"
		"\n"
		"Commands, run in order on the same connection:\n"
		"  ping [--fdl]                 BootROM hello, or FDL hello with --fdl\n"
		"  exec_addr ADDR [FILE]        BootROM stage only, before the first fdl:\n"
		"                               send FDL1 (START/MIDST/END), then FILE at\n"
		"                               ADDR (START/MIDST, no END, no EXEC) so the\n"
		"                               no-verify stub starts FDL1 (spd_dump's\n"
		"                               exec_addr). FILE defaults to\n"
		"                               fdl/ums9230/custom_exec_no_verify_<hex>.bin\n"
		"                               next to spdhost. ADDR 0 disables.\n"
		"  fdl FILE ADDR                send one loader and execute it\n"
		"  parts [FILE]                 list partitions (FILE or '-' optional)\n"
		"  read-part NAME OFF SIZE OUT\n"
		"  dump all|all_lite|NAME DIR   after parts, same session: size from the\n"
		"                               live table (units -> bytes like spd_dump),\n"
		"                               slot from misc, splloader 256K in all*,\n"
		"                               skips blackbox/cache/userdata. Writes\n"
		"                               DIR/NAME.img (failed: NAME.img.partial),\n"
		"                               DIR/dump-manifest.txt. Keeps going.\n"
		"  misc-backup FILE             read all of misc to FILE and check it;\n"
		"                               a later misc write in this session is\n"
		"                               then read back and verified. Failure\n"
		"                               stops the session before any write.\n"
		"  write-part NAME FILE\n"
		"  erase-part NAME\n"
		"  chip-uid\n"
		"  reboot-recovery            write 2048-byte BCB to misc, then reset\n"
		"  reboot-fastboot            same with --fastboot recovery arg\n"
		"  reset\n"
		"  power-off\n"
		"\n"
		"ADDR, OFF and SIZE accept a 0x hex prefix and a K/M/G suffix.\n"
		"The first fdl talks to BootROM (CRC-16). A second fdl talks to FDL1\n"
		"(additive checksum). Loaders and addresses must match that exact chip.\n"
		"This tree ships one example pair under fdl/ums9230/infinix/; a wrong\n"
		"pair or address can brick the phone.\n"
		"\n"
		"reboot-recovery and reboot-fastboot synthesize a 2048-byte Android\n"
		"bootloader_message (boot-recovery at offset 0; fastbootd also puts\n"
		"recovery\\n--fastboot\\n at 0x40), write exactly those 2048 bytes to\n"
		"partition \"misc\", then reset. Do not erase misc; do not write more\n"
		"than 2048 at offset 0 (A/B bootloader_control starts at 0x800).\n"
		"\n"
		"If the phone resets USB after a loader starts, spdhost asks termux-usb\n"
		"for a new descriptor (or scans again on the desktop) and continues\n"
		"the handshake. A reset in the middle of read-part or write-part stops\n"
		"that command. ping --fdl marks the link as already in FDL1, so the\n"
		"next fdl sends the second loader.\n");
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
	if (yes) {
		fprintf(stderr, "confirmed via --yes: %s '%s'\n", verb, name);
		return;
	}
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

static void need_fdl2(struct spd *io, const char *cmd)
{
	if (io->fdl_stage < 2) {
		fprintf(stderr,
			"%s requires FDL2 (fdl_stage >= 2); run two fdl commands first (now at stage %d)\n",
			cmd, io->fdl_stage);
		exit(1);
	}
}

static int is_command(const char *s)
{
	return strcmp(s, "ping") == 0 || strcmp(s, "fdl") == 0 ||
		strcmp(s, "exec_addr") == 0 ||
		strcmp(s, "parts") == 0 || strcmp(s, "read-part") == 0 ||
		strcmp(s, "write-part") == 0 || strcmp(s, "erase-part") == 0 ||
		strcmp(s, "chip-uid") == 0 ||
		strcmp(s, "reboot-recovery") == 0 || strcmp(s, "reboot-fastboot") == 0 ||
		strcmp(s, "reset") == 0 || strcmp(s, "dump") == 0 ||
		strcmp(s, "misc-backup") == 0 ||
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
		if (!io->linked) {
			if (line && spd_usb_line_state(&io->usb))
				exit(1);
			if (line)
				spd_brom_after_line_state(io);
			/* nbytes==1: BootROM path; tries arg ignored (SPDHOST_BROM_*). */
			if (spd_check_baud(io, 1, 4))
				exit(1);
			if (spd_connect(io))
				exit(1);
			io->linked = 1;
		}
		spd_send_loader(io, path, addr);
		if (io->exec_addr) {
			/* spd_dump non-v2 exec_addr: stub at exec_addr, no END, no EXEC. */
			spd_send_exec_file(io, io->exec_file, io->exec_addr);
		} else if (spd_exec(io, io->usb.timeout_ms > 3000 ? io->usb.timeout_ms : 3000, 0)) {
			exit(1);
		}
		io->flags &= ~SPD_F_CRC16;
		if (spd_check_baud_loader(io))
			exit(1);
		if (spd_connect(io))
			exit(1);
		io->fdl_stage = 1;
		io->linked = 1;
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
	if (line)
		spd_brom_after_line_state(io);
	if (fdl) {
		if (spd_check_baud_loader(io))
			exit(1);
	} else if (spd_check_baud(io, 1, 4)) {
		/* nbytes==1 BootROM; tries arg ignored (SPDHOST_BROM_*). */
		exit(1);
	}
	if (spd_connect(io))
		exit(1);
	io->linked = 1;
	if (fdl)
		io->fdl_stage = 1;
}


/* Android bootloader_message: first 0x800 bytes of misc. A/B metadata @0x800. */
enum { SPD_MISC_BCB_LEN = 0x800 };

/* kind: 0 = recovery only, 1 = recovery + --fastboot at 0x40. */
static int do_reboot_bcb(struct spd *io, int yes, int kind)
{
	uint8_t buf[SPD_MISC_BCB_LEN];
	const char *label = kind ? "misc (reboot-fastboot)" : "misc (reboot-recovery)";

	/* Compile-time guard: never enlarge this write window. */
	_Static_assert(sizeof(buf) == 0x800, "misc BCB must be exactly 2048 bytes");

	memset(buf, 0, sizeof(buf));
	memcpy(buf, "boot-recovery", 13);
	if (kind)
		memcpy(buf + 0x40, "recovery\n--fastboot\n", 20);

	confirm(yes, kind ? "reboot-fastboot via" : "reboot-recovery via", label);
	if (sizeof(buf) != (size_t)SPD_MISC_BCB_LEN) {
		fprintf(stderr, "internal error: misc BCB length %zu != 2048\n", sizeof(buf));
		return -1;
	}
	{
		/* spd_dump reboot-* uses w_mem_to_part_offset(..., 0x1000): the
		 * chunk is 0x1000 whatever blk_size/--step is (one 2048-byte MIDST). */
		int saved = io->step, rc;
		io->step = 0x1000;
		rc = spd_write_part_buf(io, "misc", buf, sizeof(buf));
		io->step = saved;
		if (rc)
			return -1;
	}
	if (spd_misc_guard_armed() && spd_misc_verify(io, buf, sizeof(buf))) {
		fprintf(stderr, "misc read-back mismatch: NOT resetting. Restore misc from the backup.\n");
		return -1;
	}
	return spd_simple(io, 0x05); /* BSL_CMD_NORMAL_RESET */
}

/* Default stub for exec_addr ADDR: custom_exec_no_verify_<hex>.bin (lowercase,
 * no 0x, same name spd_dump builds with "%x"). Look package-relative first
 * (next to the spdhost binary), then the current directory. Returns a static
 * buffer or NULL. */
static const char *find_exec_file(const char *self_path, uint32_t addr)
{
	static char out[1024];
	char name[64], dir[512];
	const char *slash;
	const char *rel[] = {
		"%s/fdl/ums9230/%s",
		"%s/../fdl/ums9230/%s",
		NULL
	};
	int k;

	snprintf(name, sizeof(name), "custom_exec_no_verify_%x.bin", (unsigned)addr);
	slash = strrchr(self_path, '/');
	if (slash) {
		size_t n = (size_t)(slash - self_path);
		if (n >= sizeof(dir))
			n = sizeof(dir) - 1;
		memcpy(dir, self_path, n);
		dir[n] = 0;
		for (k = 0; rel[k]; k++) {
			snprintf(out, sizeof(out), rel[k], dir, name);
			if (access(out, R_OK) == 0)
				return out;
		}
	}
	snprintf(out, sizeof(out), "fdl/ums9230/%s", name);
	if (access(out, R_OK) == 0)
		return out;
	snprintf(out, sizeof(out), "%s", name);
	if (access(out, R_OK) == 0)
		return out;
	return NULL;
}

int main(int argc, char **argv)
{
	static const struct option opts[] = {
		{"usb-fd", required_argument, NULL, 'f'},
		{"vid", required_argument, NULL, 'V'},
		{"pid", required_argument, NULL, 'P'},
		{"timeout", required_argument, NULL, 't'},
		{"step", required_argument, NULL, 's'},
		{"keep-going", no_argument, NULL, 'k'},
		{"verbose", no_argument, NULL, 'v'},
		{"yes", no_argument, NULL, 'y'},
		{"no-line-state", no_argument, NULL, 'L'},
		{"self-test", no_argument, NULL, 'T'},
		{"dry-run", no_argument, NULL, 'D'},
		{"help", no_argument, NULL, 'h'},
		{NULL, 0, NULL, 0}
	};
	int fd = -1, verbose = 0, yes = 0, line = 1, selftest = 0, dry = 0, keep_going = 0;
	char failed[1024] = "";
	int step_set = 0;
	int nfailed = 0;
	char self_path[512];
	int timeout = 1000, step = 4096;
	unsigned vid = 0x1782, pid = 0x4d00;
	int c, i;
	struct spd *io;
	const char *envfd;
	const char *emit;

	emit = getenv("SPDHOST_EMIT_SOCK");
	if (emit && emit[0])
		return spd_usb_emit_fd(emit); /* short helper process; no signal handling needed */

	install_signal_handlers();

	while ((c = getopt_long(argc, argv, "+h", opts, NULL)) != -1) {
		switch (c) {
		case 'f': {
			char *end = NULL;
			long v;
			errno = 0;
			v = strtol(optarg, &end, 10);
			if (end == optarg || *end || errno || v < 3 || v > 0x7fffffff) {
				fprintf(stderr, "bad --usb-fd: %s (need open FD >= 3)\n", optarg);
				return 2;
			}
			fd = (int)v;
			break;
		}
		case 'V':
			vid = (unsigned)strtoul(optarg, NULL, 0);
			break;
		case 'P':
			pid = (unsigned)strtoul(optarg, NULL, 0);
			break;
		case 't': {
			char *end = NULL;
			long v;
			errno = 0;
			v = strtol(optarg, &end, 10);
			if (end == optarg || *end || errno || v <= 0 || v > 600000) {
				fprintf(stderr, "bad --timeout: %s (need 1..600000 ms)\n", optarg);
				return 2;
			}
			timeout = (int)v;
			break;
		}
		case 's': {
			char *end = NULL;
			unsigned long v;
			errno = 0;
			v = strtoul(optarg, &end, 0);
			if (end == optarg || *end || errno || v < 64 || v > 65024) {
				fprintf(stderr, "bad --step: %s (need 64..65024, e.g. 4096 or 0xf800)\n", optarg);
				return 2;
			}
			step = (int)v;
			step_set = 1;
			break;
		}
		case 'k':
			keep_going = 1;
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
		case 'D':
			dry = 1;
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
	if ((!envfd || !envfd[0]) && (envfd = getenv("SPD_USB_FD")) && envfd[0])
		; /* fall through: SPD_USB_FD aliases TERMUX_USB_FD for non-Termux hosts */
	if (fd < 0 && envfd && envfd[0]) {
		char *end = NULL;
		long v;
		errno = 0;
		v = strtol(envfd, &end, 10);
		if (end == envfd || *end || errno || v < 3 || v > 0x7fffffff) {
			fprintf(stderr, "bad TERMUX_USB_FD/SPD_USB_FD: %s (need open FD >= 3)\n", envfd);
			return 2;
		}
		fd = (int)v;
	}

	if (step < 64 || step > 65024) {
		fprintf(stderr, "--step must be between 64 and 65024\n");
		return 2;
	}

	io = spd_new(verbose, step);
	io->usb.timeout_ms = timeout;
	{
		ssize_t n = readlink("/proc/self/exe", self_path, sizeof(self_path) - 1);
		if (n < 0)
			snprintf(self_path, sizeof(self_path), "%s", argv[0]);
		else
			self_path[n] = 0;
	}
	if (dry) {
		/* No USB at all: spd_send/spd_recv short-circuit on io->dry, and
		 * line-state / clear_halt (control transfers) are skipped. */
		io->dry = 1;
		line = 0;
		fprintf(stderr, "dry-run: no USB; packet sequence on stdout\n");
	} else {
		spd_usb_open(&io->usb, fd, vid, pid, timeout);
		spd_usb_enable_reacquire(&io->usb, self_path);
	}

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
		} else if (strcmp(cmd, "exec_addr") == 0) {
			uint64_t ea;
			const char *file = NULL;
			need(argc, i, 1, "exec_addr");
			ea = parse_size(argv[i + 1]);
			if (ea > 0xffffffffull) {
				fprintf(stderr, "exec_addr does not fit in 32 bits\n");
				return 1;
			}
			if (i + 2 < argc && !is_command(argv[i + 2])) {
				file = argv[i + 2];
				i++;
			}
			i += 2;
			if (io->fdl_stage != 0) {
				/* spd_dump ignores exec_addr once FDL1 is loaded; so do we. */
				fprintf(stderr, "exec_addr: ignored (only valid before the first fdl)\n");
				continue;
			}
			if (ea == 0) {
				io->exec_addr = 0;
				io->exec_file = NULL;
				fprintf(stderr, "exec_addr: disabled (0)\n");
				continue;
			}
			if (!file)
				file = find_exec_file(self_path, (uint32_t)ea);
			if (!file || access(file, R_OK) != 0) {
				fprintf(stderr,
					"exec_addr 0x%x: custom_exec_no_verify_%x.bin not found%s%s\n"
					"  expected next to spdhost in fdl/ums9230/ (or pass FILE).\n"
					"  menu.sh: SPDHOST_EXEC_ADDR=0 disables exec_addr.\n",
					(unsigned)ea, (unsigned)ea,
					file ? ": " : "", file ? file : "");
				return 1;
			}
			io->exec_addr = (uint32_t)ea;
			io->exec_file = file;
			fprintf(stderr, "exec_addr: 0x%08x using %s\n", io->exec_addr, io->exec_file);
		} else if (strcmp(cmd, "fdl") == 0) {
			need(argc, i, 2, "fdl");
			{
				uint64_t addr = parse_size(argv[i + 2]);
				if (addr > 0xffffffffull) {
					fprintf(stderr, "fdl address does not fit in 32 bits\n");
					return 1;
				}
				do_fdl(io, line, argv[i + 1], (uint32_t)addr);
				/* spd_dump: FDL1 at 0x5500 / 0x65000800 sets highspeed, and
				 * after FDL2 blk_size = 0xf800 for partition reads/writes.
				 * Loader sends stay at 528 (spd_send_fdl caps the step). */
				if (!step_set && (addr == 0x5500 || addr == 0x65000800) && io->step != 0xf800) {
					io->step = 0xf800;
					if (verbose)
						fprintf(stderr, "step: 0xf800 (FDL1 at 0x%llx, like spd_dump highspeed; --step overrides)\n",
							(unsigned long long)addr);
				}
			}
			line = 0;
			i += 3;
		} else if (strcmp(cmd, "parts") == 0) {
			const char *out = NULL;
			need_fdl2(io, "parts");
			if (i + 1 < argc && !is_command(argv[i + 1])) {
				out = argv[i + 1];
				i++;
			}
			if (spd_list_parts(io, out))
				return 1;
			i++;
		} else if (strcmp(cmd, "read-part") == 0) {
			need(argc, i, 4, "read-part");
			need_fdl2(io, "read-part");
			if (spd_read_part(io, argv[i + 1], parse_size(argv[i + 2]),
				parse_size(argv[i + 3]), argv[i + 4])) {
				if (!keep_going)
					return 1;
				fprintf(stderr, "read-part %s FAILED; continuing (--keep-going)\n", argv[i + 1]);
				nfailed++;
				if (strlen(failed) + strlen(argv[i + 1]) + 2 < sizeof(failed)) {
					strcat(failed, " ");
					strcat(failed, argv[i + 1]);
				}
			}
			i += 5;
		} else if (strcmp(cmd, "dump") == 0) {
			need(argc, i, 2, "dump");
			need_fdl2(io, "dump");
			if (spd_dump(io, argv[i + 1], argv[i + 2])) {
				if (!keep_going)
					return 1;
				nfailed++;
				if (strlen(failed) + strlen(argv[i + 1]) + 8 < sizeof(failed)) {
					strcat(failed, " dump:");
					strcat(failed, argv[i + 1]);
				}
			}
			i += 3;
		} else if (strcmp(cmd, "misc-backup") == 0) {
			need(argc, i, 1, "misc-backup");
			need_fdl2(io, "misc-backup");
			if (spd_misc_backup(io, argv[i + 1]))
				return 1; /* never --keep-going past a failed backup */
			i += 2;
		} else if (strcmp(cmd, "write-part") == 0) {
			need(argc, i, 2, "write-part");
			need_fdl2(io, "write-part");
			confirm(yes, "write", argv[i + 1]);
			if (spd_write_part(io, argv[i + 1], argv[i + 2]))
				return 1;
			if (strcmp(argv[i + 1], "misc") == 0 && spd_misc_guard_armed()) {
				FILE *f = fopen(argv[i + 2], "rb");
				uint64_t cap = spd_misc_size(io);
				uint8_t *w = malloc(cap + 1);
				size_t n = (f && w) ? fread(w, 1, cap + 1, f) : 0;
				int vr = (n && n <= cap) ? spd_misc_verify(io, w, n) : -1;
				if (f)
					fclose(f);
				free(w);
				if (vr) {
					fprintf(stderr, "misc read-back mismatch: stopping (no reset). Restore misc from the backup.\n");
					return 1;
				}
			}
			i += 3;
		} else if (strcmp(cmd, "erase-part") == 0) {
			need(argc, i, 1, "erase-part");
			need_fdl2(io, "erase-part");
			confirm(yes, "erase", argv[i + 1]);
			if (spd_erase_part(io, argv[i + 1]))
				return 1;
			i += 2;
		} else if (strcmp(cmd, "chip-uid") == 0) {
			if (spd_chip_uid(io))
				return 1;
			i++;
		} else if (strcmp(cmd, "reboot-recovery") == 0) {
			need_fdl2(io, "reboot-recovery");
			if (do_reboot_bcb(io, yes, 0))
				return 1;
			i++;
			break;
		} else if (strcmp(cmd, "reboot-fastboot") == 0) {
			need_fdl2(io, "reboot-fastboot");
			if (do_reboot_bcb(io, yes, 1))
				return 1;
			i++;
			break;
		} else if (strcmp(cmd, "reset") == 0) {
			if (spd_simple(io, 0x05))
				return 1;
			i++;
			break; /* spd_dump: `if (!send_and_check(io)) break;` */
		} else if (strcmp(cmd, "power-off") == 0) {
			if (spd_simple(io, 0x17))
				return 1;
			i++;
			break;
		} else {
			fprintf(stderr, "unknown command: %s\n", cmd);
			return 2;
		}
	}
	if (i < argc)
		fprintf(stderr, "note: ignored after reset/power-off/reboot-*: %s ... (the device left FDL2)\n", argv[i]);

	if (!dry)
		spd_usb_close(&io->usb);
	spd_free(io);
	if (nfailed) {
		fprintf(stderr, "read-part failed (%d):%s\n", nfailed, failed);
		return 1;
	}
	return 0;
}
