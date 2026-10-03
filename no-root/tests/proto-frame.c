/* Framing regression tests for src/proto.c's spd_recv().
 *
 * spd_recv reads bytes from spd_usb_bulk_recv, so this driver replaces that
 * (and the handful of other usb.c symbols proto.c references) with a stub
 * that replays a byte stream the test hands it. That is the only way to feed
 * a malformed stream to the receive path without a phone.
 *
 * The case that matters: a stray 0x7d (HDLC_ESC) arriving before a frame's
 * opening 0x7e. HDLC escapes are per-frame, so those bytes escape nothing --
 * but the escape state used to survive into the next frame, whose opening
 * mark then failed the escaped-byte test and called die(), killing the whole
 * session on one glitch in the noise. The fix must cover a stray escape
 * *immediately* followed by the mark, which needs the head test to run before
 * the escape branch, not after it.
 *
 * Usage: tests/proto-frame.sh runs every case; `proto-frame CASE` runs one and
 * exits 0 on success, 1 on a mismatch, and lets die() exit 1 too.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

#include "usb.h"
#include "proto.h"

/* ------------------------------------------------------------------ stubs */
volatile sig_atomic_t spd_interrupted = 0;

static const uint8_t *feed;
static int feed_len, feed_pos;

int spd_usb_bulk_recv(struct spd_usb *u, uint8_t *buf, int cap, int timeout_ms)
{
	int n = feed_len - feed_pos;

	(void)u;
	(void)timeout_ms;
	if (n <= 0)
		return 0; /* the real one returns 0 on timeout */
	if (n > cap)
		n = cap;
	memcpy(buf, feed + feed_pos, (size_t)n);
	feed_pos += n;
	return n;
}

int spd_usb_bulk_send(struct spd_usb *u, const uint8_t *buf, int len)
{
	(void)u;
	(void)buf;
	(void)len;
	return 0;
}

void spd_usb_clear_halts(struct spd_usb *u) { (void)u; }
int spd_usb_reacquire(struct spd_usb *u) { (void)u; return 0; }
int spd_usb_line_state(struct spd_usb *u) { (void)u; return 0; }

/* ------------------------------------------------------------------- tests */
#define BSL_REP_ACK_V 0x80

static int fails;
static const char *case_name;

static void ok(int cond, const char *what)
{
	if (cond)
		return;
	fprintf(stderr, "FAIL %s: %s\n", case_name, what);
	fails++;
}

/* One BSL_REP_ACK over the wire, marks and escaping included. */
static uint8_t *ack_frame(int *out_len)
{
	struct spd *io = spd_new(0, 0x1000);
	static uint8_t buf[64];

	spd_encode(io, BSL_REP_ACK_V, NULL, 0);
	if (io->enc_len <= 0 || io->enc_len > (int)sizeof buf) {
		fprintf(stderr, "FAIL %s: frame did not build\n", case_name);
		exit(1);
	}
	memcpy(buf, io->enc, (size_t)io->enc_len);
	*out_len = io->enc_len;
	spd_free(io);
	return buf;
}

/* Feed PREFIX then a valid ACK frame; the frame must still be read. */
static void prefixed(const char *name, const uint8_t *prefix, int plen)
{
	struct spd *io = spd_new(0, 0x1000);
	static uint8_t stream[128];
	int flen, n;

	case_name = name;
	uint8_t *fr = ack_frame(&flen);
	memcpy(stream, prefix, (size_t)plen);
	memcpy(stream + plen, fr, (size_t)flen);
	feed = stream;
	feed_len = plen + flen;
	feed_pos = 0;
	n = spd_recv(io, 1000);
	ok(n == 6, "a valid frame after the prefix was not read");
	ok(n == 6 && spd_type(io) == BSL_REP_ACK_V, "wrong reply type");
	spd_free(io);
}

/* Two frames in one buffer: both must come back, in order. */
static void two_frames(void)
{
	struct spd *io = spd_new(0, 0x1000);
	static uint8_t stream[128];
	int flen, n;

	case_name = "two-frames";
	uint8_t *fr = ack_frame(&flen);
	memcpy(stream, fr, (size_t)flen);
	memcpy(stream + flen, fr, (size_t)flen);
	feed = stream;
	feed_len = flen * 2;
	feed_pos = 0;
	n = spd_recv(io, 1000);
	ok(n == 6 && spd_type(io) == BSL_REP_ACK_V, "first frame");
	n = spd_recv(io, 1000);
	ok(n == 6 && spd_type(io) == BSL_REP_ACK_V,
	   "the second frame in the same buffer was lost");
	spd_free(io);
}

int main(int argc, char **argv)
{
	const char *which = argc > 1 ? argv[1] : "";

	if (!strcmp(which, "clean")) {
		prefixed("clean", NULL, 0);
	} else if (!strcmp(which, "junk-then-esc")) {
		/* 0x7d, then a byte that is neither mark nor escape: the escape
		 * is dropped at the next ordinary byte. */
		static const uint8_t p[] = { 0x41, 0x7d, 0x22 };
		prefixed("junk-then-esc", p, (int)sizeof p);
	} else if (!strcmp(which, "esc-then-frame")) {
		/* A stray escape IMMEDIATELY before the opening mark. This is
		 * the one an after-the-fact clear misses. */
		static const uint8_t p[] = { 0x7d };
		prefixed("esc-then-frame", p, (int)sizeof p);
	} else if (!strcmp(which, "esc-esc-then-frame")) {
		static const uint8_t p[] = { 0x7d, 0x7d };
		prefixed("esc-esc-then-frame", p, (int)sizeof p);
	} else if (!strcmp(which, "junk-esc-junk")) {
		static const uint8_t p[] = { 0x11, 0x7d, 0x22, 0x33 };
		prefixed("junk-esc-junk", p, (int)sizeof p);
	} else if (!strcmp(which, "two-frames")) {
		two_frames();
	} else {
		fprintf(stderr, "unknown case: %s\n", which);
		return 2;
	}
	if (fails)
		return 1;
	printf("ok %s\n", which);
	return 0;
}
