/* tests/mock_fdl2.c — from the dump-verify audit (cmp/mock_fdl2.c), extended for
 * tests/menu-dump.sh:
 *   MOCK_PTABLE=FILE  partition table "name KiB" lines (READ_PARTITION reply
 *                     in KiB units like eMMC FDL2, and the sizes READ_START
 *                     checks); MOCK_PTABLE=1 keeps the built-in table.
 *   MOCK_SLOT=a|b     misc 0x800 holds an AOSP bootloader_control (2 slots)
 *                     with that slot preferred (spd_dump select_ab()).
 *   MOCK_FAIL_MID=P   2nd READ_MIDST of partition P gets 0x82 instead of data.
 *   MOCK_FAIL_START=P READ_START of P is NACKed.
 *   MOCK_ZERO=P       partition P reads as zeros (fast >4 GiB test).
 *   MOCK_FAIL_WRITE=P START_DATA of partition P is NACKed.
 *   MOCK_FAIL_WRITE_MID=P  2nd write MIDST_DATA of partition P is NACKed
 *                     (the transfer is abandoned mid-partition, like a real
 *                     loader that refuses the rest).
 *   MOCK_MISC_DROPWRITE=1  misc writes are ACKed but not stored (read-back test).
 *   MOCK_MISC_OUT=F   (misc is always a live 1 MiB buffer) (partition writes land in it,
 *                     later reads see them); written to F after each END_DATA
 *                     and at READ_END of misc.
 *   MOCK_READ_FLASH_MAX=N  READ_FLASH (0x06) answers at most N bytes, for the
 *                     short-read path. MOCK_FAIL_READ_FLASH=1 NACKs it.
 *   MOCK_GPT=1        user_partition holds a standard GPT (header at LBA 1,
 *                     entries at LBA 2, four rows misc/boot_a/boot_b/userdata)
 *                     instead of the pattern bytes, so spd_dump's gpt_info()
 *                     path -- what a modern phone actually answers -- is
 *                     exercised. MOCK_PTABLE must still list user_partition, or
 *                     the read is NACKed before any of it is reached.
 *   READ_FLASH/read_mem bytes are part_byte("flash", absolute address), so
 *   `gen_expected flash ADDR SIZE` is what both must return.
 *   MOCK_MISC_BLOCK=N a loader that programs misc in N-byte units: at END_DATA
 *                     the rest of the last unit (wr_off up to the next N) is
 *                     zero-filled, so a bare 2048-byte BCB write wipes
 *                     [0x800,N) -- the A/B slot block (H3).
 *   MOCK_RESET_GONE=1 NORMAL_RESET (0x05) / POWER_OFF (0x17) get no reply and
 *                     every later IN read is LIBUSB_ERROR_NO_DEVICE: the
 *                     loader reset before its ack left (H1).
 *   MOCK_RESET_SILENT=1 those two get no reply at all (a timeout).
 *   MOCK_IMAGES=P1,P2 those partitions read with a boot-image magic in their
 *                     first 8 bytes (AVB0 for vbmeta*, else ANDROID!).
 * Data bytes are pattern_byte(offset) ^ name_seed(name) (see mock_pattern.h).
 *
 * Stateful fake libusb: BootROM -> FDL1 -> FDL2 with partition reads.
 * Logs every OUT frame as: SEQ <TYPE> <payload-len> <payload-hex(<=96B)> fnv=<fnv of framed bytes>
 * Replies: CHECK_BAUD->VER SPRD3; READ_START(0x10)->ACK if name known and size<=partsize else NACK(0x8b? use 0x82);
 * READ_MIDST(0x11)->READ_FLASH(0x93) with deterministic bytes, clipped at partition end; else ACK.
 * Checksum of reply: CRC16 if incoming frame's CRC16 is valid, else additive (CHK_ORIG). */
#include <libusb-1.0/libusb.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXR (0x10000 + 16)
static uint8_t reply[2 * MAXR + 4];
static int reply_len, reply_pos;
static FILE *logf;
static char cur_part[40];
static uint64_t cur_size;
static int connects;
static int midst_count;
static uint8_t *miscmem; static uint64_t misclen;
static int bus_gone;
static char wr_part[40]; static uint64_t wr_off, wr_size; static int wr_on; static int wmid_count;
static void misc_init(void);
static void misc_save(void)
{ const char *f = getenv("MOCK_MISC_OUT"); FILE *o; if (!f || !miscmem) return;
  if ((o = fopen(f, "wb"))) { fwrite(miscmem, 1, misclen, o); fclose(o); } }

static unsigned crc16(const uint8_t *s, unsigned len)
{ unsigned crc = 0; while (len--) { int i; crc ^= (unsigned)(*s++) << 8;
  for (i = 0; i < 8; i++) crc = (crc << 1) ^ ((0 - (crc >> 15)) & 0x11021); } return crc & 0xffff; }
static unsigned sum16_orig(const uint8_t *s, int len)
{ unsigned crc = 0; while (len > 1) { crc += (unsigned)s[1] << 8 | s[0]; s += 2; len -= 2; }
  if (len) crc += *s; crc = (crc >> 16) + (crc & 0xffff); crc += crc >> 16; crc = ~crc & 0xffff;
  return (crc >> 8) | ((crc & 0xff) << 8); }
static uint32_t fnv1a(const uint8_t *p, int n) { uint32_t h = 2166136261u; while (n-- > 0) { h ^= *p++; h *= 16777619u; } return h; }
static unsigned be16(const uint8_t *p) { return (unsigned)p[0] << 8 | p[1]; }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

#include "mock_pattern.h"

static struct { char n[37]; uint64_t kb; } tab[128];
static int ntab = -1;
static void load_tab(void)
{
	const char *p = getenv("MOCK_PTABLE"); FILE *f; char nm[64]; unsigned long long kb;
	if (ntab >= 0) return;
	ntab = 0;
	if (!p || !strcmp(p, "1") || !(f = fopen(p, "r"))) return;
	/* MOCK_PTABLE_MIB=1: the file's numbers are MiB, as a phone whose FDL2
	 * reports MiB rows (spd_dump divisor 0) sends them. tab[] stays KiB, so
	 * the size a probe finds agrees with the unit the table claims. */
	while (ntab < 128 && fscanf(f, "%36s %llu", nm, &kb) == 2) {
		strcpy(tab[ntab].n, nm); tab[ntab].kb = getenv("MOCK_PTABLE_MIB") ? kb << 10 : kb; ntab++; }
	fclose(f);
}
static int streq_env(const char *e, const char *n) { const char *v = getenv(e); return v && !strcmp(v, n); }

/* MOCK_GPT=1: a standard GPT under `user_partition`, built once. The layout is
 * the one spd_dump gpt_info() (common.c:977-1061) and spdhost gpt_probe() read:
 * "EFI PART" at LBA 1, the entry array at the LBA named at header+72, 128-byte
 * entries whose UTF-16LE name sits at +56 and whose sector range is at +32/+40.
 * Nothing checks the CRCs or the type GUIDs, so they are left zero. The header
 * at LBA 1 is also what tells both parsers the device is eMMC on 512-byte
 * sectors. Sizes come out in bytes: (end - start + 1) * 512.
 *
 * The array is the full 128 entries a real GPT declares, with the four used
 * ones followed by zeros: both parsers find the count by stopping at the first
 * entry with an empty LBA range (gpt_info common.c:1029, gpt_probe), so a table
 * without that terminator would test the two against different rules. */
#define GPT_LEN (32u * 1024u)
#define GPT_ENTRIES 128
static uint8_t *gptbuf;
static void gpt_build(void)
{
	static const char *names[] = { "misc", "boot_a", "boot_b", "userdata" };
	static const uint64_t start[] = { 2048, 4096, 20480, 40960 };
	static const uint64_t end[] = { 4095, 20479, 40959, 81919 };
	uint8_t *h;
	int i;

	if (gptbuf) return;
	gptbuf = calloc(1, GPT_LEN);
	if (!gptbuf) return;
	h = gptbuf + 512; /* LBA 1 */
	memcpy(h, "EFI PART", 8);
	h[8] = 0x00; h[9] = 0x00; h[10] = 0x01; h[11] = 0x00; /* revision 1.0 */
	*(uint32_t *)(h + 12) = 92;   /* header size */
	*(uint64_t *)(h + 24) = 1;    /* current LBA */
	*(uint64_t *)(h + 40) = 34;   /* first usable LBA */
	*(uint64_t *)(h + 48) = 81919;/* last usable LBA */
	*(uint64_t *)(h + 72) = 2;    /* partition entry LBA */
	*(uint32_t *)(h + 80) = GPT_ENTRIES; /* entries (128 * 128 B = 16 KiB) */
	*(uint32_t *)(h + 84) = 128;  /* entry size */
	for (i = 0; i < 4; i++) {
		uint8_t *e = gptbuf + 2 * 512 + i * 128;
		const char *n = names[i];
		int k;
		for (k = 0; n[k]; k++) e[56 + 2 * k] = (uint8_t)n[k];
		*(uint64_t *)(e + 32) = start[i];
		*(uint64_t *)(e + 40) = end[i];
	}
}
static int gpt_wanted(const char *name)
{
	const char *v = getenv("MOCK_GPT");
	if (!v || !strcmp(v, "0") || strcmp(name, "user_partition")) return 0;
	gpt_build();
	return gptbuf != NULL;
}

static uint64_t part_size(const char *n)
{
	int i;
	load_tab();
	/* A listed splloader row is its real size. An unlisted one stays 256 KiB,
	 * which is what dumps request. */
	if (ntab > 0) {
		for (i = 0; i < ntab; i++) if (!strcmp(tab[i].n, n)) return tab[i].kb << 10;
		if (!strcmp(n, "splloader")) return 256 << 10;
		return 0;
	}
	if (!strcmp(n, "splloader")) return 256 << 10;
	if (!strcmp(n, "misc")) return 1 << 20;
	if (!strcmp(n, "miscdata")) return 1 << 20;
	if (!strcmp(n, "userdata")) return 6ull << 30; /* 6 GiB */
	if (!strcmp(n, "super")) return 5ull << 30;
	if (!strcmp(n, "bigpart")) return 6ull << 30;
	if (!strcmp(n, "boot_a") || !strcmp(n, "boot_b")) return 64 << 20;
	return 0;
}

static void misc_init(void)
{ uint64_t k; if (miscmem) return; misclen = part_size("misc"); if (!misclen) return;
  const char *in = getenv("MOCK_MISC_IN"); FILE *f;
  miscmem = malloc(misclen); for (k = 0; k < misclen; k++) miscmem[k] = part_byte("misc", k);
  if (in && (f = fopen(in, "rb"))) { if (fread(miscmem, 1, misclen, f)) {} fclose(f); } }

static void make_reply(unsigned type, const uint8_t *data, int n, int crc)
{
	static uint8_t raw[MAXR]; int i, o = 0; unsigned c;
	raw[0] = type >> 8; raw[1] = type; raw[2] = n >> 8; raw[3] = n;
	if (n) memcpy(raw + 4, data, n);
	c = crc ? crc16(raw, 4 + n) : sum16_orig(raw, 4 + n);
	raw[4 + n] = c >> 8; raw[5 + n] = c;
	reply[o++] = 0x7e;
	for (i = 0; i < 6 + n; i++) {
		if (raw[i] == 0x7e || raw[i] == 0x7d) { reply[o++] = 0x7d; reply[o++] = raw[i] ^ 0x20; }
		else reply[o++] = raw[i];
	}
	reply[o++] = 0x7e; reply_len = o; reply_pos = 0;
}

static void log_out(const uint8_t *buf, int len)
{
	static uint8_t raw[MAXR * 2]; static uint8_t data[MAXR];
	int i, n = 0, allmark = 1, crc, plen;
	uint32_t h = fnv1a(buf, len); unsigned type;
	if (!logf) { const char *p = getenv("MOCK_LOG"); logf = fopen(p ? p : "mock.seq", "w"); }
	for (i = 0; i < len; i++) if (buf[i] != 0x7e) allmark = 0;
	if (allmark) {
		fprintf(logf, "SEQ CHECK_BAUD n=%d\n", len); fflush(logf);
		make_reply(0x81, (const uint8_t *)"SPRD3", 5, connects == 0); /* BootROM: CRC16; FDL1/2: additive */
		return;
	}
	for (i = 1; i < len - 1; i++) { if (buf[i] == 0x7d) raw[n++] = buf[++i] ^ 0x20; else raw[n++] = buf[i]; }
	type = be16(raw); plen = be16(raw + 2);
	/* additive wins when both match (1/65536 per frame on long reads) */
	crc = crc16(raw, n - 2) == be16(raw + n - 2) && sum16_orig(raw, n - 2) != be16(raw + n - 2);
	fprintf(logf, "SEQ %02x len=%d ", type, plen);
	if (type != 0x02) for (i = 0; i < plen && i < 96; i++) fprintf(logf, "%02x", raw[4 + i]);
	fprintf(logf, " %s fnv=%08x\n", crc ? "crc" : "sum", h); fflush(logf);
	if (type == 0x00) connects++;
	switch (type) {
	case 0x10: { /* READ_START name[36]wchar + size lo (+hi) */
		char nm[40]; uint64_t sz; for (i = 0; i < 36; i++) { nm[i] = raw[4 + 2 * i]; if (!nm[i]) break; } nm[36] = 0;
		sz = le32(raw + 4 + 72); if (plen >= 80) sz |= (uint64_t)le32(raw + 4 + 76) << 32;
		strcpy(cur_part, nm); cur_size = part_size(nm); midst_count = 0;
		if (streq_env("MOCK_FAIL_START", nm)) { make_reply(0x82, NULL, 0, crc); return; }
		if (!cur_size || (sz > cur_size && !getenv("MOCK_LOOSE"))) make_reply(0x82, NULL, 0, crc); /* not ACK */
		else make_reply(0x80, NULL, 0, crc);
		return; }
	case 0x11: { uint32_t want = le32(raw + 4); uint64_t off = le32(raw + 8); uint32_t k;
		if (plen >= 12) off |= (uint64_t)le32(raw + 12) << 32;
		if (off >= cur_size) { make_reply(0x82, NULL, 0, crc); return; }
		if (++midst_count == 2 && streq_env("MOCK_FAIL_MID", cur_part)) { make_reply(0x82, NULL, 0, crc); return; }
		if (off + want > cur_size) want = (uint32_t)(cur_size - off);
		if (want > 0xffff) want = 0xffff;
		if (!strcmp(cur_part, "misc") && (misc_init(), miscmem) && off + want <= misclen) memcpy(data, miscmem + off, want);
		else if (gpt_wanted(cur_part) && off + want <= GPT_LEN) memcpy(data, gptbuf + off, want);
		else if (streq_env("MOCK_ZERO", cur_part)) memset(data, 0, want);
		else for (k = 0; k < want; k++) data[k] = part_byte(cur_part, off + k);
		{ /* MOCK_IMAGES=a,b,...: those partitions start with a real header
		   * magic (AVB0 for vbmeta*, else ANDROID!), for the M5 check. */
		  const char *im = getenv("MOCK_IMAGES");
		  if (im && off < 8) {
			char lst[512], *t; snprintf(lst, sizeof lst, "%s", im);
			for (t = strtok(lst, ","); t; t = strtok(NULL, ","))
				if (!strcmp(t, cur_part)) {
					const char *m = strncmp(cur_part, "vbmeta", 6) ? "ANDROID!" : "AVB0\0\0\0\0";
					for (k = (uint32_t)off; k < 8 && k - off < want; k++) data[k - off] = (uint8_t)m[k];
				}
		  } }
		make_reply(0x93, data, (int)want, crc); return; }
	case 0x06: { /* READ_FLASH: {addr, size, offset}, all big-endian. The byte at
	              * absolute address (addr + offset) is part_byte("flash", a), so
	              * gen_expected can reproduce it and the same address read through
	              * read_flash and through read_mem (which puts the address in the
	              * first field and 0 in the third) returns the same bytes. */
		uint32_t base = be32(raw + 4), want = be32(raw + 8), off = be32(raw + 12), k;
		if (want > 0xffff) want = 0xffff;
		if (streq_env("MOCK_FAIL_READ_FLASH", "1")) { make_reply(0x82, NULL, 0, crc); return; }
		if (getenv("MOCK_READ_FLASH_MAX") && want > (uint32_t)atoi(getenv("MOCK_READ_FLASH_MAX")))
			want = (uint32_t)atoi(getenv("MOCK_READ_FLASH_MAX"));
		for (k = 0; k < want; k++) data[k] = part_byte("flash", (uint64_t)base + off + k);
		make_reply(0x93, data, (int)want, crc); return; }
	case 0x2d: load_tab(); if (ntab > 0) {
		int k, j; memset(data, 0, ntab * 0x4c);
		for (k = 0; k < ntab; k++) { uint8_t *r = data + k * 0x4c; uint32_t kb = (uint32_t)(getenv("MOCK_PTABLE_MIB") && tab[k].kb != ~0ull ? tab[k].kb >> 10 : tab[k].kb);
			for (j = 0; tab[k].n[j]; j++) r[2 * j] = tab[k].n[j];
			r[0x48] = kb; r[0x49] = kb >> 8; r[0x4a] = kb >> 16; r[0x4b] = kb >> 24; }
		make_reply(0xba, data, k * 0x4c, crc); return; }
		if (getenv("MOCK_PTABLE")) { /* KB units, like eMMC FDL2 (spd_dump divisor=10) */
		static const struct { const char *n; uint32_t kb; } t[] = { {"misc", 1024}, {"boot_a", 65536}, {"boot_b", 65536}, {"bigpart", 6291456} };
		int k, j; memset(data, 0, sizeof(t) / sizeof(t[0]) * 0x4c);
		for (k = 0; k < (int)(sizeof(t) / sizeof(t[0])); k++) { uint8_t *r = data + k * 0x4c;
			for (j = 0; t[k].n[j]; j++) r[2 * j] = t[k].n[j];
			r[0x48] = t[k].kb; r[0x49] = t[k].kb >> 8; r[0x4a] = t[k].kb >> 16; r[0x4b] = t[k].kb >> 24; }
		make_reply(0xba, data, k * 0x4c, crc); return; }
		make_reply(0x80, NULL, 0, crc); return;
	case 0x0b: { /* REPARTITION: the table the client sends becomes ours, so a
	              * row it renamed is then known by the new name and a row it
	              * added can be written. Without this the mock answered every
	              * repartition with a bare ACK and kept its old names, which
	              * is what a real loader does NOT do -- the whole reason
	              * spd_dump's w_force renames a row before writing it. */
		int k, j, n = plen / 0x4c;
		if (n > 128) n = 128;
		memset(tab, 0, sizeof(tab));
		for (k = 0; k < n; k++) {
			const uint8_t *r = raw + 4 + k * 0x4c;
			uint32_t sz;
			for (j = 0; j < 36 && r[2 * j]; j++) tab[k].n[j] = (char)r[2 * j];
			tab[k].n[j] = 0;
			/* This size field is MiB, not KiB: load_partition_force writes
			 * ptable[i].size >> 20 (common.c 1316), so a 4096 KiB row
			 * arrives as 4. tab[] is KiB, like MOCK_PTABLE and the 0x2d
			 * reply, so convert -- reading it as KiB made every renamed
			 * row 1024x too small, and a write to it was then refused by
			 * the size check above: the force trick could never complete.
			 * ~0 means "the rest of the flash" and is kept as the
			 * sentinel, which part_size turns into an unbounded size. */
			sz = le32(r + 0x48);
			tab[k].kb = (sz == 0xffffffffu) ? ~0ull : ((uint64_t)sz << 10);
		}
		ntab = n;
		make_reply(0x80, NULL, 0, crc); return; }
	case 0x12: if (!strcmp(cur_part, "misc")) misc_save(); make_reply(0x80, NULL, 0, crc); return;
	case 0x01: if (plen >= 76) { /* partition START_DATA: name[36]wchar + size lo (+hi) */
		char nm[40]; for (i = 0; i < 36; i++) { nm[i] = raw[4 + 2 * i]; if (!nm[i]) break; } nm[36] = 0;
		strcpy(wr_part, nm); wr_off = 0; wr_size = le32(raw + 4 + 72); wr_on = 1; wmid_count = 0;
		/* 88-byte START is a 64-bit size. 80-byte START is an NV write:
		 * size plus a checksum, not a high size word. */
		if (plen >= 88) wr_size |= (uint64_t)le32(raw + 4 + 76) << 32;
		if (streq_env("MOCK_FAIL_WRITE", nm) || !part_size(nm) || wr_size > part_size(nm)) { wr_on = 0; make_reply(0x82, NULL, 0, crc); return; }
		}
		make_reply(0x80, NULL, 0, crc); return;
	case 0x02: if (wr_on && ++wmid_count == 2 && streq_env("MOCK_FAIL_WRITE_MID", wr_part)) {
			/* Mid-partition refusal: the loader takes no more data. The
			 * client must abandon the transfer the way spd_dump's
			 * load_partition does, END_DATA included. */
			wr_on = 0; make_reply(0x82, NULL, 0, crc); return; }
		if (wr_on && !strcmp(wr_part, "misc") && !getenv("MOCK_MISC_DROPWRITE")) { misc_init();
		if (miscmem && wr_off + plen <= misclen) memcpy(miscmem + wr_off, raw + 4, plen); }
		if (wr_on) wr_off += plen;
		make_reply(0x80, NULL, 0, crc); return;
	case 0x03: if (wr_on && !strcmp(wr_part, "misc") && getenv("MOCK_MISC_BLOCK") && miscmem) {
			uint64_t blk = strtoull(getenv("MOCK_MISC_BLOCK"), NULL, 0), e;
			if (blk && wr_off % blk) {
				e = (wr_off / blk + 1) * blk;
				if (e > misclen) e = misclen;
				memset(miscmem + wr_off, 0, e - wr_off);
			} }
		if (wr_on && !strcmp(wr_part, "misc")) misc_save(); wr_on = 0;
		make_reply(0x80, NULL, 0, crc); return;
	case 0x05: case 0x17:
		if (getenv("MOCK_RESET_GONE")) { bus_gone = 1; reply_len = reply_pos = 0; return; }
		if (getenv("MOCK_RESET_SILENT")) { reply_len = reply_pos = 0; return; }
		make_reply(0x80, NULL, 0, crc); return;
	case 0x0a: { /* ERASE: name[36]wchar. MOCK_FAIL_ERASE=NAME refuses that one
	              * name, as a loader that will not erase splloader_bak does. */
		const char *fe = getenv("MOCK_FAIL_ERASE");
		char nm[40]; int q;
		for (q = 0; q < 36 && 4 + 2 * q < plen + 4; q++) { nm[q] = raw[4 + 2 * q]; if (!nm[q]) break; }
		nm[q < 36 ? q : 36] = 0;
		if (fe && !strcmp(fe, nm)) { make_reply(0x82, NULL, 0, crc); return; }
		make_reply(0x80, NULL, 0, crc); return; }
	default: make_reply(0x80, NULL, 0, crc); return;
	}
}

static struct libusb_endpoint_descriptor eps[2];
static struct libusb_interface_descriptor ifd;
static struct libusb_interface itf;
static struct libusb_config_descriptor cfg;
static int dummy_dev, dummy_handle;

int libusb_init(libusb_context **c) { if (c) *c = NULL; return 0; }
int libusb_init_context(libusb_context **c, const struct libusb_init_option *o, int n) { (void)o; (void)n; if (c) *c = NULL; return 0; }
void libusb_exit(libusb_context *c) { (void)c; }
int libusb_set_option(libusb_context *c, enum libusb_option o, ...) { (void)c; (void)o; return 0; }
int libusb_has_capability(uint32_t c) { (void)c; return 1; }
const char *libusb_error_name(int e) { static char b[32]; snprintf(b, sizeof b, "MOCK_ERR_%d", e); return b; }
int libusb_wrap_sys_device(libusb_context *c, intptr_t fd, libusb_device_handle **h) { (void)c; (void)fd; *h = (libusb_device_handle *)&dummy_handle; return 0; }
libusb_device *libusb_get_device(libusb_device_handle *h) { (void)h; return (libusb_device *)&dummy_dev; }
libusb_device *libusb_ref_device(libusb_device *d) { return d; }
int libusb_get_device_descriptor(libusb_device *d, struct libusb_device_descriptor *desc)
{ (void)d; memset(desc, 0, sizeof *desc); desc->idVendor = 0x1782; desc->idProduct = 0x4d00; desc->bNumConfigurations = 1; return 0; }
int libusb_get_config_descriptor(libusb_device *d, uint8_t i, struct libusb_config_descriptor **c)
{ (void)d; (void)i;
  eps[0].bEndpointAddress = 0x81; eps[0].bmAttributes = 2; eps[0].wMaxPacketSize = 512;
  eps[1].bEndpointAddress = 0x01; eps[1].bmAttributes = 2; eps[1].wMaxPacketSize = 512;
  ifd.bNumEndpoints = 2; ifd.endpoint = eps; itf.num_altsetting = 1; itf.altsetting = &ifd;
  cfg.bNumInterfaces = 1; cfg.interface = &itf; *c = &cfg; return 0; }
int libusb_get_active_config_descriptor(libusb_device *d, struct libusb_config_descriptor **c) { return libusb_get_config_descriptor(d, 0, c); }
void libusb_free_config_descriptor(struct libusb_config_descriptor *c) { (void)c; }
int libusb_kernel_driver_active(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_detach_kernel_driver(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_claim_interface(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_release_interface(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_clear_halt(libusb_device_handle *h, unsigned char e) { (void)h; (void)e; return 0; }
int libusb_get_configuration(libusb_device_handle *h, int *c) { (void)h; *c = 1; return 0; }
int libusb_set_configuration(libusb_device_handle *h, int c) { (void)h; (void)c; return 0; }
int libusb_get_device_speed(libusb_device *d) { (void)d; return LIBUSB_SPEED_HIGH; }
void libusb_close(libusb_device_handle *h) { (void)h; }
int libusb_open(libusb_device *d, libusb_device_handle **h) { (void)d; *h = (libusb_device_handle *)&dummy_handle; return 0; }
libusb_device_handle *libusb_open_device_with_vid_pid(libusb_context *c, uint16_t v, uint16_t p) { (void)c; (void)v; (void)p; return (libusb_device_handle *)&dummy_handle; }
ssize_t libusb_get_device_list(libusb_context *c, libusb_device ***l) { (void)c; *l = NULL; return 0; }
void libusb_free_device_list(libusb_device **l, int u) { (void)l; (void)u; }
int libusb_hotplug_register_callback(libusb_context *c, int e, int f, int v, int p, int cl,
	libusb_hotplug_callback_fn cb, void *u, libusb_hotplug_callback_handle *hh)
{ (void)c; (void)e; (void)f; (void)v; (void)p; (void)cl; (void)cb; (void)u; (void)hh; return 0; }
void libusb_hotplug_deregister_callback(libusb_context *c, libusb_hotplug_callback_handle h) { (void)c; (void)h; }
int libusb_handle_events(libusb_context *c) { (void)c; return 0; }
int libusb_control_transfer(libusb_device_handle *h, uint8_t rt, uint8_t r, uint16_t v, uint16_t i,
	unsigned char *d, uint16_t l, unsigned int t) { (void)h; (void)rt; (void)r; (void)v; (void)i; (void)d; (void)t; return l; }
int libusb_bulk_transfer(libusb_device_handle *h, unsigned char ep, unsigned char *d, int len, int *got, unsigned int t)
{
	(void)h; (void)t;
	if (!(ep & 0x80)) { log_out(d, len); *got = len; return 0; }
	if (bus_gone) { *got = 0; return LIBUSB_ERROR_NO_DEVICE; }
	if (reply_pos >= reply_len) { *got = 0; return LIBUSB_ERROR_TIMEOUT; }
	if (len > reply_len - reply_pos) len = reply_len - reply_pos;
	memcpy(d, reply + reply_pos, len); *got = len; reply_pos += len; return 0;
}
