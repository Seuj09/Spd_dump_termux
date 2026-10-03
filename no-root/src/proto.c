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
#define BSL_CMD_ERASE_FLASH 0x0a
#define BSL_CMD_REPARTITION 0x0b
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

int spd_check_ok(struct spd *io)
{
	unsigned t;
	int n;
	if (spd_send(io) < 0)
		return -1;
	n = spd_recv(io, io->usb.timeout_ms);
	if (n == 0) {
		fprintf(stderr, "timeout waiting for ack\n");
		return -1;
	}
	if (n < 0)
		return -1;
	t = spd_type(io);
	if (t != BSL_REP_ACK) {
		fprintf(stderr, "unexpected response 0x%04x\n", t);
		return -1;
	}
	return 0;
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
		int last;
		if (n > (size_t)step)
			n = (size_t)step;
		last = (off + n >= size);
		spd_encode(io, BSL_CMD_MIDST_DATA, mem + off, n);
		if (last) {
			/* Final chunk: tolerate a missing ack (stub took over). */
			int got;
			if (io->dry) {
				/* Test hook: SPDHOST_DRY_EXEC_NOACK=1 simulates the stub
				 * seizing execution before it acks the last chunk. */
				const char *e = getenv("SPDHOST_DRY_EXEC_NOACK");
				io->dry_drop_ack = e && e[0] == '1';
			}
			if (spd_send(io) < 0) {
				/* A USB reset as the stub starts is expected; anything
				 * else is a real send failure (spd_dump exits here too). */
				if (reopen_if_gone(io) != 0) {
					fprintf(stderr, "exec_addr: send of final chunk failed\n");
					exit(1);
				}
			} else if ((got = spd_recv(io, io->usb.timeout_ms)) == 0) {
				fprintf(stderr, "exec_addr: no ack on final chunk "
					"(stub likely running) - continuing\n");
			} else if (got < 0) {
				if (reopen_if_gone(io) != 0)
					fprintf(stderr, "exec_addr: recv error after final chunk - continuing\n");
			} else if (spd_type(io) != BSL_REP_ACK) {
				fprintf(stderr, "exec_addr: final chunk response 0x%04x "
					"(stub likely running) - continuing\n", spd_type(io));
			}
		} else {
			if (spd_check_ok(io))
				exit(1);
		}
		off += n;
	}
	/* No END_DATA, no EXEC_DATA — exactly like spd_dump's exec_addr path. */
	free(mem);
	fprintf(stderr, "exec_addr: sent %s (%zu bytes) at 0x%08x (no END/EXEC)\n",
		path, size, addr);
	return 0;
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
		fprintf(stderr, "exec returned incompatible-partition (continuing)\n");
		return 0;
	}
	fprintf(stderr, "exec response 0x%04x\n", t);
	return -1;
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

static int read_part_core(struct spd *io, const char *name, uint64_t offset, uint64_t size,
	const char *out_path, uint8_t *mem)
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
	fprintf(stderr, "read %s: %llu of %llu bytes -> %s%s\n", name, (unsigned long long)done,
		(unsigned long long)size, out_path ? out_path : "memory", (bad || done != size) ? " (INCOMPLETE)" : "");
	return (!bad && done == size) ? 0 : -1;
}

int spd_read_part(struct spd *io, const char *name, uint64_t offset, uint64_t size, const char *out_path)
{
	return read_part_core(io, name, offset, size, out_path, NULL);
}

int spd_read_part_mem(struct spd *io, const char *name, uint64_t offset, uint64_t size, uint8_t *mem)
{
	return read_part_core(io, name, offset, size, NULL, mem);
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
	fprintf(stderr, "erased %s\n", name);
	return 0;
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

int spd_repartition_xml(struct spd *io, const char *path)
{
	FILE *fi;
	char *src, *p, *end;
	uint8_t *buf, *w, *sent;
	off_t sz;
	int n = 0, cap, i;
	/* The payload is n * 0x4c and the BSL frame length is 16 bits, so the
	 * protocol itself stops at 862 entries. spd_dump passes 0xffff as a byte
	 * budget and then overruns its own 128-entry ptable for anything past
	 * 128; refusing cleanly at the real limit is better than either. */
	cap = 0xffff / 0x4c;

	fi = fopen(path, "rb");
	if (!fi) {
		fprintf(stderr, "repartition: open %s: %s\n", path, strerror(errno));
		return -1;
	}
	if (fseeko(fi, 0, SEEK_END) != 0 || (sz = ftello(fi)) <= 0 || sz > 1024 * 1024 ||
		fseeko(fi, 0, SEEK_SET) != 0) {
		fprintf(stderr, "repartition: %s is empty or over 1 MiB\n", path);
		fclose(fi);
		return -1;
	}
	src = malloc((size_t)sz + 1);
	if (!src || fread(src, 1, (size_t)sz, fi) != (size_t)sz) {
		fprintf(stderr, "repartition: short read\n");
		free(src);
		fclose(fi);
		return -1;
	}
	fclose(fi);
	if (memchr(src, 0, (size_t)sz)) {
		fprintf(stderr, "repartition: XML contains a zero byte\n");
		free(src);
		return -1;
	}
	src[sz] = 0;
	p = strstr(src, "<Partitions>");
	end = p ? strstr(p, "</Partitions>") : NULL;
	if (!p || !end || strstr(end + 1, "<Partitions>")) {
		fprintf(stderr, "repartition: need one <Partitions> list\n");
		free(src);
		return -1;
	}
	buf = calloc((size_t)cap, 0x4c);
	if (!buf) {
		free(src);
		return -1;
	}
	w = buf;
	p += strlen("<Partitions>");
	while (p < end) {
		char *lt, *gt, name[36];
		uint32_t size;
		int i;
		while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'))
			p++;
		if (p >= end)
			break;
		if (*p != '<') {
			fprintf(stderr, "repartition: unexpected text in <Partitions>\n");
			free(buf);
			free(src);
			return -1;
		}
		if (!strncmp(p, "<!--", 4)) {
			char *c = strstr(p + 4, "-->");
			if (!c || c >= end) {
				fprintf(stderr, "repartition: unclosed comment\n");
				free(buf);
				free(src);
				return -1;
			}
			p = c + 3;
			continue;
		}
		lt = p + 1;
		gt = strchr(lt, '>');
		if (!gt || gt >= end) {
			fprintf(stderr, "repartition: unclosed tag\n");
			free(buf);
			free(src);
			return -1;
		}
		*gt = 0;
		if (xml_one(lt, name, sizeof(name), &size)) {
			fprintf(stderr, "repartition: bad Partition tag near '%s'\n", lt);
			free(buf);
			free(src);
			return -1;
		}
		if (n >= cap) {
			fprintf(stderr, "repartition: more than %d partitions (frame limit)\n", cap);
			free(buf);
			free(src);
			return -1;
		}
		memset(w, 0, 0x4c);
		for (i = 0; name[i]; i++)
			w[i * 2] = (uint8_t)name[i];
		wr32le(w + 0x48, size);
		fprintf(stderr, "repartition: [%d] %s size=%u\n", n + 1, name, size);
		w += 0x4c;
		n++;
		p = gt + 1;
	}
	free(src);
	if (n < 1) {
		fprintf(stderr, "repartition: no Partition entries\n");
		free(buf);
		return -1;
	}
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
	free(buf);
	fprintf(stderr, "repartition: sent %d entries; this session now resolves names and sizes against the new layout. `parts` re-reads the table from the device, which need not match it until the phone restarts.\n", n);
	return 0;
}

/* Send the live table back to the device, with row IDX renamed to NEWNAME
 * (IDX < 0 = send it unchanged). spd_dump load_partition_force() (common.c
 * ~1302) does exactly this twice around a write: rename the target to
 * "w_force", write to that name, send the original table again. The loader
 * refuses a direct write to a name it knows -- its own list of partition
 * names and sizes -- and a name it has never heard of is not checked.
 *
 * The unit is io->ptab_shift -- the shift the table was read with -- so a
 * table the device gave us goes back exactly as it came. spd_dump writes a
 * fixed size >> 20 there, which is only the same number when the shift the
 * device's units produced was 20; on an ordinary table it is 10 (units are
 * KiB), and the fixed >> 20 would send every row back a thousand times too
 * small. Echoing with the read shift is the same number as the reference's in
 * the one case they agree and the right number in the rest.
 * 0 = accepted, -1 = refused. io->ptab is left alone either way. */
int spd_repartition_echo(struct spd *io, int idx, const char *newname)
{
	uint8_t *buf, *w;
	int i;
	unsigned shift = io->ptab_shift > 0 ? (unsigned)io->ptab_shift : 20u;

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
			wr32le(w + 0x48, (uint32_t)(io->ptab[i].size >> shift));
		w += 0x4c;
	}
	spd_encode(io, BSL_CMD_REPARTITION, buf, (size_t)io->nparts * 0x4c);
	free(buf);
	return spd_check_ok(io) ? -1 : 0;
}

/* The XML body spd_dump writes and reads back: one row per table entry, the
 * size in the table's own unit, and the last row as 0xffffffff ("take the
 * rest", which is what a table ends with). `partition-list` writes this to the
 * file the user names and the automatic copy below writes the same bytes, so
 * either one can be edited and handed to `repartition`. SHIFT turns the byte
 * size fetch_ptab computed back into that unit (see spd_part_xml). */
static void xml_body(FILE *fo, const struct spd *io, unsigned count, unsigned shift)
{
	unsigned i;

	fprintf(fo, "<Partitions>\n");
	for (i = 0; i < count; i++) {
		fprintf(fo, "    <Partition id=\"%s\" size=\"", io->ptab[i].name);
		if (i + 1 == count)
			fprintf(fo, "0x%x\"/>\n", ~0u);
		else
			fprintf(fo, "%llu\"/>\n", (unsigned long long)(io->ptab[i].size >> shift));
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
	xml_body(fo, io, count, io->ptab_shift > 0 ? (unsigned)io->ptab_shift : 20u);
	if (fclose(fo) != 0) {
		if (!warned++)
			fprintf(stderr, "auto partition xml: write %s: %s (the session continues)\n",
				path, strerror(errno));
		remove(path);
		return;
	}
	fprintf(stderr, "partition xml: %s (%u entries)\n", path, count);
}

/* Ask the device for its partition table and rebuild io->ptab from it.
 * The raw payload and its entry count go back through the out-parameters.
 * 0 = ok, -1 = refused or
 * malformed. The one place the fetch lives: `parts` prints it as text and
 * `partition-list` writes it as the XML `repartition` reads back. */
static int fetch_ptab(struct spd *io, const uint8_t **raw, unsigned *count)
{
	unsigned t, plen = 0, i;
	const uint8_t *p;

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
		return -1;
	}
	p = spd_payload(io, &plen);
	if (plen % 0x4c) {
		fprintf(stderr, "partition table length %u is not a multiple of 0x4c\n", plen);
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
		for (i = 0; i < n; i++) {
			uint32_t u = rd32le(p + i * 0x4c + 0x48);
			while (u && divisor > 0 && !(u >> divisor))
				divisor--;
		}
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
		*count = n;
	}
	*raw = p;
	/* Every read of the table leaves the XML behind, not just an explicit
	 * `partition-list`: that is what the reference does, and it is the only
	 * reason a user can edit a layout without asking for the dump first. */
	part_xml_auto(io, *count);
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
 * The divisor fetch_ptab read the table with is what turns bytes back into that
 * unit. spd_dump writes a fixed size >> 20 here instead, which is the same
 * number only when the divisor landed on 0. That is the usual case, because one
 * 1 MiB partition anywhere (misc, sml_a, vbmeta_a) drags it there, and it is
 * what this phone's own table does. Not every table has one: where it has none
 * the divisor is 10 and the fixed shift writes every row a thousand times too
 * small, so dumping a table and feeding it back would shrink the whole layout.
 * The read shift is the same number in the usual case and the right one in the
 * rest. A row the device reports as 0 is written as 0, as it read. */
int spd_part_xml(struct spd *io, const char *out_path)
{
	const uint8_t *p;
	unsigned count = 0, shift;
	FILE *fo;

	if (fetch_ptab(io, &p, &count))
		return -1;
	if (count < 1) {
		fprintf(stderr, "partition-list: the device reported an empty table\n");
		return -1;
	}
	shift = io->ptab_shift > 0 ? (unsigned)io->ptab_shift : 20u;
	fo = (!out_path || !strcmp(out_path, "-")) ? stdout : fopen(out_path, "w");
	if (!fo) {
		fprintf(stderr, "open %s: %s\n", out_path, strerror(errno));
		return -1;
	}
	xml_body(fo, io, count, shift);
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
	const uint8_t *p;
	unsigned i, count = 0;

	if (fetch_ptab(io, &p, &count))
		return -1;
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
	for (i = 0; i < count; i++) {
		const uint8_t *rec = p + i * 0x4c;
		char name[37];
		unsigned k;
		/* Wire entry is 0x4c: UTF-16LE name[36] + LE size dword at 0x48.
		 * A high dword would begin at 0x4c (the next record); common FDL
		 * tables only ship the low 32 bits. Always print as uint64. */
		uint64_t sz = (uint64_t)rd32le(rec + 0x48);
		for (k = 0; k < 36; k++) {
			name[k] = (char)rec[k * 2];
			if (!name[k])
				break;
		}
		name[k] = 0;
		printf("%u %s %" PRIu64 "\n", i + 1, name, sz);
		if (fo)
			fprintf(fo, "%s %" PRIu64 "\n", name, sz);
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
