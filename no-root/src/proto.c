#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64

#include "proto.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
	free(io);
}

void spd_encode(struct spd *io, unsigned type, const void *data, size_t len)
{
	uint8_t *p, *body;
	unsigned chk;
	size_t body_len;

	if (len > 0xffff)
		die("message too long");

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
	if (io->enc_len <= 0)
		die("empty message");
	if (io->verbose)
		fprintf(stderr, "send %d bytes\n", io->enc_len);
	if (spd_usb_bulk_send(&io->usb, io->enc, io->enc_len) < 0)
		exit(1);
	return io->enc_len;
}

int spd_recv(struct spd *io, int timeout_ms)
{
	int esc = 0, n = 0, head = 0, need = 6;
	int pos = io->recv_pos;
	int len = io->recv_len;

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
				exit(1);
			if (io->verbose)
				fprintf(stderr, "recv %d bytes\n", got);
			pos = 0;
			len = got;
			continue;
		}
		a = io->recv[pos++];
		if (io->flags & SPD_F_TRANSCODE) {
			if (esc && a != (HDLC_MARK ^ 0x20) && a != (HDLC_ESC ^ 0x20))
				die("bad escaped byte");
			if (a == HDLC_MARK) {
				if (!head) {
					head = 1;
					continue;
				}
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
			if (!head)
				continue;
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
		return spd_recv(io, timeout_ms);
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
	spd_send(io);
	if (!spd_recv(io, io->usb.timeout_ms)) {
		fprintf(stderr, "timeout waiting for ack\n");
		return -1;
	}
	t = spd_type(io);
	if (t != BSL_REP_ACK) {
		fprintf(stderr, "unexpected response 0x%04x\n", t);
		return -1;
	}
	return 0;
}

int spd_check_baud(struct spd *io, int nbytes, int tries)
{
	int i;
	for (i = 0; i < tries; i++) {
		spd_encode(io, BSL_CMD_CHECK_BAUD, NULL, (size_t)nbytes);
		spd_send(io);
		if (!spd_recv(io, io->usb.timeout_ms)) {
			fprintf(stderr, "check baud %d: timeout\n", i + 1);
			continue;
		}
		if (spd_type(io) != BSL_REP_VER) {
			fprintf(stderr, "check baud %d: response 0x%04x\n", i + 1, spd_type(io));
			continue;
		}
		{
			unsigned n = 0;
			const uint8_t *p = spd_payload(io, &n);
			fprintf(stderr, "version: %.*s\n", (int)n, (const char *)p);
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
	long n;
	uint8_t *buf;
	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		exit(1);
	}
	if (fseek(f, 0, SEEK_END) != 0)
		die("fseek");
	n = ftell(f);
	if (n < 0)
		die("ftell");
	rewind(f);
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

int spd_exec(struct spd *io, int timeout_ms, int allow_incompatible)
{
	unsigned t;
	spd_encode(io, BSL_CMD_EXEC_DATA, NULL, 0);
	spd_send(io);
	if (!spd_recv(io, timeout_ms)) {
		fprintf(stderr, "timeout waiting for exec\n");
		return -1;
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

int spd_read_part(struct spd *io, const char *name, uint64_t offset, uint64_t size, const char *out_path)
{
	FILE *fo;
	uint64_t done = 0;
	int mode64 = (offset + size) > 0xffffffffu;
	int step = io->step;

	fo = fopen(out_path, "wb");
	if (!fo) {
		fprintf(stderr, "open %s: %s\n", out_path, strerror(errno));
		return -1;
	}
	select_part(io, name, offset + size, BSL_CMD_READ_START);
	if (spd_check_ok(io))
		exit(1);

	while (done < size) {
		uint8_t req[12];
		uint64_t left = size - done;
		uint64_t pos = offset + done;
		uint32_t n = left > (uint64_t)step ? (uint32_t)step : (uint32_t)left;
		unsigned t, plen = 0;
		const uint8_t *p;

		wr32le(req, n);
		wr32le(req + 4, (uint32_t)pos);
		wr32le(req + 8, (uint32_t)(pos >> 32));
		spd_encode(io, BSL_CMD_READ_MIDST, req, mode64 ? 12 : 8);
		spd_send(io);
		if (!spd_recv(io, io->usb.timeout_ms))
			die("timeout during read");
		t = spd_type(io);
		if (t != BSL_REP_READ_FLASH) {
			fprintf(stderr, "read response 0x%04x\n", t);
			exit(1);
		}
		p = spd_payload(io, &plen);
		if (plen > n)
			die("device returned more than requested");
		if (fwrite(p, 1, plen, fo) != plen)
			die("write failed");
		done += plen;
		if (plen != n)
			break;
	}
	fclose(fo);
	spd_encode(io, BSL_CMD_READ_END, NULL, 0);
	if (spd_check_ok(io))
		exit(1);
	fprintf(stderr, "read %s: %llu bytes -> %s\n", name, (unsigned long long)done, out_path);
	return done == size ? 0 : -1;
}

int spd_write_part(struct spd *io, const char *name, const char *path)
{
	FILE *fi;
	uint64_t len, off;
	int step = io->step;

	fi = fopen(path, "rb");
	if (!fi) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}
	if (fseeko(fi, 0, SEEK_END) != 0)
		die("fseek");
	len = (uint64_t)ftello(fi);
	if (fseeko(fi, 0, SEEK_SET) != 0)
		die("fseek");
	fprintf(stderr, "write %s: %llu bytes from %s\n", name, (unsigned long long)len, path);

	select_part(io, name, len, BSL_CMD_START_DATA);
	if (spd_check_ok(io))
		exit(1);
	for (off = 0; off < len; ) {
		uint64_t left = len - off;
		size_t n = left > (uint64_t)step ? (size_t)step : (size_t)left;
		if (fread(io->temp, 1, n, fi) != n)
			die("short read");
		spd_encode(io, BSL_CMD_MIDST_DATA, io->temp, n);
		spd_send(io);
		if (!spd_recv(io, io->usb.timeout_ms > 15000 ? io->usb.timeout_ms : 15000))
			die("timeout during write");
		if (spd_type(io) != BSL_REP_ACK) {
			fprintf(stderr, "write response 0x%04x at offset %llu\n",
				spd_type(io), (unsigned long long)off);
			exit(1);
		}
		off += n;
	}
	fclose(fi);
	spd_encode(io, BSL_CMD_END_DATA, NULL, 0);
	if (spd_check_ok(io))
		exit(1);
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

int spd_list_parts(struct spd *io, const char *out_path)
{
	FILE *fo = NULL;
	unsigned t, plen = 0, i, count;
	const uint8_t *p;

	spd_encode(io, BSL_CMD_READ_PARTITION, NULL, 0);
	spd_send(io);
	if (!spd_recv(io, io->usb.timeout_ms))
		die("timeout waiting for partition table");
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
	if (out_path && strcmp(out_path, "-") != 0) {
		fo = fopen(out_path, "w");
		if (!fo) {
			fprintf(stderr, "open %s: %s\n", out_path, strerror(errno));
			return -1;
		}
	}
	count = plen / 0x4c;
	for (i = 0; i < count; i++) {
		const uint8_t *rec = p + i * 0x4c;
		char name[37];
		unsigned k;
		uint32_t sz = rd32le(rec + 0x48);
		for (k = 0; k < 36; k++) {
			name[k] = (char)rec[k * 2];
			if (!name[k])
				break;
		}
		name[k] = 0;
		printf("%u %s %u\n", i, name, sz);
		if (fo)
			fprintf(fo, "%s %u\n", name, sz);
	}
	if (fo)
		fclose(fo);
	return 0;
}

int spd_chip_uid(struct spd *io)
{
	unsigned t, n = 0, i;
	const uint8_t *p;
	spd_encode(io, BSL_CMD_READ_CHIP_UID, NULL, 0);
	spd_send(io);
	if (!spd_recv(io, io->usb.timeout_ms))
		die("timeout waiting for chip uid");
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
	unsigned sum;

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
	spd_free(io);
	printf("self-test ok\n");
	return 0;
}
