#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64

#include "proto.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define HDLC_MARK 0x7e
#define HDLC_ESC 0x7d
#define RECV_CAP 0x8000
#define RAW_CAP (4 + 0x10000 + 2)

#define BSL_CMD_CONNECT 0x00
#define BSL_CMD_START_DATA 0x01
#define BSL_CMD_MIDST_DATA 0x02
#define BSL_CMD_END_DATA 0x03
#define BSL_CMD_EXEC_DATA 0x04
#define BSL_CMD_NORMAL_RESET 0x05
#define BSL_CMD_READ_FLASH 0x06
#define BSL_CMD_ERASE_FLASH 0x0a
#define BSL_CMD_READ_FLASH_INFO 0x0d
#define BSL_CMD_DISABLE_TRANSCODE 0x21
#define BSL_CMD_REPARTITION 0x0b
#define BSL_CMD_KEEP_CHARGE 0x13
#define BSL_CMD_READ_START 0x10
#define BSL_CMD_READ_MIDST 0x11
#define BSL_CMD_READ_END 0x12
#define BSL_CMD_POWER_OFF 0x17
#define BSL_CMD_READ_CHIP_UID 0x1a
#define BSL_CMD_READ_PARTITION 0x2d
#define BSL_CMD_CHECK_BAUD 0x7e

#define BSL_REP_ACK 0x80
#define BSL_REP_VER 0x81
#define BSL_REP_READ_FLASH 0x93
#define BSL_REP_INCOMPATIBLE_PARTITION 0x96
#define BSL_REP_READ_FLASH_INFO 0x9b
#define BSL_REP_READ_CHIP_UID 0xab
#define BSL_REP_READ_PARTITION 0xba
#define BSL_REP_LOG 0xff

#define CHK_FIXZERO 1
#define CHK_ORIG 2

static void die(const char *msg)
{
	fprintf(stderr, "%s\n", msg);
	exit(1);
}

static void pause_ms(int ms)
{
	struct timespec ts;
	ts.tv_sec = ms / 1000;
	ts.tv_nsec = (long)(ms % 1000) * 1000000L;
	nanosleep(&ts, NULL);
}

/* Parse env ints; clamp to [lo, hi]. Junk/missing → def. */
static int env_int(const char *name, int def, int lo, int hi)
{
	const char *s;
	char *end = NULL;
	long v;

	s = getenv(name);
	if (!s || !*s)
		return def;
	errno = 0;
	v = strtol(s, &end, 10);
	if (errno || end == s || (end && *end))
		return def;
	if (v < lo)
		return lo;
	if (v > hi)
		return hi;
	return (int)v;
}

static long long mono_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static void wr16be(uint8_t *p, unsigned v)
{
	p[0] = (uint8_t)(v >> 8);
	p[1] = (uint8_t)v;
}

static void wr32be(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)v;
}

static void wr32le(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

static uint32_t rd32be(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
		((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static unsigned rd16be(const uint8_t *p)
{
	return ((unsigned)p[0] << 8) | p[1];
}

static uint32_t rd32le(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
		((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t rd64le(const uint8_t *p)
{
	return (uint64_t)rd32le(p) | ((uint64_t)rd32le(p + 4) << 32);
}

/* CRC-16/XMODEM, init 0. The BootROM uses this on the unescaped body. */
static unsigned crc16(const uint8_t *s, unsigned len)
{
	unsigned crc = 0;
	while (len--) {
		int i;
		crc ^= (unsigned)(*s++) << 8;
		for (i = 0; i < 8; i++)
			crc = (crc << 1) ^ ((0u - (crc >> 15)) & 0x11021u);
		crc &= 0xffffu;
	}
	return crc;
}

/* 16-bit additive checksum. final selects the byte-swap quirk:
 * CHK_FIXZERO swaps only when the body length was even,
 * CHK_ORIG always swaps. The phone checks the swapped form. */
static unsigned sum16(const uint8_t *s, int len, int final)
{
	unsigned crc = 0;
	int odd = len;
	while (len > 1) {
		crc += (unsigned)s[1] << 8 | s[0];
		s += 2;
		len -= 2;
	}
	if (len)
		crc += *s;
	if (final) {
		crc = (crc >> 16) + (crc & 0xffffu);
		crc += crc >> 16;
		crc = ~crc & 0xffffu;
		if ((odd & 1) < final)
			crc = (crc >> 8) | ((crc & 0xffu) << 8);
	}
	return crc;
}

static int escape(uint8_t *dst, const uint8_t *src, int len)
{
	int i, n = 0;
	for (i = 0; i < len; i++) {
		uint8_t a = src[i];
		if (a == HDLC_MARK || a == HDLC_ESC) {
			if (dst)
				dst[n] = HDLC_ESC;
			n++;
			a ^= 0x20;
		}
		if (dst)
			dst[n] = a;
		n++;
	}
	return n;
}

struct spd *spd_new(int verbose, int step)
{
	struct spd *io = calloc(1, sizeof(*io));
	if (!io)
		die("out of memory");
	io->verbose = verbose;
	io->step = step > 0 ? step : 4096;
	io->flags = SPD_F_TRANSCODE;
	/* spd_dump's `int selected_ab = -1`: "the device has not been asked yet".
	 * calloc's 0 would read as "asked, and the answer is not A/B". */
	io->slot_bcb = -1;
	/* spd_dump's `int gpt_failed = 1;` (spd_dump.c:144) -- same reasoning: the
	 * table has not been asked for yet. */
	io->ptab_state = 1;
	io->raw = malloc(RAW_CAP);
	io->enc = malloc(2 + RAW_CAP * 2);
	io->recv = malloc(RECV_CAP);
	io->temp = malloc(0x10000);
	if (!io->raw || !io->enc || !io->recv || !io->temp)
		die("out of memory");
	return io;
}

void spd_free(struct spd *io)
{
	if (!io)
		return;
	free(io->raw);
	free(io->enc);
	free(io->recv);
	free(io->temp);
	free(io->ptab);
	free(io);
}

static const char *cmd_name(unsigned type)
{
	switch (type) {
	case BSL_CMD_CONNECT: return "CONNECT";
	case BSL_CMD_START_DATA: return "START";
	case BSL_CMD_MIDST_DATA: return "MIDST";
	case BSL_CMD_END_DATA: return "END";
	case BSL_CMD_EXEC_DATA: return "EXEC";
	case BSL_CMD_CHECK_BAUD: return "CHECK_BAUD";
	default: return "CMD";
	}
}

/* FNV-1a over the encoded (HDLC-framed, escaped) bytes. The dry-run test
 * computes the same hash over what spd_dump's send_msg() hands to
 * libusb_bulk_transfer(), so a matching line means byte-identical frames. */
static uint32_t fnv1a(const uint8_t *p, int n)
{
	uint32_t h = 2166136261u;
	while (n-- > 0) {
		h ^= *p++;
		h *= 16777619u;
	}
	return h;
}

/* Dry-run trace: one line per packet that would go on the wire (cmd, addr,
 * len, frame hash), so a test can diff spdhost's sequence against spd_dump's
 * without USB hardware. Enabled by io->dry (--dry-run in main.c). */
static void dry_log(struct spd *io)
{
	unsigned type = (unsigned)io->last_type;
	uint32_t h = fnv1a(io->enc, io->enc_len);
	if (type == BSL_CMD_CHECK_BAUD) {
		printf("DRY CHECK_BAUD nbytes=%d fnv=%08x\n", io->enc_len, h);
	} else if (type == BSL_CMD_START_DATA && io->raw_len >= 4 + 8 + 2) {
		printf("DRY START addr=0x%08x len=%u fnv=%08x\n",
			rd32be(io->raw + 4), rd32be(io->raw + 8), h);
	} else if (type == BSL_CMD_MIDST_DATA) {
		printf("DRY MIDST len=%u fnv=%08x\n", rd16be(io->raw + 2), h);
	} else {
		printf("DRY %s fnv=%08x\n", cmd_name(type), h);
	}
	fflush(stdout);
}

void spd_encode(struct spd *io, unsigned type, const void *data, size_t len)
{
	uint8_t *p, *body;
	unsigned chk;
	size_t body_len;

	if (len > 0xffff)
		die("message too long");

	io->last_type = (int)type;
	if (type == BSL_CMD_CHECK_BAUD) {
		memset(io->enc, HDLC_MARK, len);
		io->enc_len = (int)len;
		io->raw_len = 0;
		return;
	}

	body = io->raw;
	wr16be(body, type);
	wr16be(body + 2, (unsigned)len);
	if (len && data)
		memcpy(body + 4, data, len);
	body_len = 4 + len;
	if (io->flags & SPD_F_CRC16)
		chk = crc16(body, (unsigned)body_len);
	else
		chk = sum16(body, (int)body_len, CHK_FIXZERO);
	wr16be(body + body_len, chk);
	body_len += 2;
	io->raw_len = (int)body_len;

	p = io->enc;
	*p++ = HDLC_MARK;
	if (io->flags & SPD_F_TRANSCODE)
		body_len = (size_t)escape(p, body, (int)body_len);
	else
		memcpy(p, body, body_len);
	p[body_len] = HDLC_MARK;
	io->enc_len = (int)body_len + 2;
}

int spd_send(struct spd *io)
{
	int rc;

	if (io->enc_len <= 0)
		die("empty message");
	if (io->dry) {
		dry_log(io);
		return io->enc_len; /* dry-run: nothing goes on the wire */
	}
	if (io->verbose)
		fprintf(stderr, "send %d bytes\n", io->enc_len);
	rc = spd_usb_bulk_send(&io->usb, io->enc, io->enc_len);
	if (rc < 0)
		return rc; /* -1 gone/disconnect; -2 TIMEOUT / other */
	return io->enc_len;
}

int spd_recv(struct spd *io, int timeout_ms)
{
	int esc, n, head, need, pos, len;

	if (io->dry && io->dry_drop_ack) {
		io->dry_drop_ack = 0;
		io->raw_len = 0;
		printf("DRY (no ack)\n");
		fflush(stdout);
		return 0; /* simulated timeout */
	}
	if (io->dry) {
		/* Synthesize the reply the real BootROM/FDL would send, so the
		 * dry-run walks the same control flow: CHECK_BAUD -> VER, else ACK. */
		unsigned t = (io->last_type == BSL_CMD_CHECK_BAUD)
			? BSL_REP_VER : BSL_REP_ACK;
		(void)timeout_ms;
		wr16be(io->raw, t);
		if (t == BSL_REP_VER) {
			wr16be(io->raw + 2, 5);
			memcpy(io->raw + 4, "SPRDX", 5);
			io->raw_len = 4 + 5 + 2;
		} else {
			wr16be(io->raw + 2, 0);
			io->raw_len = 4 + 2;
		}
		return io->raw_len;
	}

restart:
	esc = 0;
	n = 0;
	head = 0;
	need = 6;
	pos = io->recv_pos;
	len = io->recv_len;

	for (;;) {
		int a;
		if (pos >= len) {
			int got = spd_usb_bulk_recv(&io->usb, io->recv, RECV_CAP, timeout_ms);
			if (got == 0) {
				io->recv_pos = 0;
				io->recv_len = 0;
				io->raw_len = 0;
				return 0;
			}
			if (got < 0)
				return -1;
			if (io->verbose)
				fprintf(stderr, "recv %d bytes\n", got);
			pos = 0;
			len = got;
			continue;
		}
		a = io->recv[pos++];
		if (io->flags & SPD_F_TRANSCODE) {
			/* Outside a frame, every byte is noise. This test has to
			 * come BEFORE the escape branch: HDLC escaping is
			 * per-frame, so a 0x7d out here escapes nothing and must
			 * not set esc, because the next byte is the next frame's
			 * opening 0x7e -- which would then fail the escaped-byte
			 * test below and make die() kill the whole session on one
			 * glitch in the line noise. (Clearing esc after the
			 * escape branch still missed the stray 0x7d that is
			 * *immediately* followed by the mark.) */
			if (!head) {
				esc = 0;
				if (a != HDLC_MARK)
					continue;
				head = 1;
				continue;
			}
			if (esc && a != (HDLC_MARK ^ 0x20) && a != (HDLC_ESC ^ 0x20))
				die("bad escaped byte");
			if (a == HDLC_MARK) {
				if (!n)
					continue;
				if (n < need)
					die("short frame");
				break;
			}
			if (a == HDLC_ESC) {
				esc = 0x20;
				continue;
			}
			if (n >= RAW_CAP)
				die("frame too long");
			io->raw[n++] = (uint8_t)(a ^ esc);
			esc = 0;
		} else {
			if (!head) {
				if (a == HDLC_MARK)
					head = 1;
				continue;
			}
			if (n == need) {
				if (a != HDLC_MARK)
					die("frame missing end mark");
				break;
			}
			if (n >= RAW_CAP)
				die("frame too long");
			io->raw[n++] = (uint8_t)a;
		}
		if (n == 4) {
			need = (int)rd16be(io->raw + 2) + 6;
			if (need < 6 || need > RAW_CAP)
				die("bad declared length");
		}
	}

	io->recv_pos = pos;
	io->recv_len = len;
	io->raw_len = n;
	if (n != need)
		die("truncated frame");
	{
		unsigned chk, got;
		if (io->flags & SPD_F_CRC16)
			chk = crc16(io->raw, (unsigned)(need - 2));
		else
			chk = sum16(io->raw, need - 2, CHK_ORIG);
		got = rd16be(io->raw + need - 2);
		if (got != chk) {
			fprintf(stderr, "bad checksum: got %04x expected %04x\n", got, chk);
			exit(1);
		}
	}
	if (spd_type(io) == BSL_REP_LOG) {
		unsigned plen = 0;
		const uint8_t *p = spd_payload(io, &plen);
		fprintf(stderr, "device log: %.*s\n", (int)plen, (const char *)p);
		goto restart;
	}
	return n;
}

unsigned spd_type(struct spd *io)
{
	if (io->raw_len < 4)
		return 0xffffffffu;
	return rd16be(io->raw);
}

const uint8_t *spd_payload(struct spd *io, unsigned *len)
{
	unsigned n = 0;
	if (io->raw_len >= 4)
		n = rd16be(io->raw + 2);
	if (len)
		*len = n;
	return io->raw + 4;
}

/* Send the pending frame and read one reply: 0 on ACK. QUIET drops the
 * "unexpected response" line -- check_partition() probes with sizes the device
 * is expected to refuse, and the reference is silent about those refusals. */
static int wait_ack(struct spd *io, int quiet)
{
	unsigned t;
	int n;
	if (spd_send(io) < 0)
		return -1;
	n = spd_recv(io, io->usb.timeout_ms);
	if (n == 0) {
		if (!quiet)
			fprintf(stderr, "timeout waiting for ack\n");
		return -1;
	}
	if (n < 0)
		return -1;
	t = spd_type(io);
	if (t != BSL_REP_ACK) {
		if (!quiet)
			fprintf(stderr, "unexpected response 0x%04x\n", t);
		return -1;
	}
	return 0;
}

int spd_check_ok(struct spd *io)
{
	return wait_ack(io, 0);
}

/* Settle (and optional short IN drain) after BootROM line-state. */
void spd_brom_after_line_state(struct spd *io)
{
	int settle;
	int drain;
	int i;

	if (!io)
		return;
	/* BootROM-hello only, right after line-state — see spd_usb_clear_halts(). */
	spd_usb_clear_halts(&io->usb);
	settle = env_int("SPDHOST_BROM_SETTLE_MS", 100, 0, 2000);
	if (settle > 0) {
		if (io->verbose || env_int("SPDHOST_BROM_TRACE", 0, 0, 1))
			fprintf(stderr, "brom: settle %d ms\n", settle);
		pause_ms(settle);
	}
	drain = env_int("SPDHOST_BROM_DRAIN", 0, 0, 1);
	if (!drain)
		return;
	for (i = 0; i < 3; i++) {
		uint8_t junk[64];
		int got = spd_usb_bulk_recv(&io->usb, junk, (int)sizeof(junk), 80);
		if (got == 0)
			continue; /* TIMEOUT — ignore */
		if (got < 0) {
			fprintf(stderr, "brom: drain abort (recv error)\n");
			return;
		}
		if (io->verbose || env_int("SPDHOST_BROM_TRACE", 0, 0, 1))
			fprintf(stderr, "brom: drain got %d bytes\n", got);
	}
}

static int reopen_if_gone(struct spd *io)
{
	if (!io->usb.gone)
		return -1;
	fprintf(stderr, "USB reset; reopening\n");
	if (spd_usb_reacquire(&io->usb))
		return -1;
	io->recv_pos = 0;
	io->recv_len = 0;
	return 0;
}

/* Per-try receive timeout for BootROM hello try i (0-based) of `tries`.
 * Ramps from hello_to_min up to hello_to_max over the first `ramp` tries,
 * then stays at hello_to_max. Below hello_to_min, LIBUSB_ERROR_TIMEOUT is
 * indistinguishable from "BootROM not listening yet"; above hello_to_max,
 * the ceiling exists because some phones genuinely take that long to answer
 * once they are listening. The device can't tell you which situation you're
 * in, so the ramp buys more attempts at cheap timeouts early — when "not
 * listening yet" is the likelier explanation — while still reaching the full
 * patient timeout by the time enough short tries have failed to make that
 * less likely. Rationale, not a guarantee: on some phones the narrow window
 * really does need a near-hello_to_max wait from the very first try, which
 * is what SPDHOST_BROM_NO_RAMP=1 is for. */
static int ramp_hello_to(int i, int lo, int hi, int ramp)
{
	if (ramp <= 1 || lo >= hi)
		return hi;
	if (i >= ramp - 1)
		return hi;
	return lo + (int)((long long)(hi - lo) * i / (ramp - 1));
}

int spd_check_baud(struct spd *io, int nbytes, int tries)
{
	int i;
	int brom = (nbytes == 1);
	int pause;
	int hello_to;      /* ceiling; also this try's timeout when brom==0 */
	int hello_to_min;  /* brom only: ramp floor */
	int ramp_tries;    /* brom only: tries to reach the ceiling over */
	int wall_ms;
	int wall_explicit;
	int brom_trace;
	int reacqs_max = 0;
	int reacqs_done = 0;
	long long t0 = 0;

	/* BootROM hello (raw 1×0x7e): patient defaults + wall; tries arg ignored.
	 * hello_to uses SPDHOST_BROM_TIMEOUT only (default 3000) — not max'd with
	 * global --timeout / usb.timeout_ms (that still applies to CONNECT/bulk/loader).
	 *
	 * Each try's own receive timeout ramps from SPDHOST_BROM_TIMEOUT_MIN
	 * (default 250) up to SPDHOST_BROM_TIMEOUT over SPDHOST_BROM_TIMEOUT_RAMP
	 * tries (default 6), then holds at the ceiling. A timed-out try that used
	 * a short timeout costs little wall budget, so more of them fit before
	 * SPDHOST_BROM_WALL_MS runs out — which matters because the BootROM's
	 * listen window is often shorter than one try at the old fixed 3000ms.
	 * SPDHOST_BROM_NO_RAMP=1 disables this and every try uses the ceiling,
	 * matching the previous fixed-timeout behaviour.
	 *
	 * If SPDHOST_BROM_WALL_MS is not set, the wall is computed from `tries`
	 * and the ramp so that all of them actually fit (previously the 20000ms
	 * default only fit 5-6 of the documented 15 tries; the rest were silently
	 * never attempted). An explicit SPDHOST_BROM_WALL_MS always wins. */
	if (brom) {
		tries = env_int("SPDHOST_BROM_TRIES", 15, 1, 100);
		pause = env_int("SPDHOST_BROM_PAUSE_MS", 500, 0, 5000);
		hello_to = env_int("SPDHOST_BROM_TIMEOUT", 3000, 1, 600000);
		hello_to_min = env_int("SPDHOST_BROM_TIMEOUT_MIN", 250, 1, hello_to);
		ramp_tries = env_int("SPDHOST_BROM_TIMEOUT_RAMP", 6, 1, tries);
		if (env_int("SPDHOST_BROM_NO_RAMP", 0, 0, 1))
			hello_to_min = hello_to; /* ramp_hello_to() then returns hello_to for every i */
		brom_trace = io->verbose || env_int("SPDHOST_BROM_TRACE", 0, 0, 1);
		/* Default OFF: forced USB close/reopen mid-hello re-prompts termux-usb
		 * Allow and often hits claim BUSY. Soft OUT TIMEOUT retries + wall stay
		 * on the same FD. REACQ>0 = soft same-handle settle+retry only (no reopen). */
		reacqs_max = env_int("SPDHOST_BROM_REACQ", 0, 0, 2);
		{
			const char *w = getenv("SPDHOST_BROM_WALL_MS");
			wall_explicit = w && w[0];
		}
		if (wall_explicit) {
			wall_ms = env_int("SPDHOST_BROM_WALL_MS", 20000, 1000, 120000);
		} else {
			long long budget = 0;
			for (i = 0; i < tries; i++) {
				if (i) budget += pause;
				budget += ramp_hello_to(i, hello_to_min, hello_to, ramp_tries);
			}
			wall_ms = (int)(budget > 120000 ? 120000 : budget < 1000 ? 1000 : budget);
		}
		t0 = mono_ms();
		/* Always-on short start line (hello_to + wall + tries). */
		fprintf(stderr, "brom: hello hello_to=%d..%d(x%d) wall=%d%s tries=%d\n",
			hello_to_min, hello_to, ramp_tries, wall_ms,
			wall_explicit ? "" : "(auto)", tries);
		if (brom_trace)
			fprintf(stderr, "brom: check-baud start nbytes=1 tries=%d pause=%d hello_to=%d..%d(x%d) wall=%d%s reacq=%d @%lldms\n",
				tries, pause, hello_to_min, hello_to, ramp_tries, wall_ms,
				wall_explicit ? "" : "(auto)", reacqs_max, t0);
	} else {
		pause = 200;
		hello_to = io->usb.timeout_ms;
		hello_to_min = hello_to;
		ramp_tries = 1;
		wall_ms = 0;
		brom_trace = 0;
	}

reacq_restart:
	for (i = 0; i < tries; i++) {
		int n;
		int rc;
		int saved_to;
		int try_to = brom ? ramp_hello_to(i, hello_to_min, hello_to, ramp_tries) : hello_to;
		long long now;

		if (spd_interrupted) {
			fprintf(stderr, "interrupted; stopping check-baud\n");
			return -1;
		}
		if (brom) {
			now = mono_ms();
			if (now - t0 >= wall_ms) {
				fprintf(stderr, "check baud: wall %d ms exceeded after %d of %d tries\n",
					wall_ms, i, tries);
				break;
			}
			if (brom_trace)
				fprintf(stderr, "brom: try %d of %d start @%lldms\n",
					i + 1, tries, now - t0);
		}
		if (i)
			pause_ms(pause);
		if (spd_interrupted) {
			fprintf(stderr, "interrupted; stopping check-baud\n");
			return -1;
		}
		if (brom) {
			now = mono_ms();
			if (now - t0 >= wall_ms) {
				fprintf(stderr, "check baud: wall %d ms exceeded after %d of %d tries\n",
					wall_ms, i, tries);
				break;
			}
		}
		spd_encode(io, BSL_CMD_CHECK_BAUD, NULL, (size_t)nbytes);
		/* Hello-only timeout for send; do not leave global usb.timeout_ms raised. */
		saved_to = io->usb.timeout_ms;
		io->usb.timeout_ms = try_to;
		rc = spd_send(io);
		io->usb.timeout_ms = saved_to;
		if (brom && brom_trace)
			fprintf(stderr, "brom: try %d of %d send rc=%d to=%dms @%lldms\n",
				i + 1, tries, rc, try_to, mono_ms() - t0);
		if (rc < 0) {
			if (reopen_if_gone(io) == 0)
				continue;
			/* BootROM only: send TIMEOUT (-2, gone unset) is a soft fail —
			 * same as recv timeout: keep trying within the wall (optional soft A2). */
			if (brom && rc == -2 && !io->usb.gone) {
				fprintf(stderr, "brom: try %d of %d send TIMEOUT (soft retry) @%lldms\n",
					i + 1, tries, mono_ms() - t0);
				now = mono_ms();
				if (now - t0 >= wall_ms) {
					fprintf(stderr, "check baud: wall %d ms exceeded after %d of %d tries\n",
						wall_ms, i + 1, tries);
					break;
				}
				continue;
			}
			return -1;
		}
		n = spd_recv(io, try_to);
		if (brom && brom_trace) {
			if (n == 0)
				fprintf(stderr, "brom: try %d of %d recv timeout @%lldms\n",
					i + 1, tries, mono_ms() - t0);
			else if (n < 0)
				fprintf(stderr, "brom: try %d of %d recv disconnect/err @%lldms\n",
					i + 1, tries, mono_ms() - t0);
			else
				fprintf(stderr, "brom: try %d of %d recv n=%d @%lldms\n",
					i + 1, tries, n, mono_ms() - t0);
		}
		if (n < 0) {
			if (reopen_if_gone(io) == 0)
				continue;
			return -1;
		}
		if (n == 0) {
			fprintf(stderr, "check baud %d/%d: timeout\n", i + 1, tries);
			if (brom) {
				now = mono_ms();
				if (now - t0 >= wall_ms) {
					fprintf(stderr, "check baud: wall %d ms exceeded after %d of %d tries\n",
						wall_ms, i + 1, tries);
					break;
				}
			}
			continue;
		}
		if (spd_type(io) != BSL_REP_VER) {
			fprintf(stderr, "check baud %d/%d: response 0x%04x\n",
				i + 1, tries, spd_type(io));
			continue;
		}
		{
			unsigned plen = 0;
			const uint8_t *payload = spd_payload(io, &plen);
			fprintf(stderr, "version: %.*s\n", (int)plen, (const char *)payload);
		}
		return 0;
	}

	/* A2: after try/wall budget miss with no VER, optional soft same-FD reacq.
	 * Never force gone / never close+reopen mid-hello (that re-prompts termux-usb
	 * Allow and often claim BUSY on a still-open grant). Soft path: line-state +
	 * settle/drain on the current handle, then restart tries with a fresh wall. */
	if (brom && reacqs_done < reacqs_max) {
		fprintf(stderr, "brom: hello timeout; soft reacq same FD (reacq %d of %d)\n",
			reacqs_done + 1, reacqs_max);
		if (spd_usb_line_state(&io->usb) != 0)
			fprintf(stderr, "brom: soft reacq: line-state failed; continuing same FD\n");
		spd_brom_after_line_state(io);
		reacqs_done++;
		t0 = mono_ms();
		if (brom_trace)
			fprintf(stderr, "brom: soft reacq %d of %d done; restarting check-baud (fresh wall=%d @0ms)\n",
				reacqs_done, reacqs_max, wall_ms);
		if (spd_interrupted) {
			fprintf(stderr, "interrupted; stopping check-baud\n");
			return -1;
		}
		goto reacq_restart;
	}
	return -1;
}

int spd_check_baud_loader(struct spd *io)
{
	int i;
	/* sfd_tool sends one 0x7e after FDL1 on phones. The older dumper
	 * sends four. Try the phone form first, then the older one. */
	for (i = 0; i < 10; i++) {
		int nbytes = i < 6 ? 1 : 4;
		int n;
		if (i)
			pause_ms(500);
		spd_encode(io, BSL_CMD_CHECK_BAUD, NULL, (size_t)nbytes);
		if (spd_send(io) < 0) {
			if (reopen_if_gone(io) == 0)
				continue;
			return -1;
		}
		n = spd_recv(io, io->usb.timeout_ms);
		if (n < 0) {
			if (reopen_if_gone(io) == 0)
				continue;
			return -1;
		}
		if (n == 0) {
			fprintf(stderr, "loader check baud %d (%d x 0x7e): timeout\n", i + 1, nbytes);
			continue;
		}
		if (spd_type(io) != BSL_REP_VER) {
			fprintf(stderr, "loader check baud %d: response 0x%04x\n", i + 1, spd_type(io));
			continue;
		}
		{
			unsigned plen = 0;
			const uint8_t *p = spd_payload(io, &plen);
			fprintf(stderr, "version: %.*s\n", (int)plen, (const char *)p);
		}
		return 0;
	}
	return -1;
}

int spd_connect(struct spd *io)
{
	spd_encode(io, BSL_CMD_CONNECT, NULL, 0);
	return spd_check_ok(io);
}

/* spd_dump spd_dump.c:425 and :706 -- `if (keep_charge) { encode_msg(io,
 * BSL_CMD_KEEP_CHARGE, NULL, 0); if (!send_and_check(io)) DBG_LOG("KEEP_CHARGE
 * FDL1\n"); }`. Sent once per run, right after the FDL1-stage CMD_CONNECT, and
 * it tells the loader to keep charging the battery while it runs. A refusal is
 * not an error: the reference only logs the success, so a loader that does not
 * know the command still flashes. 0 = the loader took it. */
int spd_keep_charge(struct spd *io)
{
	spd_encode(io, BSL_CMD_KEEP_CHARGE, NULL, 0);
	if (spd_send(io) < 0)
		return -1;
	if (spd_recv(io, io->usb.timeout_ms) <= 0)
		return -1;
	return spd_type(io) == BSL_REP_ACK ? 0 : -1;
}

static uint8_t *load_file(const char *path, size_t *out)
{
	FILE *f = fopen(path, "rb");
	off_t n;
	uint8_t *buf;
	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		exit(1);
	}
	/* ftell returns a 32-bit long on arm32. fseeko/ftello stay 64-bit. */
	if (fseeko(f, 0, SEEK_END) != 0)
		die("fseek");
	n = ftello(f);
	if (n < 0 || (unsigned long long)n > (unsigned long long)SIZE_MAX)
		die("ftell");
	if (fseeko(f, 0, SEEK_SET) != 0)
		die("fseek");
	buf = malloc((size_t)n);
	if (!buf)
		die("out of memory");
	if (n && fread(buf, 1, (size_t)n, f) != (size_t)n)
		die("short read");
	fclose(f);
	*out = (size_t)n;
	return buf;
}

int spd_send_loader(struct spd *io, const char *path, uint32_t addr)
{
	size_t size = 0;
	uint8_t *mem = load_file(path, &size);
	uint8_t hdr[8];
	size_t off;
	int step = io->step > 0 && io->step < 528 ? io->step : 528;

	if (size > 0xffffffffu)
		die("loader too big");
	wr32be(hdr, addr);
	wr32be(hdr + 4, (uint32_t)size);
	spd_encode(io, BSL_CMD_START_DATA, hdr, 8);
	if (spd_check_ok(io))
		exit(1);
	for (off = 0; off < size; ) {
		size_t n = size - off;
		if (n > (size_t)step)
			n = (size_t)step;
		spd_encode(io, BSL_CMD_MIDST_DATA, mem + off, n);
		if (spd_check_ok(io))
			exit(1);
		off += n;
	}
	spd_encode(io, BSL_CMD_END_DATA, NULL, 0);
	if (spd_check_ok(io))
		exit(1);
	free(mem);
	fprintf(stderr, "sent %s (%zu bytes) at 0x%08x\n", path, size, addr);
	return 0;
}

/* exec_addr path (BootROM only). Mirrors spd_dump.c's non-v2 branch:
 *   send_file(io, execfile, exec_addr, end_data=0, step=528, 0, 0)
 * i.e. BSL_CMD_START_DATA(addr,size) then BSL_CMD_MIDST_DATA chunks, with
 * NO BSL_CMD_END_DATA and NO BSL_CMD_EXEC_DATA. The caller then goes straight
 * to spd_check_baud_loader(). spd_dump uses a fixed 528-byte step here, so we
 * do too, to keep the on-wire chunking byte-identical.
 *
 * Ack handling: spd_dump's send_buf() calls send_and_check() on every packet,
 * including the last MIDST, and would ERR_EXIT on a timeout. In practice the
 * no-verify stub can seize execution the instant its last byte lands, so the
 * final MIDST's ack may never arrive. We read acks for START and every MIDST
 * but the last exactly like spd_dump; on the final MIDST we send and TOLERATE
 * a missing/timeout ack (and a non-ACK type), because that is the stub taking
 * over — not an error. The bytes put on the wire are identical either way. */
/* The final MIDST of a download the stub takes over from: send it, then accept
 * a missing ack, a recv error or any non-ACK type. The bytes on the wire are
 * what matter; the reference's send_and_check would exit here, but the stub
 * running is the normal reason for silence. Shared by the two exec_addr paths
 * so they cannot drift. */
static void send_final_chunk(struct spd *io, const char *what)
{
	int got;

	if (io->dry) {
		/* Test hook: SPDHOST_DRY_EXEC_NOACK=1 simulates the stub seizing
		 * execution before it acks the last chunk. */
		const char *e = getenv("SPDHOST_DRY_EXEC_NOACK");
		io->dry_drop_ack = e && e[0] == '1';
	}
	if (spd_send(io) < 0) {
		/* A USB reset as the stub starts is expected; anything else is a
		 * real send failure (spd_dump exits here too). */
		if (reopen_if_gone(io) != 0) {
			fprintf(stderr, "%s: send of final chunk failed\n", what);
			exit(1);
		}
	} else if ((got = spd_recv(io, io->usb.timeout_ms)) == 0) {
		fprintf(stderr, "%s: no ack on final chunk "
			"(stub likely running) - continuing\n", what);
	} else if (got < 0) {
		if (reopen_if_gone(io) != 0)
			fprintf(stderr, "%s: recv error after final chunk - continuing\n", what);
	} else if (spd_type(io) != BSL_REP_ACK) {
		fprintf(stderr, "%s: final chunk response 0x%04x "
			"(stub likely running) - continuing\n", what, spd_type(io));
	}
}

int spd_send_exec_file(struct spd *io, const char *path, uint32_t addr)
{
	size_t size = 0;
	uint8_t *mem = load_file(path, &size);
	uint8_t hdr[8];
	size_t off;
	int step = 528; /* match spd_dump send_file(...528...) */

	if (size > 0xffffffffu)
		die("exec file too big");
	if (size == 0)
		die("exec file is empty");
	wr32be(hdr, addr);
	wr32be(hdr + 4, (uint32_t)size);
	spd_encode(io, BSL_CMD_START_DATA, hdr, 8);
	if (spd_check_ok(io))
		exit(1);
	for (off = 0; off < size; ) {
		size_t n = size - off;
		if (n > (size_t)step)
			n = (size_t)step;
		spd_encode(io, BSL_CMD_MIDST_DATA, mem + off, n);
		if (off + n >= size)
			send_final_chunk(io, "exec_addr");
		else if (spd_check_ok(io))
			exit(1);
		off += n;
	}
	/* No END_DATA, no EXEC_DATA — exactly like spd_dump's exec_addr path. */
	free(mem);
	fprintf(stderr, "exec_addr: sent %s (%zu bytes) at 0x%08x (no END/EXEC)\n",
		path, size, addr);
	return 0;
}

int spd_send_loader_appended(struct spd *io, const char *path, uint32_t addr,
	const char *stub, uint32_t stub_addr)
{
	size_t size = 0, ssize = 0;
	uint8_t *mem = load_file(path, &size);
	uint8_t *smem = load_file(stub, &ssize);
	uint8_t hdr[8];
	uint8_t *zeros;
	size_t off;
	int step = 528; /* spd_dump's v2 branch sends every frame at a fixed 528 */
	uint64_t gap;

	if (size > 0xffffffffu)
		die("loader too big");
	if (ssize > 0xffffffffu || ssize == 0)
		die("exec file too big or empty");
	/* spd_dump: `int gapsize = exec_addr - addr - execsize;` -- a stub that is
	 * not past the end of the loader leaves a negative gap, and its loop then
	 * sends no filler at all. Mirror that instead of underflowing. */
	gap = (uint64_t)stub_addr > (uint64_t)addr + size
		? (uint64_t)stub_addr - addr - size : 0;

	wr32be(hdr, addr);
	wr32be(hdr + 4, (uint32_t)size);
	spd_encode(io, BSL_CMD_START_DATA, hdr, 8);
	if (spd_check_ok(io))
		exit(1);
	/* FDL1 itself, with NO END_DATA: the download stays open. */
	for (off = 0; off < size; ) {
		size_t n = size - off;
		if (n > (size_t)step)
			n = (size_t)step;
		spd_encode(io, BSL_CMD_MIDST_DATA, mem + off, n);
		if (spd_check_ok(io))
			exit(1);
		off += n;
	}
	/* The filler, up to the stub's address. The reference sends an
	 * uninitialized malloc(528) here; nothing reads it, so zeros are sent. */
	zeros = calloc(1, (size_t)step);
	for (off = 0; off < (size_t)gap; ) {
		size_t n = (size_t)gap - off;
		if (n > (size_t)step)
			n = (size_t)step;
		spd_encode(io, BSL_CMD_MIDST_DATA, zeros, n);
		if (spd_check_ok(io))
			exit(1);
		off += n;
	}
	free(zeros);
	/* The stub: ONE MIDST with the whole file (spd_dump's
	 * `encode_msg(BSL_CMD_MIDST_DATA, buf, execsize)`), which is also the last
	 * packet of the download -- so its ack may never come. */
	spd_encode(io, BSL_CMD_MIDST_DATA, smem, (uint32_t)ssize);
	send_final_chunk(io, "exec_addr2");
	free(mem);
	free(smem);
	fprintf(stderr, "exec_addr2: sent %s (%zu bytes) at 0x%08x + %zu zero bytes,"
		" then %s (%zu bytes) in the same download (no END/EXEC)\n",
		path, size, addr, (size_t)gap, stub, ssize);
	return 0;
}

/* spd_dump get_Da_Info() (common.c:1955): the reply to EXEC_DATA on a loader that
 * answers BSL_REP_INCOMPATIBLE_PARTITION carries its Da_Info. Two shapes on the
 * wire: a `newt` key/length/value list, or the DA_INFO_T struct itself
 * (common.h:162, packed). Only two fields change what we do, so only two are
 * read: dwStorageType (BSL: key 6 / offset 16) and bDisableHDLC (key 0 /
 * offset 4). bSupportRawData (key 2 / offset 9) and dwFlushSize are decoded by
 * the reference into a raw-data write protocol this tool does not implement;
 * see the README's divergence list. */
static void da_info_parse(struct spd *io)
{
	unsigned plen = 0;
	const uint8_t *pl = spd_payload(io, &plen);
	uint32_t hdlc = 0, storage = 0;

	if (plen > 6 && rd32le(pl) == 0x7477656e) { /* "newt" */
		size_t off = 4;
		while (off + 4 <= plen) {
			uint16_t key = (uint16_t)(pl[off] | ((uint16_t)pl[off + 1] << 8));
			uint16_t vlen = (uint16_t)(pl[off + 2] | ((uint16_t)pl[off + 3] << 8));
			off += 4;
			if (off + vlen > plen)
				break;
			if (key == 0 && vlen >= 4)
				hdlc = rd32le(pl + off);
			else if (key == 6 && vlen >= 4)
				storage = rd32le(pl + off);
			off += vlen;
		}
	} else if (plen >= 20) { /* DA_INFO_T: dwVersion, bDisableHDLC, ... dwStorageType */
		hdlc = rd32le(pl + 4);
		storage = rd32le(pl + 16);
	}
	if (storage)
		io->storage = (int)storage;
	if (hdlc)
		io->hdlc_off_wanted = 1;
	fprintf(stderr, "FDL2: incompatible partition\n");
}

int spd_exec(struct spd *io, int timeout_ms, int allow_incompatible)
{
	unsigned t;
	spd_encode(io, BSL_CMD_EXEC_DATA, NULL, 0);
	if (spd_send(io) < 0) {
		/* The loader often resets USB as it starts, before the ack. */
		if (reopen_if_gone(io) == 0)
			return 0;
		return -1;
	}
	{
		int n = spd_recv(io, timeout_ms);
		if (n < 0) {
			if (reopen_if_gone(io) == 0)
				return 0;
			return -1;
		}
		if (n == 0) {
			fprintf(stderr, "timeout waiting for exec\n");
			return -1;
		}
	}
	t = spd_type(io);
	if (t == BSL_REP_ACK)
		return 0;
	if (allow_incompatible && t == BSL_REP_INCOMPATIBLE_PARTITION) {
		/* The reply body is the loader's Da_Info (spd_dump.c:731-732). */
		da_info_parse(io);
		return 0;
	}
	fprintf(stderr, "exec response 0x%04x\n", t);
	return -1;
}

/* spd_dump's fdl2 stage, after the EXEC_DATA reply (spd_dump.c:736-752): ask the
 * loader for its flash info, then honour a Da_Info request to turn HDLC off.
 * A BSL_REP_READ_FLASH_INFO reply is NAND (Da_Info.dwStorageType = 0x101); any
 * other reply is logged and ignored, exactly as the reference does -- most
 * loaders answer nothing useful here. Non-fatal either way: a device that does
 * not answer is not asked twice. */
int spd_flash_info(struct spd *io)
{
	unsigned t;

	spd_encode(io, BSL_CMD_READ_FLASH_INFO, NULL, 0);
	if (spd_send(io) < 0)
		return -1;
	if (spd_recv(io, io->usb.timeout_ms) <= 0)
		return -1;
	t = spd_type(io);
	if (t == BSL_REP_READ_FLASH_INFO) {
		io->storage = SPD_STORAGE_NAND;
		fprintf(stderr, "Storage is nand\n");
	} else if (t != BSL_REP_ACK) {
		fprintf(stderr, "unexpected response (0x%04x)\n", t);
	}
	if (io->hdlc_off_wanted) {
		spd_encode(io, BSL_CMD_DISABLE_TRANSCODE, NULL, 0);
		if (!spd_check_ok(io)) {
			io->flags &= ~SPD_F_TRANSCODE;
			if (io->verbose)
				fprintf(stderr, "DISABLE_TRANSCODE\n");
		}
	}
	return 0;
}

static int put_name(uint8_t *dst, size_t nchars, const char *name)
{
	size_t i;
	memset(dst, 0, nchars * 2);
	for (i = 0; name[i]; i++) {
		if (i + 1 >= nchars)
			return -1;
		dst[i * 2] = (uint8_t)name[i];
	}
	return 0;
}

/* Partition commands carry a 36-wchar UTF-16LE name and a little-endian size.
 * The address-style loader download uses big-endian instead. */
static void select_part(struct spd *io, const char *name, uint64_t size, unsigned cmd)
{
	uint8_t pkt[36 * 2 + 16];
	int mode64 = size > 0xffffffffu;
	int n;

	memset(pkt, 0, sizeof(pkt));
	if (put_name(pkt, 36, name))
		die("partition name too long");
	wr32le(pkt + 72, (uint32_t)size);
	if (mode64)
		wr32le(pkt + 76, (uint32_t)(size >> 32));
	n = 72 + (mode64 ? 16 : 4);
	spd_encode(io, cmd, pkt, (size_t)n);
}

/* QUIET silences the one-line summary. spd_dump's partition_list() wraps its
 * GPT probe in `io->verbose = 0` (common.c:1073-1076) because that read is not
 * the command the user asked for, and on a device whose table is an SPRD packet
 * it always comes back short -- which would otherwise print a failure on every
 * single session. */
static int read_part_core_q(struct spd *io, const char *name, uint64_t offset, uint64_t size,
	const char *out_path, uint8_t *mem, int quiet)
{
	FILE *fo = NULL;
	uint64_t done = 0;
	int mode64 = (offset + size) > 0xffffffffu;
	int step = io->step;
	int bad = 0;

	if (offset > UINT64_MAX - size) {
		fprintf(stderr, "read range wraps\n");
		return -1;
	}
	/* Like spd_dump dump_partition(): a NACKed READ_START is closed with
	 * READ_END and reported, so a batch can go on with the next partition. */
	select_part(io, name, offset + size, BSL_CMD_READ_START);
	if (spd_check_ok(io)) {
		if (!quiet)
			fprintf(stderr, "read %s: READ_START refused (no such partition or size too big)\n", name);
		spd_encode(io, BSL_CMD_READ_END, NULL, 0);
		spd_check_ok(io);
		return -1;
	}
	if (out_path)
		fo = fopen(out_path, "wb");
	if (out_path && !fo) {
		fprintf(stderr, "open %s: %s\n", out_path, strerror(errno));
		spd_encode(io, BSL_CMD_READ_END, NULL, 0);
		spd_check_ok(io);
		return -1;
	}

	while (done < size) {
		uint8_t req[12];
		if (spd_interrupted) {
			if (fo)
				fclose(fo);
			fprintf(stderr, "interrupted; stopped read at %llu of %llu bytes (%s left as-is)\n",
				(unsigned long long)done, (unsigned long long)size, out_path);
			return -1;
		}
		uint64_t left = size - done;
		uint64_t pos = offset + done;
		uint32_t n = left > (uint64_t)step ? (uint32_t)step : (uint32_t)left;
		unsigned t, plen = 0;
		const uint8_t *p;

		wr32le(req, n);
		wr32le(req + 4, (uint32_t)pos);
		wr32le(req + 8, (uint32_t)(pos >> 32));
		spd_encode(io, BSL_CMD_READ_MIDST, req, mode64 ? 12 : 8);
		if (spd_send(io) < 0)
			die("send failed during read");
		{
			int got = spd_recv(io, io->usb.timeout_ms);
			if (got == 0)
				die("timeout during read");
			if (got < 0)
				die("device reset during read; this read was not resumed");
		}
		t = spd_type(io);
		if (t != BSL_REP_READ_FLASH) {
			/* spd_dump: "unexpected response", break, then READ_END. */
			fprintf(stderr, "read %s: response 0x%04x at offset %llu\n", name, t,
				(unsigned long long)pos);
			bad = 1;
			break;
		}
		p = spd_payload(io, &plen);
		if (plen > n)
			die("device returned more than requested");
		if (fo && fwrite(p, 1, plen, fo) != plen)
			die("write failed");
		if (mem)
			memcpy(mem + done, p, plen);
		done += plen;
		if (plen != n)
			break;
	}
	if (fo && fclose(fo) != 0) {
		fprintf(stderr, "close %s: %s\n", out_path, strerror(errno));
		bad = 1;
	}
	spd_encode(io, BSL_CMD_READ_END, NULL, 0);
	if (spd_check_ok(io)) {
		fprintf(stderr, "read %s: READ_END not acked\n", name);
		bad = 1;
	}
	if (!quiet)
		fprintf(stderr, "read %s: %llu of %llu bytes -> %s%s\n", name, (unsigned long long)done,
			(unsigned long long)size, out_path ? out_path : "memory",
			(bad || done != size) ? " (INCOMPLETE)" : "");
	return (!bad && done == size) ? 0 : -1;
}

int spd_read_part(struct spd *io, const char *name, uint64_t offset, uint64_t size, const char *out_path)
{
	return read_part_core_q(io, name, offset, size, out_path, NULL, 0);
}

int spd_read_part_mem(struct spd *io, const char *name, uint64_t offset, uint64_t size, uint8_t *mem)
{
	return read_part_core_q(io, name, offset, size, NULL, mem, 0);
}

/* ------------------------------------------------------------------ *
 * check_partition(): the one command that asks the DEVICE how big a
 * partition is instead of reading the table (spd_dump common.c:1471).
 * The table is what the phone booted with; the device is what the phone
 * has now, which is the whole point for a row the XML wrote as
 * 0xffffffff ("take the rest") -- super after a repartition.
 *
 * Three answers, tried in this order, exactly as the reference does:
 *   1. find_partition_size_new(): read "<NAME>_size" (0x80 bytes at 0)
 *      and parse the loader's own text ("size:...: 0x...", or lk's
 *      "partition ... total size: 0x..."). Only on A/B, because that is
 *      the only layout the reference keeps such rows for.
 *   2. a probe: READ_START of 8 bytes, MIDST 8 at 0; a READ_FLASH reply
 *      means the partition is there.
 *   3. a binary search for the size: ask for 0xffffffff and let the
 *      loader's refusal say "too big", then halve down. The reference's
 *      own loop, with its two branches -- a loader that refuses the
 *      0xffffffff START outright is NAND (its bounds are 10 and 20, and
 *      the result loses one 1 KiB block per round).
 *
 * AB is the active slot, >0 on A/B. NEED_SIZE asks for the size (step 3);
 * without it the answer is just 1/0 ("the partition exists").
 */
static void read_end(struct spd *io)
{
	spd_encode(io, BSL_CMD_READ_END, NULL, 0);
	wait_ack(io, 1);
}

static uint64_t part_size_from_device(struct spd *io, const char *name)
{
	char tmp[80], text[512];
	uint8_t req[8];
	unsigned plen = 0;
	const uint8_t *p;
	unsigned long long off = 0;
	int got;

	if (snprintf(tmp, sizeof(tmp), "%s_size", name) >= (int)sizeof(tmp))
		return 0;
	select_part(io, tmp, 0x80, BSL_CMD_READ_START);
	if (wait_ack(io, 1)) {
		read_end(io);
		return 0;
	}
	wr32le(req, 0x80);
	wr32le(req + 4, 0);
	spd_encode(io, BSL_CMD_READ_MIDST, req, 8);
	if (spd_send(io) < 0)
		die("send failed while asking for a partition size");
	got = spd_recv(io, io->usb.timeout_ms);
	if (got == 0)
		die("timeout reached");
	if (got < 0)
		die("device reset while asking for a partition size");
	if (spd_type(io) == BSL_REP_READ_FLASH) {
		p = spd_payload(io, &plen);
		if (plen >= sizeof(text))
			plen = sizeof(text) - 1;
		memcpy(text, p, plen);
		text[plen] = 0;
		if (sscanf(text, "size:%*[^:]: 0x%llx", &off) != 1)
			sscanf(text, "partition %*s total size: 0x%llx", &off);
	}
	read_end(io);
	return (uint64_t)off;
}

/* READ_START of 8 bytes + MIDST 8 at 0: 1 when the partition answered. */
static int part_probe(struct spd *io, const char *name)
{
	uint8_t req[8];
	int ret;

	select_part(io, name, 0x8, BSL_CMD_READ_START);
	if (wait_ack(io, 1)) {
		read_end(io);
		return 0;
	}
	wr32le(req, 0x8);
	wr32le(req + 4, 0);
	spd_encode(io, BSL_CMD_READ_MIDST, req, 8);
	if (spd_send(io) < 0)
		die("send failed while probing a partition");
	ret = spd_recv(io, io->usb.timeout_ms);
	if (ret == 0)
		die("timeout reached");
	if (ret < 0)
		die("device reset while probing a partition");
	ret = spd_type(io) == BSL_REP_READ_FLASH ? 1 : 0;
	read_end(io);
	return ret;
}

uint64_t spd_check_partition(struct spd *io, const char *name, int need_size, int ab)
{
	uint64_t offset = 0;
	char name_tmp[40];
	int i, end = 20, incrementing = 1;
	int ret;

	if (ab > 0 && !strcmp(name, "uboot"))
		return 0;
	if (strstr(name, "fixnv")) {
		size_t l = strlen(name);
		if (ab > 0 && (l < 2 || (strcmp(name + l - 2, "_a") && strcmp(name + l - 2, "_b"))))
			return 0;
		snprintf(name_tmp, sizeof(name_tmp), "%s", name);
		{ char *d = strrchr(name_tmp, '1'); if (d) *d = '2'; }
		name = name_tmp;
	} else if (strstr(name, "runtimenv")) {
		size_t l = strlen(name);
		if (l >= 2 && (!strcmp(name + l - 2, "_a") || !strcmp(name + l - 2, "_b")))
			return 0;
		snprintf(name_tmp, sizeof(name_tmp), "%s", name);
		{ char *d = strrchr(name_tmp, '1'); if (d) *d = '2'; }
		name = name_tmp;
	}

	if (ab > 0) {
		offset = part_size_from_device(io, name);
		if (offset)
			return need_size ? offset : 1;
	}
	ret = part_probe(io, name);
	if (!ret)
		return 0;
	if (!need_size)
		return 1;

	select_part(io, name, 0xffffffffu, BSL_CMD_READ_START);
	if (wait_ack(io, 1)) {
		/* The loader refused 0xffffffff: NAND, whose bounds start at 10. */
		end = 10;
		read_end(io);
		for (i = 21; i >= end;) {
			uint64_t n64 = offset + (1ull << i) - (1ull << end);
			select_part(io, name, n64, BSL_CMD_READ_START);
			if (spd_send(io) < 0)
				die("send failed while sizing a partition");
			ret = spd_recv(io, io->usb.timeout_ms);
			if (ret == 0)
				die("timeout reached");
			if (ret < 0)
				die("device reset while sizing a partition");
			ret = spd_type(io);
			if (incrementing) {
				if (ret != BSL_REP_ACK) {
					offset += 1ull << (i - 1);
					i -= 2;
					incrementing = 0;
				} else {
					i++;
				}
			} else {
				if (ret == BSL_REP_ACK)
					offset += 1ull << i;
				i--;
			}
			read_end(io);
		}
		offset -= 1ull << end;
	} else {
		for (i = 21; i >= end;) {
			uint8_t data[12];
			uint64_t n64 = offset + (1ull << i) - (1ull << end);
			wr32le(data, 4);
			wr32le(data + 4, (uint32_t)n64);
			wr32le(data + 8, (uint32_t)(n64 >> 32));
			spd_encode(io, BSL_CMD_READ_MIDST, data, 12);
			if (spd_send(io) < 0)
				die("send failed while sizing a partition");
			ret = spd_recv(io, io->usb.timeout_ms);
			if (ret == 0)
				die("timeout reached");
			if (ret < 0)
				die("device reset while sizing a partition");
			ret = spd_type(io);
			if (incrementing) {
				if (ret != BSL_REP_READ_FLASH) {
					offset += 1ull << (i - 1);
					i -= 2;
					incrementing = 0;
				} else {
					i++;
				}
			} else {
				if (ret == BSL_REP_READ_FLASH)
					offset += 1ull << i;
				i--;
			}
		}
	}
	if (end == 10) {
		/* A loader that refuses 0xffffffff outright is NAND (spd_dump
		 * common.c:1582, Da_Info.dwStorageType = 101). Nothing else in
		 * this call depends on it, but w_force and load_partition_unify's
		 * _bak copy do, and they can run later in the same session. */
		io->storage = SPD_STORAGE_NAND;
		if (io->verbose)
			fprintf(stderr, "Storage is nand\n");
	}
	fprintf(stderr, "partition_size_pc: %s, 0x%llx\n", name, (unsigned long long)offset);
	read_end(io);
	return offset;
}

/* ------------------------------------------------------------------ *
 * read_flash / read_mem / erase_flash: the three commands spd_dump
 * builds on BSL_CMD_READ_FLASH (0x06) and BSL_CMD_ERASE_FLASH (0x0a).
 * Unlike read_part these name no partition -- they take a raw address,
 * which is what makes them useful for the areas the table does not
 * describe (a boot chain's spare blocks, a partition's header, RAM
 * after a loader was sent to it).
 *
 * The 12-byte body is big-endian and identical in both directions:
 *   read_flash addr offset size FILE -> {addr, n, offset}
 *   read_mem   addr size FILE        -> {addr, n, 0}      (spd_dump dump_mem)
 * and the reply is BSL_REP_READ_FLASH (0x93) whose frame length is the
 * byte count, exactly the reply read_part already reads. */
static int raw_read_core(struct spd *io, uint32_t addr, uint32_t offset, uint64_t size,
	const char *out_path, const char *what, int mem_mode)
{
	FILE *fo;
	uint64_t done = 0;
	int step = io->step;
	int bad = 0;

	fo = fopen(out_path, "wb");
	if (!fo) {
		fprintf(stderr, "open %s: %s\n", out_path, strerror(errno));
		return -1;
	}
	while (done < size) {
		uint8_t req[12];
		uint64_t left = size - done;
		uint32_t n = left > (uint64_t)step ? (uint32_t)step : (uint32_t)left;
		unsigned t, plen = 0;
		const uint8_t *p;
		int got;

		if (spd_interrupted) {
			fclose(fo);
			fprintf(stderr, "interrupted; stopped %s at %llu of %llu bytes (%s left as-is)\n",
				what, (unsigned long long)done, (unsigned long long)size, out_path);
			return -1;
		}
		/* dump_flash sends a fixed address and a moving offset; dump_mem
		 * sends the moving address and a zero offset (spd_dump.c
		 * dump_mem: WRITE32_BE(data, offset), WRITE32_BE(data + 2, 0)).
		 * The loader reads from field1 + field3 either way, so the two
		 * are the same request -- but the frames are what a phone sees,
		 * and only one of the two spellings is the reference's. */
		wr32be(req, mem_mode ? addr + (uint32_t)done : addr);
		wr32be(req + 4, n);
		wr32be(req + 8, mem_mode ? 0 : offset + (uint32_t)done);
		spd_encode(io, BSL_CMD_READ_FLASH, req, 12);
		if (spd_send(io) < 0)
			die("send failed during read");
		got = spd_recv(io, io->usb.timeout_ms);
		if (got == 0)
			die("timeout during read");
		if (got < 0)
			die("device reset during read; this read was not resumed");
		t = spd_type(io);
		if (t != BSL_REP_READ_FLASH) {
			/* spd_dump prints "unexpected response" and breaks. */
			fprintf(stderr, "%s: response 0x%04x at 0x%08x+%llu\n", what, t, addr,
				(unsigned long long)(offset + done));
			bad = 1;
			break;
		}
		p = spd_payload(io, &plen);
		if (plen > n)
			die("device returned more than requested");
		if (fwrite(p, 1, plen, fo) != plen)
			die("write failed");
		done += plen;
		if (plen != n)
			break; /* short read: the device has no more to give here */
	}
	if (fclose(fo) != 0) {
		fprintf(stderr, "close %s: %s\n", out_path, strerror(errno));
		bad = 1;
	}
	fprintf(stderr, "%s: 0x%08x+%llu -> %s: %llu of %llu bytes%s\n", what, addr,
		(unsigned long long)offset, out_path, (unsigned long long)done,
		(unsigned long long)size, (bad || done != size) ? " (INCOMPLETE)" : "");
	return (!bad && done == size) ? 0 : -1;
}

/* spd_dump refuses these with `if ((addr | size | offset | (addr + offset +
 * size)) >> 32)` -- the opcode's fields are 32-bit. Spelled out rather than
 * copied so the sum cannot wrap its way past the test. */
static int over32(uint64_t a, uint64_t b, uint64_t c, const char *what)
{
	if (a > 0xffffffffu || b > 0xffffffffu || c > 0xffffffffu || a + b + c > 0xffffffffu) {
		fprintf(stderr, "%s: 32-bit limit reached (0x%llx 0x%llx 0x%llx)\n", what,
			(unsigned long long)a, (unsigned long long)b, (unsigned long long)c);
		return 1;
	}
	return 0;
}

int spd_dump_flash(struct spd *io, uint64_t addr, uint64_t offset, uint64_t size, const char *out_path)
{
	if (over32(addr, offset, size, "read_flash"))
		return -1;
	return raw_read_core(io, (uint32_t)addr, (uint32_t)offset, size, out_path, "read_flash", 0);
}

int spd_dump_mem(struct spd *io, uint64_t addr, uint64_t size, const char *out_path)
{
	if (over32(addr, size, 0, "read_mem"))
		return -1;
	return raw_read_core(io, (uint32_t)addr, 0, size, out_path, "read_mem", 1);
}

/* BSL_CMD_ERASE_FLASH: 8 big-endian bytes, address then size. spd_dump
 * ERR_EXITs on the 32-bit overflow and otherwise prints "Erase Flash Done"
 * when the loader acks. Returns 0 on ACK. */
int spd_erase_flash(struct spd *io, uint64_t addr, uint64_t size)
{
	uint8_t req[8];

	if (over32(addr, size, 0, "erase_flash"))
		return -1;
	wr32be(req, (uint32_t)addr);
	wr32be(req + 4, (uint32_t)size);
	spd_encode(io, BSL_CMD_ERASE_FLASH, req, 8);
	if (spd_check_ok(io)) {
		fprintf(stderr, "erase_flash: the loader refused 0x%08x+0x%llx\n", (uint32_t)addr,
			(unsigned long long)size);
		return -1;
	}
	fprintf(stderr, "erase_flash: 0x%08x+0x%llx done\n", (uint32_t)addr, (unsigned long long)size);
	return 0;
}

/* A misc write can rewrite the slot bytes, so the cached answer goes. Every
 * path into a partition ends at a write primitive that calls this. */
static void part_written(struct spd *io, const char *name)
{
	if (!strcmp(name, "misc"))
		spd_slot_forget(io);
}

int spd_write_part(struct spd *io, const char *name, const char *path)
{
	FILE *fi;
	uint64_t len, off;
	int step = io->step;
	int chunk_ms = io->usb.timeout_ms > 15000 ? io->usb.timeout_ms : 15000;

	fi = fopen(path, "rb");
	if (!fi) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}
	if (fseeko(fi, 0, SEEK_END) != 0)
		die("fseek");
	{
		off_t nsz = ftello(fi);
		/* A failed ftello is -1. Casting that to uint64_t would start a huge write. */
		if (nsz < 0)
			die("ftell");
		len = (uint64_t)nsz;
	}
	if (fseeko(fi, 0, SEEK_SET) != 0)
		die("fseek");
	/* spd_dump waits 100s per chunk when the file is an Android sparse image.
	 * The container is still sent as raw bytes. Other writes stay at 15s. */
	{
		int sparse = 0;
		if (len >= 4) {
			uint8_t mag[4];
			if (fread(mag, 1, 4, fi) != 4)
				die("short read");
			sparse = mag[0] == 0x3a && mag[1] == 0xff && mag[2] == 0x26 && mag[3] == 0xed;
			if (fseeko(fi, 0, SEEK_SET) != 0)
				die("fseek");
		}
		if (sparse) {
			chunk_ms = io->usb.timeout_ms > 100000 ? io->usb.timeout_ms : 100000;
			fprintf(stderr, "write %s: sparse image, waiting up to %d ms per chunk\n",
				name, chunk_ms);
		}
	}
	fprintf(stderr, "write %s: %llu bytes from %s\n", name, (unsigned long long)len, path);

	part_written(io, name);
	select_part(io, name, len, BSL_CMD_START_DATA);
	if (spd_check_ok(io)) {
		/* spd_dump's load_partition closes the file and returns on a
		 * refused START -- no END_DATA, since the loader never entered
		 * the transfer. Returning instead of exiting lets the caller
		 * report this partition and stop cleanly. */
		fclose(fi);
		return -1;
	}
	for (off = 0; off < len; ) {
		uint64_t left = len - off;
		size_t n = left > (uint64_t)step ? (size_t)step : (size_t)left;
		if (spd_interrupted) {
			fclose(fi);
			fprintf(stderr, "interrupted; stopped write at %llu of %llu bytes into '%s'"
				" (partition is now incomplete)\n",
				(unsigned long long)off, (unsigned long long)len, name);
			return -1;
		}
		if (fread(io->temp, 1, n, fi) != n)
			die("short read");
		spd_encode(io, BSL_CMD_MIDST_DATA, io->temp, n);
		if (spd_send(io) < 0)
			die("send failed during write");
		{
			int got = spd_recv(io, chunk_ms);
			if (got == 0)
				die("timeout during write");
			if (got < 0)
				die("device reset during write; this write was not resumed");
		}
		if (spd_type(io) != BSL_REP_ACK) {
			/* spd_dump's load_partition breaks out of the loop here
			 * and still sends END_DATA, so the loader is not left
			 * mid-transfer waiting for the rest of a partition we
			 * have abandoned. Match that traffic, then report the
			 * failure instead of ending the process: the caller
			 * decides, and the loader is left in a clean state. */
			fprintf(stderr, "write response 0x%04x at offset %llu\n",
				spd_type(io), (unsigned long long)off);
			fclose(fi);
			spd_encode(io, BSL_CMD_END_DATA, NULL, 0);
			(void)spd_check_ok(io);
			return -1;
		}
		off += n;
	}
	fclose(fi);
	spd_encode(io, BSL_CMD_END_DATA, NULL, 0);
	if (spd_check_ok(io)) {
		/* spd_dump only omits its "Write Part Done" line here and carries
		 * on. Report the failure (every byte did get sent, so the caller
		 * may still want to verify) without killing the process. */
		return -1;
	}
	return 0;
}

int spd_write_part_buf(struct spd *io, const char *name, const uint8_t *buf, size_t len)
{
	uint64_t off;
	int step = io->step;
	int chunk_ms = io->usb.timeout_ms > 15000 ? io->usb.timeout_ms : 15000;

	if (!buf) {
		fprintf(stderr, "write-part-buf: null buffer\n");
		return -1;
	}
	if (len >= 4 && buf[0] == 0x3a && buf[1] == 0xff && buf[2] == 0x26 && buf[3] == 0xed) {
		chunk_ms = io->usb.timeout_ms > 100000 ? io->usb.timeout_ms : 100000;
		fprintf(stderr, "write %s: sparse image, waiting up to %d ms per chunk\n",
			name, chunk_ms);
	}
	fprintf(stderr, "write %s: %zu bytes from buffer\n", name, len);

	part_written(io, name);
	select_part(io, name, (uint64_t)len, BSL_CMD_START_DATA);
	if (spd_check_ok(io)) {
		/* As in spd_write_part: the reference returns without END_DATA
		 * when the loader refuses the START. */
		return -1;
	}
	for (off = 0; off < (uint64_t)len; ) {
		uint64_t left = (uint64_t)len - off;
		size_t n = left > (uint64_t)step ? (size_t)step : (size_t)left;
		if (spd_interrupted) {
			fprintf(stderr, "interrupted; stopped write at %llu of %llu bytes into '%s'"
				" (partition is now incomplete)\n",
				(unsigned long long)off, (unsigned long long)len, name);
			return -1;
		}
		spd_encode(io, BSL_CMD_MIDST_DATA, buf + off, n);
		if (spd_send(io) < 0)
			die("send failed during write");
		{
			int got = spd_recv(io, chunk_ms);
			if (got == 0)
				die("timeout during write");
			if (got < 0)
				die("device reset during write; this write was not resumed");
		}
		if (spd_type(io) != BSL_REP_ACK) {
			/* As in spd_write_part: break like spd_dump's
			 * load_partition, still send END_DATA, then fail. */
			fprintf(stderr, "write response 0x%04x at offset %llu\n",
				spd_type(io), (unsigned long long)off);
			spd_encode(io, BSL_CMD_END_DATA, NULL, 0);
			(void)spd_check_ok(io);
			return -1;
		}
		off += n;
	}
	spd_encode(io, BSL_CMD_END_DATA, NULL, 0);
	if (spd_check_ok(io)) {
		/* Same as spd_write_part: fail, but let the caller decide. */
		return -1;
	}
	return 0;
}

int spd_erase_part(struct spd *io, const char *name)
{
	select_part(io, name, 0, BSL_CMD_ERASE_FLASH);
	if (spd_check_ok(io))
		return -1;
	/* An erased misc no longer holds the bootloader_control block, so the
	 * cached slot answer is not the device's any more. */
	if (!strcmp(name, "misc"))
		spd_slot_forget(io);
	fprintf(stderr, "erased %s\n", name);
	return 0;
}

void spd_slot_forget(struct spd *io)
{
	io->slot_known = 0;
}

void spd_slot_set(struct spd *io, int slot)
{
	io->slot = slot;
	io->slot_known = 1;
}

/* AOSP bootloader_control (spd_dump common.h:177-192, packed): slot_suffix[4],
 * magic, version, then nb_slot:3 | recovery_tries:3 | merge_status:3, then
 * slot_metadata slot_info[4] of 2 bytes each -- priority:4, tries_remaining:3,
 * successful_boot:1. ABC is those 32 bytes, already sliced at misc+0x800.
 * AB_COMPARE_SLOTS(slot_info[1], slot_info[0]) < 0 means slot b (common.c:2011):
 * higher priority wins, then the one that booted successfully, then the one with
 * more tries left. Returns 1/2, or 0 when the device is not A/B. */
int spd_slot_from_bytes(const uint8_t *abc, int have_uboot_a)
{
	int nb, p0, p1, ok0, ok1, t0, t1, d;

	nb = abc[9] & 7;
	if (nb != 2)
		return 0;
	p0 = abc[12] & 15; t0 = (abc[12] >> 4) & 7; ok0 = abc[12] >> 7;
	p1 = abc[14] & 15; t1 = (abc[14] >> 4) & 7; ok1 = abc[14] >> 7;
	if (p1 != p0) d = p0 - p1;
	else if (ok1 != ok0) d = ok0 - ok1;
	else d = t0 - t1;
	if (!have_uboot_a)
		return 0; /* spd_dump: no uboot_a means not really A/B */
	return d < 0 ? 2 : 1;
}

/* spd_dump partition_list() applies this while it walks the table it just read
 * (common.c:1046-1049 on the GPT path, 1131-1134 on the SPRD one): when
 * select_ab() came back 0, the first row whose name ends in "_a" means the
 * device is A/B after all and slot A is the one in use. Without it a table
 * naming boot_a/boot_b reads as "not A/B" and the dump stops preferring the
 * slot-A rows the way the reference's does. */
int spd_slot_from_table(const struct spd *io)
{
	int i;
	for (i = 0; i < io->nparts; i++) {
		size_t l = strlen(io->ptab[i].name);
		if (l > 2 && !strcmp(io->ptab[i].name + l - 2, "_a"))
			return 1;
	}
	return 0;
}

/* spd_dump select_ab() (common.c:1988): read the 32-byte bootloader_control at
 * misc+0x800 and ask the device which slot it is running. A refused READ_START,
 * a reply that is not a read, or an nb_slot that is not 2 all mean "not A/B";
 * so does a phone that kept no uboot_a, which the reference checks with a real
 * partition probe. Leaves io->slot_bcb set (the reference's `selected_ab`).
 *
 * This is the read the reference puts on the wire at the FDL2 stage, before the
 * table, so it is also where ours goes -- see fetch_ptab(). */
static int select_ab(struct spd *io)
{
	uint8_t req[8], abc[32];
	const uint8_t *p;
	unsigned plen = 0;
	int have_abc = 0, slot;

	select_part(io, "misc", 0x820, BSL_CMD_READ_START);
	if (wait_ack(io, 1)) {
		read_end(io);
		io->slot_bcb = 0;
		return 0;
	}
	wr32le(req, 0x20);
	wr32le(req + 4, 0x800);
	spd_encode(io, BSL_CMD_READ_MIDST, req, 8);
	if (spd_send(io) < 0)
		die("send failed while reading the active slot");
	{
		int got = spd_recv(io, io->usb.timeout_ms);
		if (got == 0)
			die("timeout reached");
		if (got < 0)
			die("device reset while reading the active slot");
	}
	if (spd_type(io) == BSL_REP_READ_FLASH) {
		p = spd_payload(io, &plen);
		/* The reference copies the reply into its bootloader_control without
		 * looking at the length. Ours needs the 20 bytes it reads -- short of
		 * those, "not A/B" is the only honest answer. */
		if (plen >= 20) {
			memset(abc, 0, sizeof(abc));
			memcpy(abc, p, plen < sizeof(abc) ? plen : sizeof(abc));
			have_abc = 1;
		}
	}
	read_end(io);
	if (!have_abc) {
		io->slot_bcb = 0;
		return 0;
	}
	memcpy(io->slot_abc, abc, sizeof(abc));
	io->slot_abc_valid = 1;
	slot = spd_slot_from_bytes(abc, 1);
	/* common.c:2014: a device that cannot find uboot_a is not A/B, whatever the
	 * block says. check_partition() is the reference's own probe -- and the two
	 * frames it adds here are frames the reference sends too. */
	if (slot > 0 && spd_check_partition(io, "uboot_a", 0, slot) == 0)
		slot = 0;
	io->slot_bcb = slot;
	return slot;
}

/* CRC-16/ARC, the checksum spd_dump puts in a fixnv image before sending it. */
static uint16_t crc16_arc(const uint8_t *p, size_t n)
{
	uint16_t crc = 0;
	while (n--) {
		int b;
		crc ^= *p++;
		for (b = 0; b < 8; b++)
			crc = (crc & 1) ? (uint16_t)((crc >> 1) ^ 0xA001) : (uint16_t)(crc >> 1);
	}
	return crc;
}

/* Walk a fixnv blob the way spd_dump load_nv_partition does. On success MEM
 * is the body (after an optional 0x4e56 + 0x200 header) and *LEN is the
 * framed length, including the 8 bytes after 0xffff. */
static int nv_frame(uint8_t *mem, size_t flen, size_t *len_out)
{
	size_t len;
	if (flen >= 4 && rd32le(mem) == 0x4e56u) {
		if (flen < 0x200 + 4)
			return -1;
		mem += 0x200;
		flen -= 0x200;
	}
	len = 4;
	for (;;) {
		uint16_t id, n;
		uint32_t pad;
		if (len + 4 > flen)
			return -1;
		id = (uint16_t)(mem[len] | (mem[len + 1] << 8));
		n = (uint16_t)(mem[len + 2] | (mem[len + 3] << 8));
		(void)id;
		if (!n)
			return -1;
		len += 4u + n;
		if (len > flen)
			return -1;
		pad = ((len + 3u) & ~3u) - (uint32_t)len;
		if (len + pad + 2 > flen)
			return -1;
		len += pad;
		if ((uint16_t)(mem[len] | (mem[len + 1] << 8)) == 0xffff) {
			if (len + 8 > flen)
				return -1;
			len += 8;
			break;
		}
	}
	*len_out = len;
	return 0;
}

int spd_nv_image_ok(const char *path)
{
	FILE *fi;
	uint8_t *mem;
	size_t flen, len;
	off_t sz;

	fi = fopen(path, "rb");
	if (!fi)
		return -1;
	if (fseeko(fi, 0, SEEK_END) != 0 || (sz = ftello(fi)) < 4 ||
		(unsigned long long)sz > (unsigned long long)SIZE_MAX ||
		fseeko(fi, 0, SEEK_SET) != 0) {
		fclose(fi);
		return -1;
	}
	flen = (size_t)sz;
	mem = malloc(flen);
	if (!mem || fread(mem, 1, flen, fi) != flen) {
		free(mem);
		fclose(fi);
		return -1;
	}
	fclose(fi);
	if (nv_frame(mem, flen, &len)) {
		free(mem);
		return -1;
	}
	free(mem);
	return 0;
}

int spd_write_nv(struct spd *io, const char *name, const char *path)
{
	FILE *fi;
	uint8_t *mem, *body, pkt[80];
	size_t flen, len, off;
	uint16_t crc;
	uint32_t cs;
	int step = 4096; /* spd_dump load_nv_partition ignores blk_size and uses 4096 */
	off_t sz;

	fi = fopen(path, "rb");
	if (!fi) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}
	if (fseeko(fi, 0, SEEK_END) != 0 || (sz = ftello(fi)) < 4 ||
		(unsigned long long)sz > (unsigned long long)SIZE_MAX ||
		fseeko(fi, 0, SEEK_SET) != 0) {
		fprintf(stderr, "write nv %s: %s is not an NV image\n", name, path);
		fclose(fi);
		return -1;
	}
	flen = (size_t)sz;
	mem = malloc(flen);
	if (!mem || fread(mem, 1, flen, fi) != flen) {
		fprintf(stderr, "write nv %s: short read\n", name);
		free(mem);
		fclose(fi);
		return -1;
	}
	fclose(fi);
	body = mem;
	if (rd32le(mem) == 0x4e56u)
		body = mem + 0x200;
	if (nv_frame(mem, flen, &len)) {
		fprintf(stderr,
			"write nv %s: not an NV image (spd_dump skips a broken fixnv1 file); nothing sent\n",
			name);
		free(mem);
		return -1;
	}
	crc = crc16_arc(body + 2, len - 2);
	body[0] = (uint8_t)(crc >> 8);
	body[1] = (uint8_t)crc;
	cs = 0;
	for (off = 0; off < len; off++)
		cs += body[off];
	fprintf(stderr, "write nv %s: framed %zu bytes, checksum 0x%x\n", name, len, cs);
	memset(pkt, 0, sizeof(pkt));
	if (put_name(pkt, 36, name))
		die("partition name too long");
	wr32le(pkt + 72, (uint32_t)len);
	wr32le(pkt + 76, cs);
	spd_encode(io, BSL_CMD_START_DATA, pkt, sizeof(pkt));
	if (spd_check_ok(io)) {
		free(mem);
		return -1;
	}
	for (off = 0; off < len; ) {
		size_t n = len - off;
		if (n > (size_t)step)
			n = (size_t)step;
		spd_encode(io, BSL_CMD_MIDST_DATA, body + off, n);
		if (spd_send(io) < 0)
			die("send failed during write");
		{
			int got = spd_recv(io, io->usb.timeout_ms > 15000 ? io->usb.timeout_ms : 15000);
			if (got == 0)
				die("timeout during write");
			if (got < 0)
				die("device reset during write; this write was not resumed");
		}
		if (spd_type(io) != BSL_REP_ACK) {
			/* spd_dump's load_nv_partition breaks and still sends
			 * END_DATA after a non-ACK; returning here without it
			 * left the loader mid-transfer for the next command. */
			fprintf(stderr, "write nv response 0x%04x at offset %zu\n", spd_type(io), off);
			free(mem);
			spd_encode(io, BSL_CMD_END_DATA, NULL, 0);
			(void)spd_check_ok(io);
			return -1;
		}
		off += n;
	}
	free(mem);
	spd_encode(io, BSL_CMD_END_DATA, NULL, 0);
	if (spd_check_ok(io))
		return -1;
	return 0;
}

/* One <Partition id="NAME" size="NUM"/> record. NUM is decimal or 0x hex
 * (spd_dump's own partition_list writer emits 0xffffffff for the last row). */
static int xml_one(const char *tag, char *name, size_t namecap, uint32_t *size)
{
	const char *id, *ide, *sz, *sze;
	char *end;
	unsigned long long v;
	size_t n;
	if (strncmp(tag, "Partition", 9) != 0)
		return -1;
	id = strstr(tag, "id=\"");
	sz = strstr(tag, "size=\"");
	if (!id || !sz)
		return -1;
	id += 4;
	ide = strchr(id, '"');
	sz += 6;
	sze = strchr(sz, '"');
	if (!ide || !sze || ide == id)
		return -1;
	n = (size_t)(ide - id);
	if (n >= namecap || n > 35)
		return -1;
	memcpy(name, id, n);
	name[n] = 0;
	errno = 0;
	v = strtoull(sz, &end, 0);
	if (end == sz || end != sze || errno || v > 0xffffffffull)
		return -1;
	*size = (uint32_t)v;
	return 0;
}

/* The one reader of a partition list XML: the file spd_dump's repartition
 * takes and the one its read_parts takes are the same document, so both go
 * through here and cannot drift apart on what a record means. WHAT names the
 * caller in the messages. */
int spd_xml_partitions(const char *path, const char *what, struct spd_xml_part **out)
{
	FILE *fi;
	char *src, *p, *end;
	off_t sz;
	int n = 0, cap;
	struct spd_xml_part *list;

	*out = NULL;
	fi = fopen(path, "rb");
	if (!fi) {
		fprintf(stderr, "%s: open %s: %s\n", what, path, strerror(errno));
		return -1;
	}
	if (fseeko(fi, 0, SEEK_END) != 0 || (sz = ftello(fi)) <= 0 || sz > 1024 * 1024 ||
		fseeko(fi, 0, SEEK_SET) != 0) {
		fprintf(stderr, "%s: %s is empty or over 1 MiB\n", what, path);
		fclose(fi);
		return -1;
	}
	src = malloc((size_t)sz + 1);
	if (!src || fread(src, 1, (size_t)sz, fi) != (size_t)sz) {
		fprintf(stderr, "%s: short read\n", what);
		free(src);
		fclose(fi);
		return -1;
	}
	fclose(fi);
	if (memchr(src, 0, (size_t)sz)) {
		fprintf(stderr, "%s: XML contains a zero byte\n", what);
		free(src);
		return -1;
	}
	src[sz] = 0;
	p = strstr(src, "<Partitions>");
	end = p ? strstr(p, "</Partitions>") : NULL;
	if (!p || !end || strstr(end + 1, "<Partitions>")) {
		fprintf(stderr, "%s: need one <Partitions> list\n", what);
		free(src);
		return -1;
	}
	/* The frame limit, so a list this long is refused here rather than by
	 * spd_repartition_xml after the entries have been built. */
	cap = 0xffff / 0x4c;
	list = calloc((size_t)cap, sizeof(*list));
	if (!list) {
		free(src);
		return -1;
	}
	p += strlen("<Partitions>");
	while (p < end) {
		char *lt, *gt;
		while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'))
			p++;
		if (p >= end)
			break;
		if (*p != '<') {
			fprintf(stderr, "%s: unexpected text in <Partitions>\n", what);
			goto bad;
		}
		if (!strncmp(p, "<!--", 4)) {
			char *c = strstr(p + 4, "-->");
			if (!c || c >= end) {
				fprintf(stderr, "%s: unclosed comment\n", what);
				goto bad;
			}
			p = c + 3;
			continue;
		}
		lt = p + 1;
		gt = strchr(lt, '>');
		if (!gt || gt >= end) {
			fprintf(stderr, "%s: unclosed tag\n", what);
			goto bad;
		}
		*gt = 0;
		if (n >= cap) {
			fprintf(stderr, "%s: more than %d partitions (frame limit)\n", what, cap);
			goto bad;
		}
		if (xml_one(lt, list[n].name, sizeof(list[n].name), &list[n].size)) {
			fprintf(stderr, "%s: bad Partition tag near '%s'\n", what, lt);
			goto bad;
		}
		n++;
		p = gt + 1;
	}
	free(src);
	if (n < 1) {
		fprintf(stderr, "%s: no Partition entries\n", what);
		free(list);
		return -1;
	}
	*out = list;
	return n;
bad:
	free(src);
	free(list);
	return -1;
}

int spd_repartition_xml(struct spd *io, const char *path)
{
	uint8_t *buf, *w, *sent;
	struct spd_xml_part *list = NULL;
	int n, i;

	n = spd_xml_partitions(path, "repartition", &list);
	if (n < 0)
		return -1;
	buf = calloc((size_t)n, 0x4c);
	if (!buf) {
		free(list);
		return -1;
	}
	w = buf;
	for (i = 0; i < n; i++) {
		int k;
		memset(w, 0, 0x4c);
		for (k = 0; list[i].name[k]; k++)
			w[k * 2] = (uint8_t)list[i].name[k];
		wr32le(w + 0x48, list[i].size);
		fprintf(stderr, "repartition: [%d] %s size=%u\n", i + 1, list[i].name, list[i].size);
		w += 0x4c;
	}
	free(list);
	sent = buf;
	spd_encode(io, BSL_CMD_REPARTITION, sent, (size_t)n * 0x4c);
	if (spd_check_ok(io)) {
		fprintf(stderr, "repartition: device refused the table; partition layout unchanged by this ack\n");
		free(buf);
		return -1;
	}
	/* spd_dump scan_xml_partitions() rewrites io->ptable from the XML, so a
	 * command after the repartition in the same session -- a `write-part
	 * <name> FILE` for the partition just enlarged, which is the reason to
	 * repartition at all -- resolves against the NEW layout. Without this the
	 * next write answered "not in the live partition table" for an added
	 * partition, and refused a file the enlarged partition now holds.
	 * The XML's size is MiB and ptab holds bytes, as spd_dump's size << 20. */
	free(io->ptab);
	io->ptab = calloc((size_t)n, sizeof(*io->ptab));
	if (!io->ptab)
		die("out of memory");
	io->nparts = n;
	for (i = 0; i < n; i++) {
		const uint8_t *rec = sent + (size_t)i * 0x4c;
		unsigned k;
		for (k = 0; k < 36 && rec[k * 2]; k++)
			io->ptab[i].name[k] = (char)rec[k * 2];
		io->ptab[i].name[k] = 0;
		io->ptab[i].size = (uint64_t)rd32le(rec + 0x48) << 20;
	}
	/* The XML is MiB and so is the shift that turns it back into bytes, so an
	 * echo of this table later (spd_repartition_echo, for a force write) uses
	 * the same unit the XML did. fetch_ptab sets it from the wire instead. */
	io->ptab_shift = 20;
	/* The session has a table (the one just sent), so the latch is "asked and
	 * answered": spd_dump's gpt_failed is already 0 here and scan_xml_partitions
	 * rewrites io->ptable in place, so a later partition_list prints the new
	 * layout rather than re-reading one the phone has not applied yet. */
	io->ptab_state = 0;
	free(buf);
	fprintf(stderr, "repartition: sent %d entries; this session now resolves names and sizes against the new layout, and `parts` prints that same layout until the phone restarts.\n", n);
	return 0;
}

/* Send the live table back to the device, with row IDX renamed to NEWNAME
 * (IDX < 0 = send it unchanged). spd_dump load_partition_force() (common.c
 * ~1302) does exactly this twice around a write: rename the target to
 * "w_force", write to that name, send the original table again. The loader
 * refuses a direct write to a name it knows -- its own list of partition
 * names and sizes -- and a name it has never heard of is not checked.
 *
 * The unit is MiB, the same one the XML carries and the same one spd_dump's
 * load_partition_force writes (`size >> 20`) -- this table goes back to the
 * DEVICE, and the device reads the repartition payload in the unit
 * scan_xml_partitions writes into it, which is the XML's MiB unchanged. io->ptab
 * holds bytes whichever unit the read used, so the conversion here is the fixed
 * >> 20 and not the read shift.
 * 0 = accepted, -1 = refused. io->ptab is left alone either way. */
int spd_repartition_echo(struct spd *io, int idx, const char *newname)
{
	uint8_t *buf, *w;
	int i;

	if (io->nparts < 1 || !io->ptab)
		return -1;
	if (idx >= io->nparts) {
		fprintf(stderr, "repartition: row %d is past the %d-entry table\n", idx + 1, io->nparts);
		return -1;
	}
	buf = calloc((size_t)io->nparts, 0x4c);
	if (!buf)
		die("out of memory");
	w = buf;
	for (i = 0; i < io->nparts; i++) {
		const char *nm = (i == idx) ? newname : io->ptab[i].name;
		unsigned k;
		if (strlen(nm) > 35) {
			fprintf(stderr, "repartition: name '%s' does not fit a table entry\n", nm);
			free(buf);
			return -1;
		}
		for (k = 0; nm[k]; k++)
			w[k * 2] = (uint8_t)nm[k];
		/* The last row is ~0, "take the rest", exactly as the XML path and
		 * spd_dump's partition_list write it. A real byte size there would
		 * cut the last partition to that value. */
		if (i + 1 == io->nparts)
			wr32le(w + 0x48, ~0u);
		else
			wr32le(w + 0x48, (uint32_t)(io->ptab[i].size >> 20));
		w += 0x4c;
	}
	spd_encode(io, BSL_CMD_REPARTITION, buf, (size_t)io->nparts * 0x4c);
	free(buf);
	return spd_check_ok(io) ? -1 : 0;
}

/* The XML body spd_dump writes and reads back: one row per table entry, the
 * size in MiB, and the last row as 0xffffffff ("take the rest", which is what a
 * table ends with). `partition-list` writes this to the file the user names and
 * the automatic copy below writes the same bytes, so either one can be edited
 * and handed to `repartition`.
 *
 * MiB is not an assumption about the wire unit, it is the format: spd_dump
 * writes this file with a fixed `size >> 20` and reads it back with
 * `size << 20` (common.c scan_xml_partitions), writing the same number into
 * the device table unconverted. The wire unit is whatever fetch_ptab's divisor
 * found -- KiB on an eMMC whose rows are all >= 1 MiB -- so `>> ptab_shift`
 * here is NOT the same number: on a divisor-10 table it writes every row 1024x
 * too large, and feeding that back would claim a 5 GiB super was 5 TiB. The
 * divisor normalises the READ; the XML is MiB either way. */
static void xml_body(FILE *fo, const struct spd *io, unsigned count)
{
	unsigned i;

	fprintf(fo, "<Partitions>\n");
	for (i = 0; i < count; i++) {
		fprintf(fo, "    <Partition id=\"%s\" size=\"", io->ptab[i].name);
		if (i + 1 == count)
			fprintf(fo, "0x%x\"/>\n", ~0u);
		else
			fprintf(fo, "%llu\"/>\n", (unsigned long long)(io->ptab[i].size >> 20));
	}
	/* No trailing newline: the reference's own partition_list CLI writes the
	 * closing tag bare (spd_dump.c ~1047), and its repartition reads either.
	 * Byte-identical output is easier to assert. */
	fprintf(fo, "</Partitions>");
}

/* spd_dump leaves partition_<unixtime>.xml (spd_dump.c:191) wherever it runs,
 * on every session that reads the table, so a user always has the file a
 * repartition edit is made from. spdhost writes the same file into
 * io->part_xml_dir -- the menu points that at the dump folder, so it lands
 * beside the dumps instead of in whatever directory the tool was started in.
 *
 * One name per process, as the reference picks its name once at startup: a
 * session that reads the table twice (parts, then partition-list) rewrites its
 * own copy rather than leaving two files. A failure is a warning and nothing
 * more -- the file is a convenience, and losing it must not cost the dump or
 * the write the user actually asked for. */
static void part_xml_auto(struct spd *io, unsigned count)
{
	static char path[512];
	static int named, warned;
	FILE *fo;

	if (!io->part_xml_dir || !io->part_xml_dir[0])
		return;
	if (!named) {
		int n;

		named = 1;
		n = snprintf(path, sizeof(path), "%s/partition_%lld.xml",
			io->part_xml_dir, (long long)time(NULL));
		if (n < 0 || (size_t)n >= sizeof(path)) {
			fprintf(stderr, "auto partition xml: %s/partition_<time>.xml is too long;"
				" skipped (the session continues)\n", io->part_xml_dir);
			path[0] = 0;
			return;
		}
	}
	if (!path[0])
		return;
	fo = fopen(path, "w");
	if (!fo) {
		if (!warned++)
			fprintf(stderr, "auto partition xml: open %s: %s (the session continues)\n",
				path, strerror(errno));
		return;
	}
	xml_body(fo, io, count);
	if (fclose(fo) != 0) {
		if (!warned++)
			fprintf(stderr, "auto partition xml: write %s: %s (the session continues)\n",
				path, strerror(errno));
		remove(path);
		return;
	}
	fprintf(stderr, "partition xml: %s (%u entries)\n", path, count);
}

/* The device's raw table packet, as "sprdpart.bin" in the dump folder (or the
 * cwd when none was named, which is where the reference's savepath points). A
 * failure is a warning: the XML and the in-memory table are what the command
 * the user asked for actually needs. */
static void save_raw_ptab(const struct spd *io, const uint8_t *p, unsigned count)
{
	char path[1200];
	FILE *fo;
	int n;

	n = snprintf(path, sizeof(path), "%s/sprdpart.bin",
		io->part_xml_dir && io->part_xml_dir[0] ? io->part_xml_dir : ".");
	if (n <= 0 || (size_t)n >= sizeof(path)) {
		fprintf(stderr, "partition-list: sprdpart.bin path is too long; skipped\n");
		return;
	}
	fo = fopen(path, "wb");
	if (!fo) {
		fprintf(stderr, "partition-list: create %s: %s (the session continues)\n",
			path, strerror(errno));
		return;
	}
	if (fwrite(p, 1, (size_t)count * 0x4c, fo) != (size_t)count * 0x4c || fclose(fo) != 0) {
		fprintf(stderr, "partition-list: create %s failed (the session continues)\n", path);
		remove(path);
		return;
	}
	fprintf(stderr, "partition-list: sprd partition list packet saved to %s\n", path);
}

/* ---------------------------------------------------------------- *
 * The standard-GPT half of spd_dump partition_list() (common.c:1075-1078
 * and gpt_info, common.c:976-1061).
 *
 * Before it asks for the SPRD packet, the reference reads the first 32 KiB of
 * the `user_partition` partition and looks for an EFI header in it. A phone
 * whose storage was laid out with a generic GPT -- one that was reflashed with
 * a standard table, or whose vendor kept the Google layout -- answers here and
 * has no SPRD packet at all, so this is the only way its table is ever read.
 * A phone with an SPRD table (the usual case) refuses the read, pgpt.bin is
 * removed, and the packet read below runs exactly as it did before.
 */

#define GPT_PROBE_BYTES (32u * 1024u)  /* spd_dump: 32*1024 at step 4096 */
#define GPT_PROBE_STEP 4096u
#define GPT_SECTOR_SIZE 512u           /* common.c:973 */
#define GPT_MAX_SECTORS 32u            /* common.c:974 */
#define GPT_ENTRY_BYTES 128u           /* sizeof(efi_entry), packed */
#define GPT_ENTRY_CAP 4096u            /* allocation guard; see below */

static void part_dir_path(const struct spd *io, const char *name, char *out, size_t cap)
{
	int n = snprintf(out, cap, "%s/%s",
		io->part_xml_dir && io->part_xml_dir[0] ? io->part_xml_dir : ".", name);
	if (n <= 0 || (size_t)n >= cap)
		out[0] = 0;
}

/* The `user_partition` read and the GPT parse. 0 = the table came from a
 * standard GPT (io->ptab filled, io->nparts set, pgpt.bin kept, the XML
 * written), -1 = fall back to the SPRD packet (pgpt.bin removed if it was
 * made). Everything it does on -1 is what the reference does on gpt_failed. */
static int gpt_probe(struct spd *io)
{
	char path[1200];
	uint8_t sec[GPT_SECTOR_SIZE];
	uint64_t entry_lba, real_sector;
	int sector_index = -1, nent, entsz, n, i, storage;
	FILE *fi;

	part_dir_path(io, "pgpt.bin", path, sizeof(path));
	if (!path[0]) {
		fprintf(stderr, "partition-list: pgpt.bin path is too long; skipped\n");
		return -1;
	}
	io->step = (int)GPT_PROBE_STEP;
	if (read_part_core_q(io, "user_partition", 0, GPT_PROBE_BYTES, path, NULL, 1) != 0) {
		remove(path);
		return -1;
	}
	/* spd_dump: `if (32 * 1024 == size) gpt_failed = gpt_info(...)`. A short
	 * read is not a table, and the file it left is not useful either. */
	fi = fopen(path, "rb");
	if (!fi) {
		fprintf(stderr, "partition-list: open %s: %s\n", path, strerror(errno));
		return -1;
	}
	for (i = 0; i < (int)GPT_MAX_SECTORS; i++) {
		if (fread(sec, 1, sizeof(sec), fi) != sizeof(sec))
			break;
		if (!memcmp(sec, "EFI PART", 8)) {
			sector_index = i;
			break;
		}
	}
	if (sector_index < 0) {
		fclose(fi);
		remove(path); /* gpt_failed: the reference removes pgpt.bin too */
		return -1;
	}
	/* common.c:1007: the header at LBA 1 means 512-byte sectors and eMMC; found
	 * anywhere else (a 4 KiB-sector disk puts it at index 8) means UFS. */
	real_sector = (uint64_t)GPT_SECTOR_SIZE * (uint64_t)sector_index;
	storage = (sector_index == 1) ? SPD_STORAGE_EMMC : SPD_STORAGE_UFS;
	if (real_sector == 0) {
		/* A header at offset 0: the reference divides by it and reads the
		 * garbage at offset 0 as the entry array. Nothing sane to do with it. */
		fprintf(stderr, "partition-list: GPT header at sector 0; not a usable table\n");
		fclose(fi);
		remove(path);
		return -1;
	}
	entry_lba = rd64le(sec + 72);
	nent = (int)rd32le(sec + 80);
	entsz = (int)rd32le(sec + 84);
	if (nent <= 0 || entsz < (int)GPT_ENTRY_BYTES) {
		fprintf(stderr, "partition-list: GPT says %d entries of %d bytes; not a usable table\n",
			nent, entsz);
		fclose(fi);
		remove(path);
		return -1;
	}
	if ((uint32_t)nent > GPT_ENTRY_CAP)
		nent = (int)GPT_ENTRY_CAP;
	/* The reference allocates nent * sizeof(efi_entry) and reads that much,
	 * then walks whatever the short read left behind. Ours reads only what the
	 * 32 KiB probe actually holds -- the entry array cannot be longer than the
	 * buffer it was dumped into. */
	{
		uint64_t off = entry_lba * real_sector;
		uint64_t avail = off < GPT_PROBE_BYTES ? GPT_PROBE_BYTES - off : 0;
		uint64_t fits = avail / GPT_ENTRY_BYTES;
		if ((uint64_t)nent > fits) {
			fprintf(stderr, "partition-list: GPT entry array is %llu bytes past the %u-byte probe;"
				" reading %llu entries\n", (unsigned long long)((uint64_t)nent * GPT_ENTRY_BYTES),
				GPT_PROBE_BYTES, (unsigned long long)fits);
			nent = (int)fits;
		}
		if (nent <= 0) {
			fclose(fi);
			remove(path);
			return -1;
		}
		if (fseeko(fi, (off_t)off, SEEK_SET) != 0) {
			fprintf(stderr, "partition-list: seek %s: %s\n", path, strerror(errno));
			fclose(fi);
			remove(path);
			return -1;
		}
	}
	{
		uint8_t *rec = calloc((size_t)nent, GPT_ENTRY_BYTES);
		if (!rec)
			die("out of memory");
		if (fread(rec, GPT_ENTRY_BYTES, (size_t)nent, fi) != (size_t)nent) {
			fprintf(stderr, "partition-list: short read of the GPT entry array\n");
			free(rec);
			fclose(fi);
			remove(path);
			return -1;
		}
		/* spd_dump stops at the first entry whose LBA range is empty and calls
		 * that the count (common.c:1029-1033); a full table with no empty entry
		 * leaves its n at 0, which reads as "no table". Ours takes all nent
		 * then, which is the only reading that keeps the rows. */
		n = nent;
		for (i = 0; i < nent; i++) {
			const uint8_t *e = rec + (size_t)i * GPT_ENTRY_BYTES;
			if (rd64le(e + 32) == 0 && rd64le(e + 40) == 0) {
				n = i;
				break;
			}
		}
		free(io->ptab);
		io->ptab = calloc(n ? (size_t)n : 1, sizeof(*io->ptab));
		if (!io->ptab)
			die("out of memory");
		io->nparts = n;
		for (i = 0; i < n; i++) {
			/* sizeof(efi_entry) == 128: type GUID 0..15, unique GUID 16..31,
			 * starting_lba 32, ending_lba 40, attributes 48, then the
			 * partition_name as 36 UTF-16LE wchars at 56 (72 bytes, to the end
			 * of the record). gpt_info() reads it through
			 * `entry.partition_name` (common.c:1037); reading it from 0 -- the
			 * type GUID, which a real table always fills with a nonzero GUID --
			 * gave every row an empty or mojibake name. */
			const uint8_t *e = rec + (size_t)i * GPT_ENTRY_BYTES;
			uint64_t start = rd64le(e + 32), end = rd64le(e + 40);
			unsigned k;
			for (k = 0; k < 36 && e[56 + k * 2]; k++)
				io->ptab[i].name[k] = (char)e[56 + k * 2];
			io->ptab[i].name[k] = 0;
			io->ptab[i].size = (end - start + 1) * real_sector;
		}
		free(rec);
	}
	fclose(fi);
	io->storage = storage;
	/* Sizes here are bytes already, and the XML is MiB whichever path wrote it
	 * (xml_body fixes the shift at 20), so the read shift is 20 for the same
	 * reason the repartition echo's is. */
	io->ptab_shift = 20;
	fprintf(stderr, "parts: %d entries from the standard GPT (%llu-byte sectors)\n",
		io->nparts, (unsigned long long)real_sector);
	fprintf(stderr, "Storage is %s\n", storage == SPD_STORAGE_EMMC ? "emmc" : "ufs");
	/* The reference's partition_list: gpt_info succeeded, but a count of 0
	 * makes it drop the table and refuse to read the packet either. */
	if (io->nparts == 0)
		return 1;
	fprintf(stderr, "partition-list: standard gpt table saved to %s\n", path);
	fprintf(stderr, "partition-list: skip saving sprd partition list packet\n");
	part_xml_auto(io, (unsigned)io->nparts);
	return 0;
}

/* Ask the device for its partition table and rebuild io->ptab from it.
 * 0 = ok, -1 = refused or malformed. The one place the fetch lives: `parts`
 * prints it as text and `partition-list` writes it as the XML `repartition`
 * reads back.
 *
 * The device is asked ONCE per session, as in the reference: every caller there
 * is guarded by `if (gpt_failed == 1)` (spd_dump.c:755, 954, 1034, 1603) and a
 * successful read clears it, so a second `parts` or `partition-list` re-prints
 * the table already in io->ptab instead of putting a second READ_PARTITION on
 * the wire. A refusal latches the same way (gpt_failed = -1), which is why
 * io->ptab_state is a tri-state rather than a flag. */
static int fetch_ptab(struct spd *io)
{
	unsigned t, plen = 0, i;
	const uint8_t *p;
	int gpt;

	if (io->ptab_state != 1)
		return io->ptab_state < 0 ? -1 : 0;
	/* spd_dump partition_list() (common.c:1071-1078), in its own order: the
	 * active slot is asked of the DEVICE once per session, then the GPT probe,
	 * and only then the SPRD packet. `if (selected_ab < 0)` is the reference's
	 * own latch -- a second table read in one session sends neither the misc
	 * read nor the uboot_a probe again. */
	if (io->slot_bcb < 0)
		spd_slot_set(io, select_ab(io));
	{
		int step = io->step;
		gpt = gpt_probe(io);
		io->step = step;
	}
	if (gpt == 0) {
		/* A standard GPT answered. There is no SPRD packet to save, and the
		 * XML is already written -- both as the reference does it. */
		if (io->slot_bcb == 0)
			spd_slot_set(io, spd_slot_from_table(io));
		io->ptab_state = 0;
		return 0;
	}
	if (gpt > 0) {
		/* gpt_info() parsed a table with no rows at all: the reference calls
		 * that "no table" (partition_list returns NULL) rather than falling
		 * back to the packet. */
		fprintf(stderr, "partition table: the standard GPT has no entries\n");
		io->ptab_state = -1;
		return -1;
	}
	spd_encode(io, BSL_CMD_READ_PARTITION, NULL, 0);
	if (spd_send(io) < 0)
		die("send failed");
	{
		int got = spd_recv(io, io->usb.timeout_ms);
		if (got == 0)
			die("timeout waiting for partition table");
		if (got < 0)
			die("device reset while reading the partition table");
	}
	t = spd_type(io);
	if (t != BSL_REP_READ_PARTITION) {
		fprintf(stderr, "partition response 0x%04x\n", t);
		io->ptab_state = -1; /* common.c:1088 gpt_failed = -1 */
		return -1;
	}
	p = spd_payload(io, &plen);
	if (plen % 0x4c) {
		fprintf(stderr, "partition table length %u is not a multiple of 0x4c\n", plen);
		io->ptab_state = -1; /* common.c:1095 gpt_failed = -1 */
		return -1;
	}
	/* spd_dump partition_list() (common.c ~1109-1124): divisor starts at 10
	 * and drops while any entry >> divisor is 0; bytes = units << (20 -
	 * divisor). spd_dump would loop forever on a 0-size entry; skip those. */
	{
		int divisor = 10;
		unsigned n = plen / 0x4c;
		free(io->ptab);
		io->ptab = calloc(n ? n : 1, sizeof(*io->ptab));
		if (!io->ptab)
			die("out of memory");
		io->nparts = (int)n;
		/* A new table is a new answer for "is this table A/B", so the effective
		 * slot is recomputed below -- but the device's own answer (slot_bcb,
		 * the reference's selected_ab) is not re-asked, exactly as the
		 * reference does not re-ask it. */
		spd_slot_forget(io);
		for (i = 0; i < n; i++) {
			uint32_t u = rd32le(p + i * 0x4c + 0x48);
			while (u && divisor > 0 && !(u >> divisor))
				divisor--;
		}
		/* spd_dump partition_list() reads the storage type out of the same
		 * heuristic it sizes the table with: divisor 10 means the rows are
		 * MiB and the device is eMMC, anything else is UFS (common.c:1116,
		 * and common.c:1007 on the GPT path). It is what load_partition_unify
		 * and w_force look at, so it is recorded even though the sizes here
		 * do not need it. */
		io->storage = (divisor == 10) ? SPD_STORAGE_EMMC : SPD_STORAGE_UFS;
		io->ptab_shift = 20 - divisor;
		for (i = 0; i < n; i++) {
			const uint8_t *rec = p + i * 0x4c;
			unsigned k;
			for (k = 0; k < 36 && rec[k * 2]; k++)
				io->ptab[i].name[k] = (char)rec[k * 2];
			io->ptab[i].name[k] = 0;
			io->ptab[i].size = (uint64_t)rd32le(rec + 0x48) << io->ptab_shift;
		}
		fprintf(stderr, "parts: %u entries, units << %d = bytes (spd_dump divisor %d)\n",
			n, io->ptab_shift, divisor);
		fprintf(stderr, "Storage is %s\n",
			divisor == 10 ? "emmc" : "ufs");
	}
	/* common.c:1143 gpt_failed = 0: the session has its table now, so nothing
	 * asks the device again. */
	io->ptab_state = 0;
	/* spd_dump partition_list() (common.c:1131-1134): a device that answered
	 * "not A/B" but whose table names an _a row is A/B after all, and slot A is
	 * the one in use. The table read is where the reference applies it, so this
	 * is where ours does too. */
	if (io->slot_bcb == 0)
		spd_slot_set(io, spd_slot_from_table(io));
	/* Every read of the table leaves the XML behind, not just an explicit
	 * `partition-list`: that is what the reference does, and it is the only
	 * reason a user can edit a layout without asking for the dump first. */
	part_xml_auto(io, (unsigned)io->nparts);
	/* spd_dump partition_list() also drops the device's own packet as
	 * "sprdpart.bin" whenever the table came from the device rather than from
	 * a standard GPT ("sprd partition list packet saved to sprdpart.bin"). It
	 * is what a repair flow flashes back to restore a table, so it is worth
	 * the same place the XML goes -- and the cwd, as the reference's savepath
	 * starts at ".", when no dump folder was named. */
	save_raw_ptab(io, p, (unsigned)io->nparts);
	return 0;
}

int spd_parts_ensure(struct spd *io)
{
	if (io->nparts > 0)
		return 0;
	if (fetch_ptab(io) || io->nparts <= 0) {
		fprintf(stderr, "partition table: the device did not give one; "
			"commands that name a partition have nothing to resolve against\n");
		return -1;
	}
	return 0;
}

/* The table as the XML `repartition` accepts: one <Partitions> list, the size
 * column in the table's own unit, and the last row 0xffffffff. That last row is
 * why a dumped table can be fed straight back -- the device reads ~0 as "take
 * the rest" -- and the size column is why the round trip is exact.
 *
 * The size column is the WIRE unit, not a byte count: spd_dump's repartition
 * writes the XML value straight into the table without converting it
 * (common.c scan_xml_partitions: WRITE32_LE(buf + 0x48, size)), so a row the
 * user enlarged to 10000 arrives as 10000. On a phone whose rows are MiB -- a
 * 5 GiB super is 5120 -- that is the number the XML has to carry.
 *
 * The divisor fetch_ptab read the table with normalises the READ: bytes =
 * units << (20 - divisor), whichever unit the device reported. The XML is the
 * normalised one -- spd_dump writes a fixed `size >> 20` here and its own
 * reader turns the number back into bytes with `size << 20`, so MiB is the
 * format and not a property of the phone. Echoing the read shift instead (which
 * is 10, not 20, on a table whose rows are all >= 1 MiB) would write every row
 * a thousand times too large. A row the device reports as 0 is written as 0,
 * as it read. */
int spd_part_xml(struct spd *io, const char *out_path)
{
	unsigned count;
	FILE *fo;

	if (fetch_ptab(io))
		return -1;
	count = (unsigned)io->nparts;
	if (count < 1) {
		fprintf(stderr, "partition-list: the device reported an empty table\n");
		return -1;
	}
	fo = (!out_path || !strcmp(out_path, "-")) ? stdout : fopen(out_path, "w");
	if (!fo) {
		fprintf(stderr, "open %s: %s\n", out_path, strerror(errno));
		return -1;
	}
	xml_body(fo, io, count);
	if (fo != stdout) {
		/* Same as the parts table file: a short write must not leave a file
		 * the next repartition reads as the real table. */
		if (fclose(fo) != 0) {
			fprintf(stderr, "write %s: %s\n", out_path, strerror(errno));
			remove(out_path);
			return -1;
		}
	} else if (fflush(fo) != 0) {
		fprintf(stderr, "partition-list: write failed: %s\n", strerror(errno));
		return -1;
	}
	fprintf(stderr, "partition-list: %u entries written as the repartition XML format\n", count);
	return 0;
}

int spd_list_parts(struct spd *io, const char *out_path)
{
	FILE *fo = NULL;
	unsigned i, count;

	if (fetch_ptab(io))
		return -1;
	count = (unsigned)io->nparts;
	if (out_path && strcmp(out_path, "-") != 0) {
		fo = fopen(out_path, "w");
		if (!fo) {
			fprintf(stderr, "open %s: %s\n", out_path, strerror(errno));
			return -1;
		}
	}
	/* The index printed here is the index spd_lookup_part() accepts, which is
	 * spd_dump's scheme: the first table entry is 1 -> ptab[0] (and 0, which
	 * has no table row, is splloader). Printing the raw 0-based loop index
	 * made every displayed index off by one, so feeding one back into
	 * read-part/write-part targeted the wrong partition.
	 *
	 * Both columns are RAW table units, as the README documents them
	 * ("index name units") and as the menu parses them: it applies the shift
	 * itself (parts_units_to_bytes) and writes partition_bytes.txt from this
	 * file. Printing bytes here made the menu shift twice, so every dump came
	 * out at unit << 2*shift and every size check failed. */
	/* Printed from io->ptab, not from the packet the device sent: a second
	 * `parts` in the same session is answered from the table already in hand
	 * (fetch_ptab's latch), and after a `repartition` the in-memory table is
	 * the new layout -- the same one spd_dump prints, because it prints from
	 * io->ptable (spd_dump.c:1041-1042) and not from a saved packet. The raw
	 * packet is only valid for the read that produced it; io->ptab also holds
	 * a standard-GPT table, for which there is no packet at all. */
	for (i = 0; i < count; i++) {
		/* The column is the table's own unit, which is what the menu and the
		 * README say it is: bytes >> ptab_shift. On a wire read that is the
		 * raw 0x4c-record dword (size = dword << shift), so this prints the
		 * same number it always did; after a repartition, where the shift is
		 * 20, it is the XML's MiB. */
		uint64_t sz = io->ptab[i].size >> io->ptab_shift;
		printf("%u %s %" PRIu64 "\n", i + 1, io->ptab[i].name, sz);
		if (fo)
			fprintf(fo, "%s %" PRIu64 "\n", io->ptab[i].name, sz);
	}
	if (fo) {
		/* Buffered writes report their failure at fclose. A table file cut
		 * short by a full disk would otherwise sit where the next session
		 * reads it as the real table and sizes every partition from it, so
		 * a failed write leaves no file at all. */
		if (fclose(fo) != 0) {
			fprintf(stderr, "write %s: %s\n", out_path, strerror(errno));
			remove(out_path);
			return -1;
		}
	}
	return 0;
}

int spd_chip_uid(struct spd *io)
{
	unsigned t, n = 0, i;
	const uint8_t *p;
	spd_encode(io, BSL_CMD_READ_CHIP_UID, NULL, 0);
	if (spd_send(io) < 0)
		return -1;
	{
		int got = spd_recv(io, io->usb.timeout_ms);
		if (got == 0)
			die("timeout waiting for chip uid");
		if (got < 0)
			return -1;
	}
	t = spd_type(io);
	if (t != BSL_REP_READ_CHIP_UID) {
		fprintf(stderr, "chip uid response 0x%04x\n", t);
		return -1;
	}
	p = spd_payload(io, &n);
	printf("chip-uid:");
	for (i = 0; i < n; i++)
		printf(" %02x", p[i]);
	printf("\n");
	return 0;
}

int spd_simple(struct spd *io, unsigned type)
{
	spd_encode(io, type, NULL, 0);
	return spd_check_ok(io);
}

int spd_selftest(void)
{
	static const uint8_t msg[] = "123456789";
	struct spd *io;
	uint8_t body[8] = {0x00, 0x00, 0x00, 0x01, 0x11, 0x22};
	uint8_t odd[5] = {0x00, 0x00, 0x00, 0x01, 0x11};
	uint8_t payload[4] = {0x7e, 0x7d, 0x00, 0x01};
	uint8_t unesc[64];
	unsigned sum;
	int i, n, esc;

	if (crc16(msg, 9) != 0x31c3) {
		fprintf(stderr, "crc16 self-test failed: %04x\n", crc16(msg, 9));
		return 1;
	}
	/* Even length: both checksum modes byte-swap. Value checked against
	 * an independent implementation of the same fold. */
	sum = sum16(body, 6, CHK_FIXZERO);
	if (sum != 0xeedc || sum16(body, 6, CHK_ORIG) != 0xeedc) {
		fprintf(stderr, "sum16 self-test failed: %04x\n", sum);
		return 1;
	}
	/* Odd length: FIXZERO does not swap; ORIG does. */
	sum = sum16(odd, 5, CHK_FIXZERO);
	if (sum != 0xfeee || sum16(odd, 5, CHK_ORIG) != 0xeefe) {
		fprintf(stderr, "sum16 odd-length self-test failed: %04x / %04x\n",
			sum, sum16(odd, 5, CHK_ORIG));
		return 1;
	}

	io = spd_new(0, 0);
	io->flags = SPD_F_TRANSCODE | SPD_F_CRC16;
	spd_encode(io, BSL_CMD_CONNECT, NULL, 0);
	/* Mark, escaped body, mark. Body is 6 bytes plus places 0x7e would grow. */
	if (io->enc[0] != HDLC_MARK || io->enc[io->enc_len - 1] != HDLC_MARK) {
		fprintf(stderr, "frame marks missing\n");
		return 1;
	}
	if (io->enc_len < 8) {
		fprintf(stderr, "frame too short\n");
		return 1;
	}

	/* Encode a body that contains HDLC specials; unescape and match raw. */
	spd_encode(io, BSL_CMD_MIDST_DATA, payload, sizeof(payload));
	if (io->enc[0] != HDLC_MARK || io->enc[io->enc_len - 1] != HDLC_MARK) {
		fprintf(stderr, "escaped frame marks missing\n");
		return 1;
	}
	esc = 0;
	n = 0;
	for (i = 1; i < io->enc_len - 1; i++) {
		uint8_t a = io->enc[i];
		if (esc) {
			unesc[n++] = (uint8_t)(a ^ 0x20);
			esc = 0;
			continue;
		}
		if (a == HDLC_ESC) {
			esc = 1;
			continue;
		}
		if (a == HDLC_MARK) {
			fprintf(stderr, "unescape saw bare mark inside frame\n");
			return 1;
		}
		unesc[n++] = a;
	}
	if (esc || n != io->raw_len || memcmp(unesc, io->raw, (size_t)n) != 0) {
		fprintf(stderr, "encode/unescape round-trip failed (n=%d raw_len=%d)\n",
			n, io->raw_len);
		return 1;
	}
	/* Escaped form must contain 0x7d 0x5e (for 0x7e) and 0x7d 0x5d (for 0x7d). */
	{
		int saw_7e = 0, saw_7d = 0;
		for (i = 1; i < io->enc_len - 2; i++) {
			if (io->enc[i] == HDLC_ESC && io->enc[i + 1] == (HDLC_MARK ^ 0x20))
				saw_7e = 1;
			if (io->enc[i] == HDLC_ESC && io->enc[i + 1] == (HDLC_ESC ^ 0x20))
				saw_7d = 1;
		}
		if (!saw_7e || !saw_7d) {
			fprintf(stderr, "escape of 0x7e/0x7d missing in encoded frame\n");
			return 1;
		}
	}

	spd_free(io);
	printf("self-test ok\n");
	return 0;
}
