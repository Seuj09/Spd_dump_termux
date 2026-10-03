#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include "proto.h"
#include "dumpcmd.h"
#include "writecmd.h"
#include "sha256.h"
#include "dhtb.h"
#include "pac.h"

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
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
		"  --yes               do not prompt before write / erase / repartition / reboot-*\n"
		"                      Does NOT authorize verity, frp-reset, or danger-erase.\n"
		"  --dangerous         authorize those three without a typed word. The menu\n"
		"                      never passes this. A terminal user types dangerous.\n"
		"  --confirm-token SHA256  authorize ONE misc write (reboot-*, write-part\n"
		"                      misc) whose exact bytes have this sha256; any\n"
		"                      other bytes are refused before sending. For a\n"
		"                      caller that already took a typed confirm.\n"
		"  --part-xml DIR      leave partition_<unixtime>.xml in DIR every time the\n"
		"                      partition table is read (spd_dump writes that file\n"
		"                      on every session; the menu points DIR at the dump\n"
		"                      folder). env SPDHOST_PART_XML_DIR when unset.\n"
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
		"  exec_addr2 ADDR [FILE]       the same, with the stub appended to FDL1's\n"
		"                               own download (zero filler, then the stub,\n"
		"                               one START, no END) for a BootROM that takes\n"
		"                               only one download (spd_dump's exec_addr2).\n"
		"  loadexec FILE                exec_addr taken from FILE's own name\n"
		"                               (custom_exec_no_verify_<hex>.bin); sends\n"
		"                               nothing and is BootROM stage only.\n"
		"  loadexec2 FILE               the same, in exec_addr2's one-download form.\n"
		"  fdl FILE ADDR                send one loader and execute it\n"
		"  loadfdl FILE                 the same, with ADDR read out of FILE's\n"
		"                               name: the last 0X (or 0x) in it.\n"
		"  parts [FILE]                 list partitions (FILE or '-' optional)\n"
		"  partition-list [FILE]        the same table as the XML repartition\n"
		"                               reads back, size in MiB, last row\n"
		"                               0xffffffff ('take the rest'). Dump it,\n"
		"                               edit it, feed it to repartition.\n"
		"  read-part NAME OFF SIZE OUT  SIZE may be - or full (or 0xffffffff) for\n"
		"                               the whole partition, like spd_dump read_part\n"
		"  print (or p)                 the live table as read, splloader 256KB\n"
		"                               first then one row per line in MiB, in\n"
		"                               spd_dump's own layout\n"
		"  read-parts FILE.xml [DIR]    spd_dump read_parts: every partition the\n"
		"                               list names into DIR/NAME.bin, in order.\n"
		"                               Skips userdata and names not in the table;\n"
		"                               splloader is 256 KiB; size 0xffffffff asks\n"
		"                               the device; the rest are MiB. DIR defaults\n"
		"                               to `path`, then the current directory.\n"
		"  check-part NAME              print 1 when the partition exists, 0 when\n"
		"                               it does not (a note on stderr), like\n"
		"                               spd_dump check_part. Needs parts.\n"
		"  part-size NAME               print the byte size from the live table,\n"
		"                               0 when absent, like spd_dump size_part /\n"
		"                               part_size. Needs parts.\n"
		"  dump all|all_lite|NAME DIR   after parts, same session: size from the\n"
		"                               live table (units -> bytes like spd_dump),\n"
		"                               slot from misc, splloader 256K in all*,\n"
		"                               skips blackbox/cache/userdata. Writes\n"
		"                               DIR/NAME.img (failed: NAME.img.partial),\n"
		"                               DIR/dump-manifest.txt. Keeps going.\n"
		"  dump preset_modem DIR        spd_dump r preset_modem: every l_* and nr_*\n"
		"                               row, plus misc when the device is A/B\n"
		"  dump preset_resign DIR       spd_dump r preset_resign: vbmeta, splloader,\n"
		"                               uboot, sml, trustos, teecfg, boot, recovery\n"
		"  misc-backup FILE             read all of misc to FILE and check it;\n"
		"                               a later misc write in this session is\n"
		"                               then read back and verified. Failure\n"
		"                               stops the session before any write.\n"
		"  write-part NAME FILE     one partition. misc is 2048 bytes or the\n"
		"                          whole partition. fixnv1 uses NV framing.\n"
		"                          A same-size NAME_bak is also written when\n"
		"                          the device is not A/B. Does not edit vbmeta.\n"
		"  wof NAME OFF FILE      spd_dump wof: put FILE into the partition at\n"
		"                         OFF. At OFF 0 the partition becomes exactly\n"
		"                         FILE; past 0 the whole partition is read to\n"
		"                         <NAME>.bin, patched, and written back. Not\n"
		"                         fixnv / runtimenv / userdata (spd_dump's own\n"
		"                         blacklist). Same confirm as write-part.\n"
		"  wov NAME OFF VALUE     the same with 4 bytes, little-endian, max\n"
		"                         0xffffffff (spd_dump wov).\n"
		"  firstmode MODE_ID      spd_dump firstmode: write MODE_ID + 0x53464D00\n"
		"                         at miscdata+0x2420 (the mode the device boots\n"
		"                         into). Reads miscdata whole if OFFSET is not 0,\n"
		"                         so it needs the partition table.\n"
		"  path [DIR]             where wof / wov / firstmode put the <NAME>.bin\n"
		"                         they build (default: the current directory).\n"
		"                         An explicit output path in read-part / dump /\n"
		"                         read_flash / read_mem is used exactly as given.\n"
		"  w-force NAME FILE       spd_dump w_force: rename the row to 'w_force'\n"
		"                          in a temporary table, write, then send the\n"
		"                          table back. Gets through where a plain write\n"
		"                          is refused, and is the one write that does not\n"
		"                          stop at the row's size. Never splloader or misc.\n"
		"  write-parts DIR         restore: every image in DIR (NAME.img), skip\n"
		"                          the inactive slot, then set the active slot.\n"
		"                          write-parts-a / write-parts-b force that slot\n"
		"                          when those files exist. Run parts first.\n"
		"                          super without metadata.img erases metadata.\n"
		"                          No w_force repartition.\n"
		"  write-files DIR         flash: every named image, including the\n"
		"                          inactive slot. Does not erase metadata and\n"
		"                          does not change the active slot.\n"
		"  repartition FILE.xml    replace the partition table from XML\n"
		"                          <Partition id=\"..\" size=\"..\"/>. Destructive.\n"
		"  set-active a|b          rewrite misc slot bytes (backup + verify)\n"
		"  pack-slot a|b IN OUT    offline: patch a misc image at offset 0x800\n"
		"  gen-spl-unlock IN OUT   offline: patch a dumped splloader into an\n"
		"                          unlock image (DHTB, aarch64). Ported from the\n"
		"                          release's x86-64 gen_spl-unlock so it runs here.\n"
		"  gen-spl-unlock-legacy IN OUT   the same for an older SoC generation\n"
		"  gen-fdl1-dl IN OUT      offline: patch an fdl1 for download mode\n"
		"  chsize IN OUT           offline: cut a DHTB image to its real size\n"
		"  unpac [-d DIR] {list|extract|check} FILE.pac [names]\n"
		"                          offline: read or extract a Spreadtrum .pac\n"
		"  The six offline tools open no USB and ignore the device options.\n"
		"  Unlike the release tools they never overwrite their input file.\n"
		"  read_flash ADDR OFF SIZE OUT  raw read by address, no partition\n"
		"                               table involved (spd_dump read_flash).\n"
		"                               All three are 32-bit; a bigger value is\n"
		"                               refused before anything is sent.\n"
		"  read_mem ADDR SIZE OUT  the same opcode for RAM (spd_dump read_mem:\n"
		"                          the address goes in the offset field).\n"
		"  erase_flash ADDR SIZE   raw erase by address (spd_dump erase_flash).\n"
		"                          --yes confirms it; it never names a partition,\n"
		"                          so erase-part's blacklist has nothing to match.\n"
		"  erase-part NAME         not persist, not splloader, not all\n"
		"  verity 0|1              DANGEROUS. Byte 0x7B of vbmeta (spd_dump):\n"
		"                          0 writes 0x01 (dm-verity off), 1 writes 0x00\n"
		"                          on each vbmeta* that exists. Not byte 0x78.\n"
		"                          Needs parts. Over 64MB is refused. --yes is not enough.\n"
		"  frp-reset OUT           DANGEROUS. Read all of persist to OUT, check\n"
		"                          the file size, then erase persist. A failed or\n"
		"                          short read does not erase. Needs parts.\n"
		"                          Over 512MB is refused.\n"
		"  danger-erase NAME       DANGEROUS. Only persist, persist_a, persist_b,\n"
		"                          splloader, splloader_bak. erase-part still refuses\n"
		"                          those names. --yes is not enough.\n"
		"  chip-uid\n"
		"  reboot-recovery            write 2048-byte BCB to misc, then reset\n"
		"  reboot-fastboot            same with --fastboot recovery arg\n"
		"  reset\n"
		"  power-off                  also accepted as poweroff (release menu)\n"
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

/* Scoped authorization from a caller that already took a typed confirm on
 * its own terminal (scripts/menu.sh): --confirm-token SHA256 authorizes ONE
 * write to partition "misc" whose exact bytes hash to SHA256. Nothing else. */
static const char *confirm_token;
static int confirm_token_used;

/* Read one line from FD (raw read(2), no stdio buffering). Returns bytes read
 * (0 = EOF), -1 on error. */
static int read_line_fd(int fd, char *buf, int cap)
{
	int n = 0;
	while (n < cap - 1) {
		char c;
		ssize_t r = read(fd, &c, 1);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return n ? n : (int)r;
		buf[n++] = c;
		if (c == '\n')
			break;
	}
	buf[n] = 0;
	return n;
}

static void put_fd(int fd, const char *s)
{
	size_t l = strlen(s);
	while (l) {
		ssize_t w = write(fd, s, l);
		if (w <= 0)
			return;
		s += w;
		l -= (size_t)w;
	}
}

/* Typed confirm when there is no --yes and no matching token. termux-usb -e
 * buffers the child's stdout/stderr until exit, so the prompt also goes
 * straight to the terminal: /dev/tty if it opens, else fd 0 when fd 0 is a
 * tty. The answer is read from stdin when it is a tty, else from /dev/tty.
 * Trailing CR/LF/space/tab are ignored ("yes\r\n" is yes).
 *
 * Returns 1 when confirmed, 0 when declined or unanswerable. Writes exit on 0
 * because a refused write must not go ahead; the read side (spd_confirm_read,
 * below) treats 0 as "skip this read", which is what spd_dump's check_confirm
 * returning false means to dump_partition(). */
static int confirm_ask(int yes, const char *verb, const char *name)
{
	char buf[64], prompt[256], hex[3 * 64 + 1];
	int in_fd = -1, out_fd = -1, tty = -1, n, k;
	if (yes) {
		fprintf(stderr, "confirmed via --yes: %s '%s'\n", verb, name);
		return 1;
	}
	tty = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
	if (isatty(STDIN_FILENO))
		in_fd = STDIN_FILENO;
	else if (tty >= 0)
		in_fd = tty;
	if (in_fd < 0) {
		fprintf(stderr, "spdhost: refusing %s '%s' without --yes/--confirm-token"
			" (no terminal: stdin is not a tty and /dev/tty did not open)\n", verb, name);
		return 0;
	}
	out_fd = tty >= 0 ? tty : STDIN_FILENO;
	snprintf(prompt, sizeof(prompt), "spdhost: type yes to %s '%s': ", verb, name);
	put_fd(out_fd, prompt);
	fprintf(stderr, "%s(waiting for input on the terminal)\n", prompt);
	n = read_line_fd(in_fd, buf, sizeof(buf));
	if (tty >= 0)
		close(tty);
	hex[0] = 0;
	for (k = 0; k < n && k < 64; k++)
		snprintf(hex + 3 * k, 4, "%02x ", (unsigned char)buf[k]);
	if (n > 0) {
		int l = n;
		while (l > 0 && (buf[l - 1] == '\n' || buf[l - 1] == '\r' || buf[l - 1] == ' ' || buf[l - 1] == '\t'))
			l--;
		buf[l] = 0;
		if (strcmp(buf, "yes") == 0) {
			fprintf(stderr, "spdhost: confirmed: %s '%s'\n", verb, name);
			return 1;
		}
	}
	if (n > 0 && hex[0])
		hex[strlen(hex) - 1] = 0;
	fprintf(stderr, "spdhost: not confirmed (read: %s)\n", n > 0 ? hex : n == 0 ? "EOF" : strerror(errno));
	return 0;
}

/* A write is refused outright when the confirm says no. */
static void confirm(int yes, const char *verb, const char *name)
{
	if (!confirm_ask(yes, verb, name))
		exit(1);
}

/* spd_dump check_confirm() on the read side (dump_partition's "read userdata").
 * --yes passes it, as skip_confirm does there. A "no" is not an error: the
 * caller skips that read. */
int spd_confirm_read(int yes, const char *what)
{
	if (yes) {
		fprintf(stderr, "confirmed via --yes: read '%s'\n", what);
		return 1;
	}
	return confirm_ask(0, "read", what);
}

/* verity / frp-reset / danger-erase. --yes does not pass this gate.
 * --dangerous does (tests and a caller that already took the word). */
static int dangerous_ok;

static void confirm_dangerous(const char *what)
{
	char buf[64], prompt[320], hex[3 * 64 + 1];
	int in_fd = -1, out_fd = -1, tty = -1, n, k;

	if (dangerous_ok) {
		fprintf(stderr, "DANGEROUS confirmed via --dangerous: %s\n", what);
		return;
	}
	fprintf(stderr, "spdhost: DANGEROUS: %s. --yes does not authorize this.\n", what);
	tty = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
	if (isatty(STDIN_FILENO))
		in_fd = STDIN_FILENO;
	else if (tty >= 0)
		in_fd = tty;
	if (in_fd < 0) {
		fprintf(stderr, "spdhost: refusing %s without a terminal; nothing sent\n", what);
		exit(1);
	}
	out_fd = tty >= 0 ? tty : STDIN_FILENO;
	snprintf(prompt, sizeof(prompt), "spdhost: type dangerous to %s: ", what);
	put_fd(out_fd, prompt);
	fprintf(stderr, "%s(waiting for input on the terminal)\n", prompt);
	n = read_line_fd(in_fd, buf, sizeof(buf));
	if (tty >= 0)
		close(tty);
	hex[0] = 0;
	for (k = 0; k < n && k < 64; k++)
		snprintf(hex + 3 * k, 4, "%02x ", (unsigned char)buf[k]);
	if (n > 0) {
		int l = n;
		while (l > 0 && (buf[l - 1] == '\n' || buf[l - 1] == '\r' || buf[l - 1] == ' ' || buf[l - 1] == '\t'))
			l--;
		buf[l] = 0;
		if (strcmp(buf, "dangerous") == 0) {
			/* One typed word covers the rest of this process. The unlock
			 * session erases splloader and then splloader_bak; a second
			 * refusal would exit after the first erase. */
			dangerous_ok = 1;
			fprintf(stderr, "spdhost: DANGEROUS confirmed: %s\n", what);
			return;
		}
	}
	if (n > 0 && hex[0])
		hex[strlen(hex) - 1] = 0;
	fprintf(stderr, "spdhost: not confirmed (read: %s); nothing sent\n",
		n > 0 ? hex : n == 0 ? "EOF" : strerror(errno));
	exit(1);
}

/* Gate for a write of LEN bytes BUF to partition NAME. With --confirm-token:
 * only misc, only once, only these exact bytes; a mismatch refuses before
 * anything is sent. Without a token: --yes or the typed confirm. */
static void authorize_write(int yes, const char *verb, const char *name, const uint8_t *buf, size_t len)
{
	char got[65];
	if (!confirm_token) {
		confirm(yes, verb, name);
		return;
	}
	if (strcmp(name, "misc") != 0) {
		fprintf(stderr, "spdhost: --confirm-token only authorizes a misc write, not '%s'\n", name);
		confirm(yes, verb, name);
		return;
	}
	if (confirm_token_used) {
		fprintf(stderr, "spdhost: refusing a second misc write: --confirm-token authorizes one write per session\n");
		exit(1);
	}
	sha256_hex(buf, len, got);
	if (strcmp(got, confirm_token) != 0) {
		fprintf(stderr, "spdhost: confirm-token mismatch (expected %s, got %s); nothing written\n",
			confirm_token, got);
		exit(1);
	}
	confirm_token_used = 1;
	fprintf(stderr, "spdhost: confirm-token matches sha256 %s (%zu bytes to misc); authorized\n", got, len);
}

/* Whole file into memory (misc images are at most a few MiB). */
static uint8_t *load_small_file(const char *path, size_t *len, size_t cap)
{
	FILE *f = fopen(path, "rb");
	uint8_t *b;
	size_t n;
	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return NULL;
	}
	b = malloc(cap + 1);
	n = b ? fread(b, 1, cap + 1, f) : 0;
	fclose(f);
	if (!b || n == 0 || n > cap) {
		fprintf(stderr, "%s: %s\n", path, !b ? "out of memory" : n ? "too large for misc" : "empty");
		free(b);
		return NULL;
	}
	*len = n;
	return b;
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

/* The reference gates reset, reboot-recovery, reboot-fastboot and poweroff on
 * `if (!fdl1_loaded) { DBG_LOG("FDL NOT READY"); continue; }` (spd_dump.c:1303,
 * 1314, 1330, 1347) -- all four are FDL opcodes and none of them means anything
 * to a BootROM still waiting for a loader, so at stage 0 it does nothing at all.
 * We refuse instead of skipping: a reset that silently did not happen would let
 * the menu report success and leave the phone sitting in download mode. Stage 1
 * is enough, matching the reference, which treats fdl1_loaded == -1 (FDL2
 * executed) as loaded just the same. */
static void need_fdl1(struct spd *io, const char *cmd)
{
	if (io->fdl_stage < 1) {
		fprintf(stderr,
			"%s requires a loader (fdl_stage >= 1); run an fdl command first (now at stage %d)\n",
			cmd, io->fdl_stage);
		exit(1);
	}
}

/* The reference spells five verbs with an underscore where spdhost uses a
 * hyphen (`read_part`, `check_part`, `write_part`, `write_parts`,
 * `erase_part`). Both spellings are accepted so a command line copied out of
 * spd_dump's own documentation runs unchanged; the rest of the reference's
 * underscore names (read_parts, partition_list, size_part/part_size, w_force,
 * keep_charge, read_flash, read_mem, erase_flash) are already spelled that way
 * in the dispatch chain. Returns the canonical name, or NULL when S is
 * already one. */
static const char *cmd_alias(const char *s)
{
	static const struct { const char *ref, *ours; } tab[] = {
		{ "read_part", "read-part" },
		{ "check_part", "check-part" },
		{ "write_part", "write-part" },
		{ "write_parts", "write-parts" },
		{ "erase_part", "erase-part" },
	};
	size_t k;
	for (k = 0; k < sizeof(tab) / sizeof(tab[0]); k++)
		if (strcmp(s, tab[k].ref) == 0)
			return tab[k].ours;
	return NULL;
}

static int is_command(const char *s)
{
	const char *a = cmd_alias(s);
	if (a)
		s = a;
	return strcmp(s, "ping") == 0 || strcmp(s, "fdl") == 0 ||
		strcmp(s, "loadfdl") == 0 || strcmp(s, "exec_addr") == 0 ||
		strcmp(s, "exec_addr2") == 0 ||
		strcmp(s, "loadexec") == 0 || strcmp(s, "loadexec2") == 0 ||
		strcmp(s, "parts") == 0 || strcmp(s, "read-part") == 0 ||
		strcmp(s, "read-parts") == 0 || strcmp(s, "read_parts") == 0 ||
		strcmp(s, "print") == 0 || strcmp(s, "p") == 0 ||
		strcmp(s, "partition-list") == 0 || strcmp(s, "partition_list") == 0 ||
		strcmp(s, "check-part") == 0 ||
		strcmp(s, "part-size") == 0 || strcmp(s, "size_part") == 0 ||
		strcmp(s, "part_size") == 0 ||
		strcmp(s, "write-part") == 0 || strcmp(s, "w-force") == 0 ||
		strcmp(s, "w_force") == 0 || strcmp(s, "erase-part") == 0 ||
		strcmp(s, "wof") == 0 || strcmp(s, "wov") == 0 ||
		strcmp(s, "firstmode") == 0 || strcmp(s, "path") == 0 ||
		strcmp(s, "keep_charge") == 0 || strcmp(s, "keep-charge") == 0 ||
		strcmp(s, "read_flash") == 0 || strcmp(s, "read_mem") == 0 ||
		strcmp(s, "erase_flash") == 0 ||
		strcmp(s, "verity") == 0 || strcmp(s, "frp-reset") == 0 ||
		strcmp(s, "danger-erase") == 0 ||
		strcmp(s, "write-parts") == 0 || strcmp(s, "write-parts-a") == 0 ||
		strcmp(s, "write-parts-b") == 0 || strcmp(s, "write-files") == 0 ||
		strcmp(s, "repartition") == 0 ||
		strcmp(s, "set-active") == 0 || strcmp(s, "pack-slot") == 0 ||
		strcmp(s, "chip-uid") == 0 ||
		strcmp(s, "reboot-recovery") == 0 || strcmp(s, "reboot-fastboot") == 0 ||
		strcmp(s, "reset") == 0 || strcmp(s, "dump") == 0 ||
		strcmp(s, "misc-backup") == 0 ||
		strcmp(s, "power-off") == 0 || strcmp(s, "poweroff") == 0;
}

static int need(int argc, int i, int n, const char *what)
{
	if (i + n >= argc) {
		fprintf(stderr, "%s: missing argument\n", what);
		exit(1);
	}
	return 0;
}

/* Defined with the other command state, below: whether to send KEEP_CHARGE. */
static int keep_charge_on(void);

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
		if (io->exec_addr && io->exec_v2) {
			/* spd_dump exec_addr2/loadexec2: the stub rides along in the
			 * same download, behind zero filler. */
			spd_send_loader_appended(io, path, addr, io->exec_file, io->exec_addr);
		} else {
			spd_send_loader(io, path, addr);
			if (io->exec_addr) {
				/* spd_dump non-v2 exec_addr: stub at exec_addr, no END, no EXEC. */
				spd_send_exec_file(io, io->exec_file, io->exec_addr);
			} else if (spd_exec(io, io->usb.timeout_ms > 3000 ? io->usb.timeout_ms : 3000, 0)) {
				exit(1);
			}
		}
		io->flags &= ~SPD_F_CRC16;
		if (spd_check_baud_loader(io))
			exit(1);
		if (spd_connect(io))
			exit(1);
		/* spd_dump spd_dump.c:706 sends this right after the FDL1-stage
		 * CMD_CONNECT, and only there -- the loader is the one that holds
		 * the charger on while it flashes. A loader that refuses it still
		 * flashes: the reference only prints when it is taken. */
		if (keep_charge_on() && !spd_keep_charge(io))
			fprintf(stderr, "KEEP_CHARGE FDL1\n");
		io->fdl_stage = 1;
		io->linked = 1;
		fprintf(stderr, "FDL1 is running\n");
	} else if (io->fdl_stage == 1) {
		spd_send_loader(io, path, addr);
		if (spd_exec(io, 15000, 1))
			exit(1);
		io->fdl_stage = 2;
		fprintf(stderr, "FDL2 is running\n");
		/* spd_dump spd_dump.c:736-752, the two frames between the EXEC and
		 * the table read: the flash-info ask (a BSL_REP_READ_FLASH_INFO
		 * reply means NAND) and DISABLE_TRANSCODE if the loader's Da_Info
		 * asked for it. A device that ignores the ask is not fatal. */
		spd_flash_info(io);
		/* spd_dump's FDL2 stage ends by loading the partition table
		 * (spd_dump.c:753-771 -> partition_list), so from here on every
		 * command that names a partition has one, and the session has
		 * already written partition_<time>.xml. Ours does the same read at
		 * the same point; it just does not print the table, which is
		 * `print`'s job. A device that refuses one is not fatal here.
		 * NAND is the one case the reference skips: it has no SPRD table
		 * to read, and says so instead (spd_dump.c:772). */
		if (io->storage == SPD_STORAGE_NAND)
			fprintf(stderr, "Storage is nand\n");
		else
			spd_parts_ensure(io);
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

static int ensure_misc_backup(struct spd *io);

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

	authorize_write(yes, kind ? "reboot-fastboot via" : "reboot-recovery via", "misc", buf, sizeof(buf));
	/* One full-misc read, and only if this session has not already backed up.
	 * The menu's misc-backup arms the guard, so this does not read twice. */
	if (ensure_misc_backup(io))
		return -1;
	fprintf(stderr, "%s: writing %zu-byte BCB\n", label, sizeof(buf));
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
	if (spd_misc_verify(io, buf, sizeof(buf))) {
		fprintf(stderr, "misc read-back mismatch: NOT resetting. Restore misc from the backup.\n");
		return -1;
	}
	return spd_simple(io, 0x05); /* BSL_CMD_NORMAL_RESET */
}

/* Backup misc once per session before any misc write. The file lands in the
 * current directory so a bare reboot-* or write-part misc can be restored. */
static int ensure_misc_backup(struct spd *io)
{
	char path[64];
	time_t now;
	struct tm tm;
	if (spd_misc_guard_armed())
		return 0;
	now = time(NULL);
	if (!localtime_r(&now, &tm))
		return -1;
	snprintf(path, sizeof(path), "misc-before-%04d%02d%02d-%02d%02d%02d.img",
		tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
		tm.tm_hour, tm.tm_min, tm.tm_sec);
	fprintf(stderr, "misc: reading the partition into %s before writing\n", path);
	return spd_misc_backup(io, path);
}

static int have_part(struct spd *io, const char *name)
{
	int i;
	for (i = 0; i < io->nparts; i++)
		if (strcmp(io->ptab[i].name, name) == 0)
			return 1;
	return 0;
}

/* 2048-byte BCB or a full-partition misc image. Backup, write, read back.
 * gate=0 means the caller already confirmed this session (write-parts). */
static int write_misc_image(struct spd *io, int yes, const char *path, int gate)
{
	size_t n = 0;
	uint64_t full = spd_misc_size(io);
	uint8_t *w = load_small_file(path, &n, (size_t)full);
	int saved, rc;
	if (!w)
		return -1;
	if (n != SPD_MISC_BCB_LEN && n != full) {
		fprintf(stderr,
			"write misc: refusing %zu bytes (need %d for a BCB, or %llu for the whole partition)\n",
			n, SPD_MISC_BCB_LEN, (unsigned long long)full);
		free(w);
		return -1;
	}
	if (gate)
		authorize_write(yes, "write", "misc", w, n);
	if (ensure_misc_backup(io)) {
		free(w);
		return -1;
	}
	fprintf(stderr, "write misc: %zu bytes from %s\n", n, path);
	saved = io->step;
	if (n == SPD_MISC_BCB_LEN)
		io->step = 0x1000;
	rc = spd_write_part_buf(io, "misc", w, n);
	io->step = saved;
	if (rc) {
		free(w);
		return -1;
	}
	if (spd_misc_verify(io, w, n)) {
		free(w);
		fprintf(stderr, "misc read-back mismatch: stopping (no reset). Restore misc from the backup.\n");
		return -1;
	}
	free(w);
	return 0;
}

/* spd_dump set_active: 32-byte bootloader_control at misc+0x800, then the
 * whole misc image is written back. Backup and read-back stay in front. */
static int set_active_slot(struct spd *io, int yes, char which, int gate)
{
	uint64_t full;
	uint8_t *img, abc[32];
	if (which != 'a' && which != 'b') {
		fprintf(stderr, "set-active: want a or b\n");
		return -1;
	}
	if (io->nparts <= 0 || !have_part(io, "misc")) {
		fprintf(stderr, "set-active: run parts first (misc must be in the table)\n");
		return -1;
	}
	full = spd_misc_size(io);
	if (full < 0x820 || full > (uint64_t)SIZE_MAX) {
		fprintf(stderr, "set-active: misc size %llu is not usable\n", (unsigned long long)full);
		return -1;
	}
	img = malloc((size_t)full);
	if (!img)
		return -1;
	if (spd_read_part_mem(io, "misc", 0, full, img)) {
		free(img);
		return -1;
	}
	if (spd_fill_slot_abc(abc, which)) {
		free(img);
		return -1;
	}
	memcpy(img + 0x800, abc, 32);
	if (gate)
		authorize_write(yes, "set-active", "misc", img, (size_t)full);
	if (ensure_misc_backup(io)) {
		free(img);
		return -1;
	}
	fprintf(stderr, "set-active: slot %c (32 bytes at misc+0x800, %llu-byte rewrite)\n",
		which, (unsigned long long)full);
	if (spd_write_part_buf(io, "misc", img, (size_t)full)) {
		free(img);
		return -1;
	}
	if (spd_misc_verify(io, img, (size_t)full)) {
		free(img);
		fprintf(stderr, "misc read-back mismatch: slot was NOT confirmed. Restore misc from the backup.\n");
		return -1;
	}
	/* The write above dropped the cached slot; we know what it is now, so
	 * say so rather than spending three frames re-reading misc. */
	spd_slot_set(io, which == 'a' ? 1 : 2);
	free(img);
	return 0;
}

static int erase_refused(const char *name)
{
	if (!strcmp(name, "persist") || !strcmp(name, "persist_a") || !strcmp(name, "persist_b") ||
		!strcmp(name, "all") || !strcmp(name, "erase_all") ||
		!strcmp(name, "splloader") || !strcmp(name, "splloader_bak")) {
		fprintf(stderr,
			"erase-part: refusing '%s' (no persist erase, no erase-all, no splloader erase)\n",
			name);
		return 1;
	}
	return 0;
}

static int part_named(struct spd *io, const char *name)
{
	int i;
	if (!io || io->nparts <= 0)
		return 0;
	for (i = 0; i < io->nparts; i++)
		if (!strcmp(io->ptab[i].name, name))
			return 1;
	return 0;
}

/* The size of PATH in bytes, -1 when it cannot be read. */
static int file_size(const char *path, uint64_t *out)
{
	FILE *f;
	off_t n;
	f = fopen(path, "rb");
	if (!f)
		return -1;
	if (fseeko(f, 0, SEEK_END) != 0) {
		fclose(f);
		return -1;
	}
	n = ftello(f);
	fclose(f);
	if (n < 0)
		return -1;
	*out = (uint64_t)n;
	return 0;
}

/* `path [DIR]`: where a command that names its own output file puts it.
 * NULL means the current directory, which is what spd_dump's empty savepath
 * means. Read by wof / wov / firstmode. */
static const char *save_dir;

/* `keep_charge [0|1]`: spd_dump's own default is 1 (spd_dump.c:155), and the
 * command exists there to turn it off. Sentinel-initialised so the environment
 * can still override the default, the way the other transport knobs work. */
static int keep_charge = -1;

static int keep_charge_on(void)
{
	if (keep_charge >= 0)
		return keep_charge;
	{
		const char *v = getenv("SPDHOST_NO_KEEP_CHARGE");
		return !(v && v[0] && strcmp(v, "0") != 0);
	}
}

/* write-part NAME FILE, and the tail of wof / wov / firstmode, which build the
 * same kind of image file and then flash it. Every write confirm is here, so
 * no path into a partition can skip the one write-part takes. */
static int do_write_part(struct spd *io, int yes, const char *name, const char *path)
{
	int part_slot;
	if (strcmp(name, "misc") == 0)
		return write_misc_image(io, yes, path, 1);
	authorize_write(yes, "write", name, NULL, 0);
	part_slot = io->nparts > 0 ? spd_active_slot(io) : 0;
	return spd_write_named(io, name, path, part_slot);
}

static int same_file_size(const char *path, uint64_t expect)
{
	FILE *f;
	off_t n;
	f = fopen(path, "rb");
	if (!f)
		return -1;
	if (fseeko(f, 0, SEEK_END) != 0) {
		fclose(f);
		return -1;
	}
	n = ftello(f);
	fclose(f);
	if (n < 0)
		return -1;
	return (uint64_t)n == expect ? 0 : -1;
}

/* Backup persist, then erase it. A short or failed read leaves the partition. */
static int frp_reset(struct spd *io, const char *out)
{
	char resolved[40];
	uint64_t sz = 0;
	int slot, lk;

	if (!io || io->nparts <= 0) {
		fprintf(stderr, "frp-reset: run parts first; nothing sent\n");
		return -1;
	}
	slot = spd_active_slot(io);
	lk = spd_lookup_part(io, "persist", slot, resolved, sizeof(resolved), &sz);
	if (lk != 0 || sz == 0) {
		fprintf(stderr, "frp-reset: persist is not in the live table; nothing sent\n");
		return -1;
	}
	/* The read streams to a file. The cap only stops a corrupt table from
	 * filling the disk. A normal persist image is well under this. */
	if (sz > (512ull << 20)) {
		fprintf(stderr, "frp-reset: %s is %llu bytes, over the 512MB cap; nothing erased\n",
			resolved, (unsigned long long)sz);
		return -1;
	}
	fprintf(stderr, "DANGEROUS frp-reset: reading %s (%llu bytes) to %s, then erasing it\n",
		resolved, (unsigned long long)sz, out);
	if (spd_read_part(io, resolved, 0, sz, out)) {
		fprintf(stderr, "frp-reset: read failed; %s was not erased\n", resolved);
		return -1;
	}
	if (same_file_size(out, sz)) {
		fprintf(stderr, "frp-reset: %s size does not match %llu; %s was not erased\n",
			out, (unsigned long long)sz, resolved);
		return -1;
	}
	if (spd_erase_part(io, resolved)) {
		fprintf(stderr, "frp-reset: erase of %s failed; backup is %s\n", resolved, out);
		return -1;
	}
	fprintf(stderr, "DANGEROUS frp-reset: erased %s after backup %s\n", resolved, out);
	return 0;
}

static int danger_erase(struct spd *io, const char *name)
{
	int persist, spl, listed;

	persist = !strcmp(name, "persist") || !strcmp(name, "persist_a") || !strcmp(name, "persist_b");
	spl = !strcmp(name, "splloader") || !strcmp(name, "splloader_bak");
	if (!persist && !spl) {
		fprintf(stderr,
			"danger-erase: refusing '%s' (only persist, persist_a, persist_b, splloader, splloader_bak); nothing sent\n",
			name);
		return -1;
	}
	listed = part_named(io, name);
	if (persist && !listed) {
		fprintf(stderr, "danger-erase: %s is not in the live table; nothing sent\n", name);
		return -1;
	}
	if (spl && io->nparts > 0 && !listed)
		fprintf(stderr, "danger-erase: %s is not in the live table; erasing that name anyway\n", name);
	fprintf(stderr, "DANGEROUS erase: %s\n", name);
	return spd_erase_part(io, name);
}

static int run_write_plan(struct spd *io, int yes, const char *dir, int force_ab, int flash_each)
{
	struct spd_op *ops;
	int n = 0, k;
	confirm(yes, flash_each ? "write each named image from" : "write all partitions from", dir);
	ops = spd_plan_writes(io, dir, force_ab, flash_each, &n);
	if (!ops)
		return -1;
	for (k = 0; k < n; k++) {
		if (ops[k].kind == SPD_OP_WRITE && !strcmp(ops[k].name, "misc")) {
			if (write_misc_image(io, yes, ops[k].path, 0)) {
				free(ops);
				return -1;
			}
		} else if (ops[k].kind == SPD_OP_WRITE) {
			int part_slot = ops[k].slot == 'a' ? 1 : ops[k].slot == 'b' ? 2 : 0;
			if (spd_write_named(io, ops[k].name, ops[k].path, part_slot)) {
				free(ops);
				return -1;
			}
		} else if (ops[k].kind == SPD_OP_ERASE_METADATA) {
			fprintf(stderr, "write-parts: erasing metadata\n");
			if (spd_erase_part(io, "metadata")) {
				free(ops);
				return -1;
			}
		} else if (ops[k].kind == SPD_OP_SET_SLOT) {
			if (set_active_slot(io, yes, ops[k].slot, 0)) {
				free(ops);
				return -1;
			}
		}
	}
	free(ops);
	return 0;
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
		{"dangerous", no_argument, NULL, 'G'},
		{"confirm-token", required_argument, NULL, 'C'},
		{"part-xml", required_argument, NULL, 'X'},
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
	int interrupted_stop = 0;
	char self_path[512];
	int timeout = 1000, step = 4096;
	unsigned vid = 0x1782, pid = 0x4d00;
	int c, i;
	struct spd *io;
	const char *envfd;
	const char *emit;
	const char *part_xml_dir = NULL;

	/* --part-xml wins, but the env var is how the menu configures it for a
	 * whole run. Both are taken verbatim, so an empty value (--part-xml ""
	 * or SPDHOST_PART_XML_DIR=) means "do not write it" rather than falling
	 * through to the other source. */
	part_xml_dir = getenv("SPDHOST_PART_XML_DIR");
	emit = getenv("SPDHOST_EMIT_SOCK");
	if (emit && emit[0])
		/* short helper process; no signal handling needed. argv[1] is the
		 * legacy termux-usb fd form — see spd_usb_emit_fd(). */
		return spd_usb_emit_fd(emit, argc > 1 ? argv[1] : NULL);

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
		case 'G':
			dangerous_ok = 1;
			break;
		case 'C': {
			size_t k;
			for (k = 0; optarg[k]; k++)
				if (!((optarg[k] >= '0' && optarg[k] <= '9') || (optarg[k] >= 'a' && optarg[k] <= 'f')))
					break;
			if (k != 64 || optarg[k]) {
				fprintf(stderr, "bad --confirm-token: need 64 lowercase hex (sha256 of the misc bytes)\n");
				return 2;
			}
			confirm_token = optarg;
			break;
		}
		case 'X':
			/* A folder, not a file: the name carries the timestamp, as
			 * spd_dump's partition_<unixtime>.xml does. An empty value
			 * turns the copy off, which is what the env fallback lets a
			 * caller do. */
			part_xml_dir = optarg;
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
	if (selftest) {
		/* FIPS 180-4 vectors for the --confirm-token hash. */
		char h[65];
		sha256_hex((const uint8_t *)"abc", 3, h);
		if (strcmp(h, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) {
			fprintf(stderr, "self-test: sha256(abc) wrong: %s\n", h);
			return 1;
		}
		sha256_hex((const uint8_t *)"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, h);
		if (strcmp(h, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")) {
			fprintf(stderr, "self-test: sha256(448-bit) wrong: %s\n", h);
			return 1;
		}
		{
			/* Bytes spd_dump set_active writes at misc+0x800 (packed bootloader_control). */
			static const uint8_t slot_a[32] = {
				0x5f,0x61,0x00,0x00,0x42,0x43,0x41,0x42,0x01,0x02,0x00,0x00,0x6f,0x00,0x1e,0x00,
				0,0,0,0,0,0,0,0,0,0,0,0,0xe6,0xbf,0xea,0xc5
			};
			static const uint8_t slot_b[32] = {
				0x5f,0x62,0x00,0x00,0x42,0x43,0x41,0x42,0x01,0x02,0x00,0x00,0x1e,0x00,0x6f,0x00,
				0,0,0,0,0,0,0,0,0,0,0,0,0x9e,0xe2,0x10,0x70
			};
			uint8_t abc[32];
			if (spd_fill_slot_abc(abc, 'a') || memcmp(abc, slot_a, 32) ||
				spd_fill_slot_abc(abc, 'b') || memcmp(abc, slot_b, 32)) {
				fprintf(stderr, "self-test: set-active slot block differs from spd_dump\n");
				return 1;
			}
		}
		/* Pure computation over synthetic buffers: the header math and the
		 * three patch patterns, and the PAC CRC the extractor reports. */
		if (spd_dhtb_selftest() || spd_pac_selftest())
			return 1;
		return spd_selftest();
	}
	if (optind < argc && strcmp(argv[optind], "pack-slot") == 0) {
		if (optind + 3 >= argc || (argv[optind + 1][0] != 'a' && argv[optind + 1][0] != 'b') ||
			argv[optind + 1][1]) {
			fprintf(stderr, "pack-slot a|b IN OUT\n");
			return 2;
		}
		return spd_pack_slot_file(argv[optind + 1][0], argv[optind + 2], argv[optind + 3]) ? 1 : 0;
	}
	/* Offline image tools. No USB, so they run before a device is required
	 * (same place as pack-slot above). Each is IN OUT and writes only OUT:
	 * the release tools remove and rename over their INPUT, so running
	 * `gen_spl-unlock splloader.bin` destroys the dump it is patching. */
	{
		static const struct {
			const char *name;
			int (*fn)(const char *, const char *);
		} tools[] = {
			{ "gen-spl-unlock", spd_gen_spl_unlock },
			{ "gen-spl-unlock-legacy", spd_gen_spl_unlock_legacy },
			{ "gen-fdl1-dl", spd_gen_fdl1_dl },
			{ "chsize", spd_dhtb_chsize },
		};
		size_t t;
		for (t = 0; t < sizeof(tools) / sizeof(tools[0]); t++) {
			if (optind >= argc || strcmp(argv[optind], tools[t].name) != 0)
				continue;
			if (optind + 2 >= argc) {
				fprintf(stderr, "%s IN OUT\n", tools[t].name);
				return 2;
			}
			return tools[t].fn(argv[optind + 1], argv[optind + 2]) ? 1 : 0;
		}
	}
	if (optind < argc && strcmp(argv[optind], "unpac") == 0) {
		if (optind + 1 >= argc) {
			fprintf(stderr, "unpac [-d dir] {list|extract|check} firmware.pac [names]\n");
			return 2;
		}
		return spd_pac_main(argc - optind, argv + optind) ? 1 : 0;
	}
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
	io->part_xml_dir = part_xml_dir;
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
		{
			/* spd_dump's underscores, folded to spdhost's hyphens. */
			const char *a = cmd_alias(cmd);
			if (a)
				cmd = a;
		}
		/* An interrupt stops the run whether or not --keep-going is set.
		 * That flag covers a command that failed on its own; an interrupted
		 * one left the transfer half done, so the next command in the
		 * sequence would go to a loader still waiting for the rest of it. */
		if (spd_interrupted) {
			fprintf(stderr, "interrupted; stopping before '%s'\n", cmd);
			interrupted_stop = 1;
			break;
		}
		if (strcmp(cmd, "ping") == 0) {
			int fdl = 0;
			if (i + 1 < argc && strcmp(argv[i + 1], "--fdl") == 0) {
				fdl = 1;
				i++;
			}
			do_ping(io, line, fdl);
			line = 0;
			i++;
		} else if (strcmp(cmd, "exec_addr") == 0 || strcmp(cmd, "exec_addr2") == 0) {
			/* exec_addr2 (spd_dump.c:819) is exec_addr plus the flag that
			 * makes the stub ride along in FDL1's own download instead of
			 * starting a second one. */
			uint64_t ea;
			const char *file = NULL;
			int v2 = cmd[9] == '2';
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
			io->exec_v2 = v2;
			fprintf(stderr, "exec_addr%s: 0x%08x using %s\n", v2 ? "2" : "",
				io->exec_addr, io->exec_file);
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
		} else if (strcmp(cmd, "loadfdl") == 0) {
			/* spd_dump loadfdl FILE: `fdl FILE addr` with the address taken
			 * from the file's own name. It is the LAST "0X" in the name, or
			 * the last "0x" when there is no upper-case one, and the rest of
			 * that string is the hex address -- so
			 * fdl2-dl_0x9efffe00.bin loads at 0x9efffe00. Nothing is
			 * special-cased: a name with no 0x is refused, as in spd_dump. */
			const char *p, *last = NULL;
			uint64_t addr;
			need(argc, i, 1, "loadfdl");
			for (p = argv[i + 1]; (p = strstr(p, "0X")) != NULL; p += 2)
				last = p;
			if (!last)
				for (p = argv[i + 1]; (p = strstr(p, "0x")) != NULL; p += 2)
					last = p;
			if (!last) {
				fprintf(stderr, "loadfdl: \"0x\" not found in name of %s\n", argv[i + 1]);
				return 1;
			}
			/* spd_dump: `addr = strtoul(last_pos, NULL, 16)`. Base 16
			 * eats the "0x" itself and stops at the first character
			 * that is not a hex digit, so fdl2-dl_0x9efffe00.bin and
			 * fdl2-dl_0x9efffe00 both mean 0x9efffe00 -- a file name
			 * with an extension is not a special case there, and must
			 * not be one here. A name whose last 0x has no digits at
			 * all parses as 0, as it does in the reference. */
			errno = 0;
			addr = strtoul(last, NULL, 16);
			if (errno == ERANGE || addr > 0xffffffffull) {
				fprintf(stderr, "loadfdl: address in %s does not fit in 32 bits\n", last);
				return 1;
			}
			do_fdl(io, line, argv[i + 1], (uint32_t)addr);
			if (!step_set && (addr == 0x5500 || addr == 0x65000800) && io->step != 0xf800) {
				io->step = 0xf800;
				if (verbose)
					fprintf(stderr, "step: 0xf800 (FDL1 at 0x%llx, like spd_dump highspeed; --step overrides)\n",
						(unsigned long long)addr);
			}
			line = 0;
			i += 2;
		} else if (strcmp(cmd, "loadexec") == 0 || strcmp(cmd, "loadexec2") == 0) {
			/* spd_dump loadexec FILE: exec_addr with the address read out of
			 * the file's own name (custom_exec_no_verify_<hex>.bin), and the
			 * file remembered as the stub. It sends nothing and is BootROM
			 * stage only, exactly like exec_addr. A name it cannot read an
			 * address from, or a file that is not there, disables exec_addr
			 * rather than failing the run -- which is what the reference does
			 * (it prints "does not exist" and sets exec_addr = 0).
			 * loadexec2 is the same command plus the same-download flag
			 * (spd_dump.c:839). */
			const char *base;
			char straddr[9] = { 0 };
			uint32_t ea = 0;
			int v2 = cmd[8] == '2';
			need(argc, i, 1, "loadexec");
			base = strrchr(argv[i + 1], '/');
			base = base ? base + 1 : argv[i + 1];
			if (sscanf(base, "custom_exec_no_verify_%8[0-9a-fA-F]", straddr) == 1)
				ea = (uint32_t)strtoul(straddr, NULL, 16);
			i += 2;
			if (io->fdl_stage != 0) {
				fprintf(stderr, "loadexec: ignored (only valid before the first fdl); current exec_addr is 0x%x\n",
					(unsigned)io->exec_addr);
				continue;
			}
			io->exec_file = argv[i - 1];
			if (!ea) {
				fprintf(stderr, "loadexec: no custom_exec_no_verify_<hex> address in %s\n", base);
				ea = 0;
			} else if (access(argv[i - 1], R_OK) != 0) {
				fprintf(stderr, "loadexec: %s does not exist\n", argv[i - 1]);
				ea = 0;
			}
			io->exec_addr = ea;
			io->exec_v2 = v2;
			fprintf(stderr, "current exec_addr is 0x%x\n", (unsigned)io->exec_addr);
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
			uint64_t rsize, rnamesz = 0, roff;
			char rnamebuf[40], ralt[40];
			const char *rname = argv[i + 1];
			need(argc, i, 4, "read-part");
			need_fdl2(io, "read-part");
			/* spd_dump read_part treats size 0xffffffff as "whole partition";
			 * here `-` and `full` mean the same, plus a numeric 0xffffffff.
			 * The words are matched first: parse_size() errors on them. */
			if (!strcmp(argv[i + 3], "-") || !strcmp(argv[i + 3], "full")) {
				rsize = 0xffffffffu;
			} else {
				rsize = parse_size(argv[i + 3]);
			}
			/* spd_dump resolves the name through get_partition_info first and
			 * dumps the result, so `boot` reads `boot_a` on a slot-a phone.
			 * A name the table does not know still reads with an explicit
			 * size (spdhost's older behaviour); only a magic size needs it. */
			if (spd_resolve_part(io, rname, rnamebuf, sizeof(rnamebuf), &rnamesz) == 0) {
				rname = rnamebuf;
				if (rsize == 0xffffffffu) {
					/* spd_dump read_part: `if (0xffffffff == size) size =
					 * check_partition(io, gPartInfo.name, 1);` -- the
					 * device sizes it, not the table. splloader is the
					 * one name where the table has no row to probe with:
					 * it is a raw offset, so it keeps its fixed 256 KiB
					 * (documented divergence: the reference refuses the
					 * name outright). A device that will not answer falls
					 * back to the row's own size. */
					uint64_t probed = 0;
					if (strncmp(rname, "splloader", 9))
						probed = spd_check_partition(io, rname, 1,
							spd_active_slot(io));
					rsize = probed ? probed : rnamesz;
				}
			} else if (rsize == 0xffffffffu) {
				fprintf(stderr, "read-part: no size for '%s' in the live table; "
					"run parts first or give an explicit size\n", rname);
				if (!keep_going)
					return 1;
				nfailed++;
				i += 5;
				continue;
			}
			/* spd_dump dump_partition's nv rule, which read_part goes
			 * through too: an `<x>1...` name with "nv1" in it reads its
			 * `<x>2...` twin starting at 512, size less 512. It overrides
			 * the offset and size given on the command line, as the
			 * reference's own dump_partition does -- so the command line's
			 * offset is kept unless the name was one (spd_nv_read_adjust
			 * leaves *OFF at 0, and ALT untouched, for every other name). */
			roff = parse_size(argv[i + 2]);
			{
				uint64_t nvoff = 0;
				spd_nv_read_adjust(rname, ralt, sizeof(ralt), &nvoff, &rsize);
				if (nvoff) {
					rname = ralt;
					roff = nvoff;
					fprintf(stderr, "read-part: %s -> %s at offset %llu, %llu bytes\n",
						argv[i + 1], rname, (unsigned long long)roff,
						(unsigned long long)rsize);
				}
			}
			/* spd_dump dump_partition's userdata rule: the read asks first. */
			if (spd_userdata_declined(rname, yes)) {
				i += 5;
				continue;
			}
			/* and its super rule: metadata first, sized by the device. */
			if (!strcmp(rname, "super"))
				spd_metadata_beside(io, argv[i + 4], spd_active_slot(io));
			if (spd_read_part(io, rname, roff, rsize, argv[i + 4])) {
				if (!keep_going)
					return 1;
				/* The loop-top check stops the run on the next iteration, so
				 * promising to continue here would contradict it. */
				if (spd_interrupted)
					fprintf(stderr, "read-part %s FAILED; interrupted\n", argv[i + 1]);
				else
					fprintf(stderr, "read-part %s FAILED; continuing (--keep-going)\n", argv[i + 1]);
				nfailed++;
				if (strlen(failed) + strlen(argv[i + 1]) + 2 < sizeof(failed)) {
					strcat(failed, " ");
					strcat(failed, argv[i + 1]);
				}
			}
			i += 5;
		} else if (strcmp(cmd, "check-part") == 0) {
			/* spd_dump check_part prints 0/1 -- "Checks if the specified
			 * partition exists" (README.md:177, spd_dump.c:925 with
			 * need_size=0). The byte count is part-size, below. */
			uint64_t sz;
			need(argc, i, 1, "check-part");
			sz = spd_check_part(io, argv[i + 1]);
			printf("%d\n", sz ? 1 : 0);
			if (!sz)
				fprintf(stderr, "check-part: '%s' is not in the live table\n", argv[i + 1]);
			i += 2;
		} else if (strcmp(cmd, "part-size") == 0 || strcmp(cmd, "size_part") == 0 ||
			strcmp(cmd, "part_size") == 0) {
			uint64_t sz;
			need(argc, i, 1, cmd);
			sz = spd_check_part(io, argv[i + 1]);
			printf("%llu\n", (unsigned long long)sz);
			if (!sz)
				fprintf(stderr, "%s: '%s' is not in the live table\n", cmd, argv[i + 1]);
			i += 2;
		} else if (strcmp(cmd, "print") == 0 || strcmp(cmd, "p") == 0) {
			/* spd_dump p|print: the table this session already read, in the
			 * reference's own layout -- splloader first at its fixed
			 * 256 KiB, then one row per line, MiB to the nearest whole. */
			int k;
			if (io->nparts > 0) {
				printf("  0 %36s     256KB\n", "splloader");
				for (k = 0; k < io->nparts; k++)
					printf("%3d %36s %7lluMB\n", k + 1, io->ptab[k].name,
						(unsigned long long)(io->ptab[k].size >> 20));
			}
			i++;
		} else if (strcmp(cmd, "read-parts") == 0 || strcmp(cmd, "read_parts") == 0) {
			/* spd_dump read_parts FILE [DIR]: every partition the XML list
			 * names, into DIR/NAME.bin. DIR defaults to the `path`
			 * directory (or the current one). */
			const char *dir, *xml;
			int named = 0;
			need(argc, i, 1, "read-parts");
			need_fdl2(io, "read-parts");
			/* The list is argv[i+1] and the optional DIR argv[i+2]; the list
			 * is taken before I moves, because after it the DIR sits at
			 * argv[i+1] and would be read as the XML. */
			xml = argv[i + 1];
			if (i + 2 < argc && !is_command(argv[i + 2])) {
				dir = argv[i + 2];
				named = 1;
				i++;
			} else {
				dir = save_dir && save_dir[0] ? save_dir : ".";
				/* spd_dump's savepath[0] test: `path DIR` counts as named,
				 * so the dump list is copied into it. */
				named = save_dir && save_dir[0] ? 1 : 0;
			}
			if (spd_read_parts(io, xml, dir, named))
				return 1;
			i += 2;
		} else if (strcmp(cmd, "dump") == 0) {
			need(argc, i, 2, "dump");
			need_fdl2(io, "dump");
			if (spd_dump(io, argv[i + 1], argv[i + 2], yes)) {
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
			if (do_write_part(io, yes, argv[i + 1], argv[i + 2]))
				return 1;
			i += 3;
		} else if (strcmp(cmd, "wof") == 0 || strcmp(cmd, "wov") == 0) {
			/* spd_dump wof NAME OFFSET FILE / wov NAME OFFSET VALUE: patch
			 * a small region of a partition by writing the whole image (the
			 * phone has no partial write), through the same write confirm as
			 * write-part. The reference blacklists fixnv/runtimenv/userdata
			 * inside w_mem_to_part_offset(), which is where we do it too. */
			char img[1200];
			uint8_t val[4];
			const uint8_t *mem;
			size_t len;
			uint64_t off, flen = 0;
			int slot, wov = strcmp(cmd, "wov") == 0;

			need(argc, i, 3, cmd);
			need_fdl2(io, cmd);
			off = parse_size(argv[i + 2]);
			if (wov) {
				unsigned long long v;
				errno = 0;
				v = strtoull(argv[i + 3], NULL, 0);
				if (errno || v > 0xffffffffull) {
					fprintf(stderr, "wov: value %s is not a 32-bit number\n", argv[i + 3]);
					return 1;
				}
				/* spd_dump memcpy()s the host uint32_t, so the file gets
				 * the value little-endian; spelled out here rather than
				 * copied so it does not depend on the host. */
				val[0] = (uint8_t)v;
				val[1] = (uint8_t)(v >> 8);
				val[2] = (uint8_t)(v >> 16);
				val[3] = (uint8_t)(v >> 24);
				mem = val;
				len = 4;
			} else {
				FILE *f;
				if (file_size(argv[i + 3], &flen)) {
					fprintf(stderr, "%s: cannot read %s\n", cmd, argv[i + 3]);
					return 1;
				}
				if (flen > 256ull * 1024 * 1024) {
					fprintf(stderr, "%s: %s is %llu bytes; over the 256 MB"
						" in-memory patch limit\n", cmd, argv[i + 3],
						(unsigned long long)flen);
					return 1;
				}
				mem = malloc(flen ? (size_t)flen : 1);
				if (!mem) {
					fprintf(stderr, "%s: out of memory for %s\n", cmd, argv[i + 3]);
					return 1;
				}
				f = fopen(argv[i + 3], "rb");
				if (!f || (flen && fread((void *)mem, 1, (size_t)flen, f) != flen)) {
					fprintf(stderr, "%s: read %s failed\n", cmd, argv[i + 3]);
					if (f)
						fclose(f);
					free((void *)mem);
					return 1;
				}
				fclose(f);
				len = (size_t)flen;
			}
			slot = io->nparts > 0 ? spd_active_slot(io) : 0;
			if (spd_mem_to_part_file(io, argv[i + 1], off, mem, len, save_dir, slot,
				    img, sizeof(img))) {
				if (!wov)
					free((void *)mem);
				return 1;
			}
			if (!wov)
				free((void *)mem);
			if (do_write_part(io, yes, argv[i + 1], img))
				return 1;
			i += 4;
		} else if (strcmp(cmd, "firstmode") == 0) {
			/* spd_dump firstmode mode_id: 4 bytes at miscdata+0x2420,
			 * the mode the device boots into (mode_id + 0x53464D00).
			 * The reference drives the whole thing at its 0x1000 step,
			 * whatever blk_size says. */
			char img[1200];
			uint8_t modebuf[4];
			uint64_t mode;
			int slot, saved = io->step, rc;

			need(argc, i, 1, "firstmode");
			need_fdl2(io, "firstmode");
			mode = parse_size(argv[i + 1]) + 0x53464D00ull;
			if (mode > 0xffffffffull) {
				fprintf(stderr, "firstmode: mode_id + 0x53464D00 does not fit in 32 bits\n");
				return 1;
			}
			modebuf[0] = (uint8_t)mode;
			modebuf[1] = (uint8_t)(mode >> 8);
			modebuf[2] = (uint8_t)(mode >> 16);
			modebuf[3] = (uint8_t)(mode >> 24);
			io->step = 0x1000;
			slot = io->nparts > 0 ? spd_active_slot(io) : 0;
			rc = spd_mem_to_part_file(io, "miscdata", 0x2420, modebuf, 4, save_dir, slot,
				img, sizeof(img));
			if (!rc)
				rc = do_write_part(io, yes, "miscdata", img);
			io->step = saved;
			if (rc)
				return 1;
			i += 2;
		} else if (strcmp(cmd, "path") == 0) {
			/* spd_dump path [save_location]: where a command that names
			 * its own output file puts it. Ours is the image wof / wov /
			 * firstmode build; an explicit output path (read-part, dump,
			 * read_flash, read_mem) is used exactly as given, because
			 * the menu passes absolute paths and the reference's my_fopen
			 * would silently replace the directory with savepath. */
			if (i + 1 < argc && !is_command(argv[i + 1])) {
				save_dir = argv[i + 1];
				i++;
			}
			fprintf(stderr, "save dir is %s\n", save_dir ? save_dir : ".");
			i++;
		} else if (strcmp(cmd, "keep_charge") == 0 || strcmp(cmd, "keep-charge") == 0) {
			/* spd_dump keep_charge {0,1} (spd_dump.c:1285). Takes effect
			 * on the next fdl, which is where the reference sends it. */
			if (i + 1 >= argc || is_command(argv[i + 1])) {
				fprintf(stderr, "keep_charge is %d\n", keep_charge_on());
			} else {
				keep_charge = atoi(argv[i + 1]) ? 1 : 0;
				i++;
			}
			i++;
		} else if (strcmp(cmd, "w-force") == 0 || strcmp(cmd, "w_force") == 0) {
			int part_slot;
			need(argc, i, 2, "w-force");
			need_fdl2(io, "w-force");
			/* Same write confirm as write-part: this is still a write. It
			 * is not in the menu (the reference menu has no w_force option
			 * either); it is the CLI escape hatch for a write the loader
			 * refuses by name. */
			authorize_write(yes, "w-force", argv[i + 1], NULL, 0);
			part_slot = io->nparts > 0 ? spd_active_slot(io) : 0;
			if (spd_write_force(io, argv[i + 1], argv[i + 2], part_slot))
				return 1;
			i += 3;
		} else if (strcmp(cmd, "write-parts") == 0 || strcmp(cmd, "write-parts-a") == 0 ||
			strcmp(cmd, "write-parts-b") == 0 || strcmp(cmd, "write-files") == 0) {
			int force = 0, flash = 0;
			need(argc, i, 1, cmd);
			need_fdl2(io, cmd);
			if (!strcmp(cmd, "write-files"))
				flash = 1;
			else if (!strcmp(cmd, "write-parts-a"))
				force = 1;
			else if (!strcmp(cmd, "write-parts-b"))
				force = 2;
			if (run_write_plan(io, yes, argv[i + 1], force, flash))
				return 1;
			i += 2;
		} else if (strcmp(cmd, "repartition") == 0) {
			need(argc, i, 1, "repartition");
			need_fdl2(io, "repartition");
			if (access(argv[i + 1], R_OK) != 0) {
				fprintf(stderr, "repartition: file does not exist: %s\n", argv[i + 1]);
				return 1;
			}
			confirm(yes, "repartition from", argv[i + 1]);
			if (spd_repartition_xml(io, argv[i + 1]))
				return 1;
			i += 2;
		} else if (strcmp(cmd, "partition-list") == 0 || strcmp(cmd, "partition_list") == 0) {
			const char *out = NULL;
			need_fdl2(io, "partition-list");
			if (i + 1 < argc && !is_command(argv[i + 1])) {
				out = argv[i + 1];
				i++;
			}
			if (spd_part_xml(io, out))
				return 1;
			i++;
		} else if (strcmp(cmd, "set-active") == 0) {
			need(argc, i, 1, "set-active");
			need_fdl2(io, "set-active");
			if ((argv[i + 1][0] != 'a' && argv[i + 1][0] != 'b') || argv[i + 1][1]) {
				fprintf(stderr, "set-active: want a or b\n");
				return 1;
			}
			if (set_active_slot(io, yes, argv[i + 1][0], 1))
				return 1;
			i += 2;
		} else if (strcmp(cmd, "erase-part") == 0) {
			need(argc, i, 1, "erase-part");
			need_fdl2(io, "erase-part");
			if (erase_refused(argv[i + 1]))
				return 1;
			confirm(yes, "erase", argv[i + 1]);
			if (spd_erase_part(io, argv[i + 1]))
				return 1;
			i += 2;
		} else if (strcmp(cmd, "read_flash") == 0) {
			/* spd_dump read_flash addr offset size FILE: a raw read by
			 * address, for areas the partition table does not name.
			 * 32-bit fields, hence the limit message from proto.c. */
			int saved = io->step, rc;
			need(argc, i, 4, "read_flash");
			need_fdl2(io, "read_flash");
			/* spd_dump calls dump_flash with `blk_size ? blk_size : 1024`
			 * -- a different default from dump_partition's 0x1000, so
			 * an unset --step must put the same 1024-byte requests on
			 * the wire (the same temporary override exec_addr makes for
			 * its 0x1000 stub chunks). */
			if (!step_set)
				io->step = 1024;
			rc = spd_dump_flash(io, parse_size(argv[i + 1]), parse_size(argv[i + 2]),
				parse_size(argv[i + 3]), argv[i + 4]);
			io->step = saved;
			if (rc)
				return 1;
			i += 5;
		} else if (strcmp(cmd, "read_mem") == 0) {
			/* The same opcode with the address put in the offset field
			 * and a zero address (spd_dump dump_mem), and the same 1024
			 * default step. */
			int saved = io->step, rc;
			need(argc, i, 3, "read_mem");
			need_fdl2(io, "read_mem");
			if (!step_set)
				io->step = 1024;
			rc = spd_dump_mem(io, parse_size(argv[i + 1]), parse_size(argv[i + 2]), argv[i + 3]);
			io->step = saved;
			if (rc)
				return 1;
			i += 4;
		} else if (strcmp(cmd, "erase_flash") == 0) {
			/* Raw erase by address. The reference asks check_confirm
			 * ("erase flash") unless skip_confirm is on; --yes is our
			 * equivalent of that flag and nothing more. It cannot name
			 * persist or splloader -- it does not know about partitions
			 * at all -- so the erase-part blacklist does not apply. */
			need(argc, i, 2, "erase_flash");
			need_fdl2(io, "erase_flash");
			confirm(yes, "erase flash at", argv[i + 1]);
			if (spd_erase_flash(io, parse_size(argv[i + 1]), parse_size(argv[i + 2])))
				return 1;
			i += 3;
		} else if (strcmp(cmd, "verity") == 0) {
			char what[64];
			need(argc, i, 1, "verity");
			need_fdl2(io, "verity");
			if (strcmp(argv[i + 1], "0") != 0 && strcmp(argv[i + 1], "1") != 0) {
				fprintf(stderr, "verity: want 0 (disable) or 1 (enable)\n");
				return 1;
			}
			snprintf(what, sizeof(what), "%s verity (vbmeta byte 0x7b)",
				argv[i + 1][0] == '0' ? "disable" : "enable");
			confirm_dangerous(what);
			if (spd_verity(io, argv[i + 1][0] == '1'))
				return 1;
			i += 2;
		} else if (strcmp(cmd, "frp-reset") == 0) {
			need(argc, i, 1, "frp-reset");
			need_fdl2(io, "frp-reset");
			confirm_dangerous("reset FRP (backup persist, then erase it)");
			if (frp_reset(io, argv[i + 1]))
				return 1;
			i += 2;
		} else if (strcmp(cmd, "danger-erase") == 0) {
			char what[80];
			need(argc, i, 1, "danger-erase");
			need_fdl2(io, "danger-erase");
			snprintf(what, sizeof(what), "erase %s", argv[i + 1]);
			confirm_dangerous(what);
			if (danger_erase(io, argv[i + 1]))
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
			need_fdl1(io, "reset");
			if (spd_simple(io, 0x05))
				return 1;
			i++;
			break; /* spd_dump: `if (!send_and_check(io)) break;` */
		} else if (strcmp(cmd, "power-off") == 0 || strcmp(cmd, "poweroff") == 0) {
			need_fdl1(io, "power-off");
			if (spd_simple(io, 0x17))
				return 1;
			i++;
			break;
		} else {
			fprintf(stderr, "unknown command: %s\n", cmd);
			return 2;
		}
	}
	if (i < argc && !interrupted_stop)
		fprintf(stderr, "note: ignored after reset/power-off/reboot-*: %s ... (the device left FDL2)\n", argv[i]);

	if (!dry)
		spd_usb_close(&io->usb);
	spd_free(io);
	if (interrupted_stop)
		return 1;
	if (nfailed) {
		fprintf(stderr, "read-part failed (%d):%s\n", nfailed, failed);
		return 1;
	}
	return 0;
}
