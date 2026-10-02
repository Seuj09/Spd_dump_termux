#define _FILE_OFFSET_BITS 64

#include "dhtb.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DHTB_MAGIC  0x42544844u /* "DHTB" */
#define AARCH64_NOP 0xD503201Fu

/* Little-endian field access assembled by hand: the tools run on aarch64 but
 * the images are little-endian either way, and this keeps it endian-safe. */
static uint32_t rd32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
		((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint16_t rd16(const uint8_t *p)
{
	return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static void wr16(uint8_t *p, uint16_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
}

static void wr32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

/* The self-test walks the rejection paths on purpose; without this the three
 * expected messages would print under a passing "self-test ok". */
static int quiet;

static void complain(const char *msg)
{
	if (!quiet)
		fprintf(stderr, "%s\n", msg);
}

int spd_dhtb_size(const uint8_t *buf, size_t len, size_t *size, int *short_image)
{
	static const unsigned off[3] = { 0x50, 0x30, 0x20 };
	size_t h;
	unsigned i;

	*short_image = 0;
	if (len < 0x34) {
		complain("not sprd trusted firmware (too short for a DHTB header)");
		return -1;
	}
	if (rd32(buf) != DHTB_MAGIC) {
		complain("not sprd trusted firmware (no DHTB magic)");
		return -1;
	}
	h = rd32(buf + 0x30);
	if (!h) {
		complain("broken sprd trusted firmware (header offset is zero)");
		return -1;
	}
	/* The release tools give up here and write nothing. That test is also
	 * what keeps the patch loops below inside the file, so it must stay
	 * exactly this comparison. */
	if (h + 0x260 >= len) {
		*size = len;
		*short_image = 1;
		return 0;
	}
	/* Three (offset, size) pairs, first non-zero pair wins. */
	for (i = 0; i < 3; i++) {
		uint32_t a = rd32(buf + h + 0x200 + off[i]);
		uint32_t b = rd32(buf + h + 0x200 + off[i] + 8);
		if (a && b) {
			*size = (size_t)a + (size_t)b;
			return 0;
		}
	}
	*size = h + 0x200;
	return 0;
}

/* Defined below the self-test, which exercises them directly. */
static void patch_spl(uint8_t *m, int *hits);
static void patch_spl_legacy(uint8_t *m, int *hits);
static void patch_fdl1(uint8_t *m, int *hits);

int spd_dhtb_selftest(void)
{
	static uint8_t m[0x1000];
	size_t size = 0;
	int short_image = 0, hits = 0;
	unsigned k;

/* A patch site must have become a NOP; a decoy must not have. */
#define NOP_AT(k) (rd32(m + (k)) == AARCH64_NOP)

	/* --- size math ---------------------------------------------------- */
	memset(m, 0, sizeof(m));
	wr32(m, DHTB_MAGIC);
	wr32(m + 0x30, 0x400); /* h */
	/* No (offset,size) pair set: fall back to h + 0x200. */
	if (spd_dhtb_size(m, 0x1000, &size, &short_image) != 0 || short_image ||
	    size != 0x400 + 0x200) {
		fprintf(stderr, "dhtb self-test: empty size table should give h+0x200\n");
		return 1;
	}
	/* Only the last pair (0x20/0x28) set: it still counts. */
	wr32(m + 0x400 + 0x200 + 0x20, 0x100);
	wr32(m + 0x400 + 0x200 + 0x28, 0x200);
	if (spd_dhtb_size(m, 0x1000, &size, &short_image) != 0 || size != 0x300) {
		fprintf(stderr, "dhtb self-test: 0x20/0x28 pair not used (got 0x%zx)\n", size);
		return 1;
	}
	/* First pair in the order 0x50, 0x30, 0x20 wins. */
	wr32(m + 0x400 + 0x200 + 0x30, 0x1000);
	wr32(m + 0x400 + 0x200 + 0x38, 0x2000);
	wr32(m + 0x400 + 0x200 + 0x50, 0x40);
	wr32(m + 0x400 + 0x200 + 0x58, 0x60);
	if (spd_dhtb_size(m, 0x1000, &size, &short_image) != 0 || size != 0xA0) {
		fprintf(stderr, "dhtb self-test: 0x50 pair should win over 0x30 (got 0x%zx)\n",
			size);
		return 1;
	}
	/* A half-filled pair is not a pair. */
	wr32(m + 0x400 + 0x200 + 0x50, 0);
	wr32(m + 0x400 + 0x200 + 0x58, 0);
	wr32(m + 0x400 + 0x200 + 0x30, 0x7000); /* size half zero */
	wr32(m + 0x400 + 0x200 + 0x38, 0);
	if (spd_dhtb_size(m, 0x1000, &size, &short_image) != 0 || size != 0x300) {
		fprintf(stderr, "dhtb self-test: half-filled pair was used (got 0x%zx)\n", size);
		return 1;
	}
	/* h + 0x260 >= len: upstream calls this "not a full image" and does nothing.
	 * The boundary is the comparison itself, so pin it exactly. */
	if (spd_dhtb_size(m, 0x400 + 0x260, &size, &short_image) != 0 ||
	    !short_image || size != 0x400 + 0x260) {
		fprintf(stderr, "dhtb self-test: h+0x260 == len should be a short image\n");
		return 1;
	}
	if (spd_dhtb_size(m, 0x400 + 0x261, &size, &short_image) != 0 || short_image) {
		fprintf(stderr, "dhtb self-test: h+0x260 < len wrongly called a short image\n");
		return 1;
	}
	/* Rejections: bad magic, zero header offset, header too short. These are
	 * the paths that print, so keep them quiet until the flags are checked. */
	quiet = 1;
	wr32(m, 0x42544845u);
	if (spd_dhtb_size(m, 0x1000, &size, &short_image) != -1) {
		fprintf(stderr, "dhtb self-test: bad magic accepted\n");
		return 1;
	}
	wr32(m, DHTB_MAGIC);
	wr32(m + 0x30, 0);
	if (spd_dhtb_size(m, 0x1000, &size, &short_image) != -1) {
		fprintf(stderr, "dhtb self-test: zero header offset accepted\n");
		return 1;
	}
	if (spd_dhtb_size(m, 0x20, &size, &short_image) != -1) {
		fprintf(stderr, "dhtb self-test: truncated header accepted\n");
		return 1;
	}
	quiet = 0;

	/* --- gen-spl-unlock: BL / 0x34000060 / movk w0,#0x80 --------------- */
	memset(m, 0, sizeof(m));
	wr32(m, DHTB_MAGIC);
	wr32(m + 0x30, 0x200); /* end of the patched window is 0x400 */
	wr32(m + 0x2FC, 0x94000000u); /* BL */
	wr32(m + 0x300, 0x34000060u);
	wr16(m + 0x306, 0x5280u);
	/* Decoy: the same compare, but the movk is missing. */
	wr32(m + 0x340, 0x94000000u);
	wr32(m + 0x344, 0x34000060u);
	/* Decoy: the movk is there, the BL is not. */
	wr32(m + 0x380, 0x34000060u);
	wr16(m + 0x386, 0x5280u);
	patch_spl(m, &hits);
	if (hits != 1) {
		fprintf(stderr, "dhtb self-test: gen-spl-unlock hit %d site(s), want 1\n", hits);
		return 1;
	}
	for (k = 0x2FC; k <= 0x308; k += 4)
		if (!NOP_AT(k)) {
			fprintf(stderr, "dhtb self-test: gen-spl-unlock left 0x%x unpatched\n", k);
			return 1;
		}
	if (NOP_AT(0x340) || NOP_AT(0x344) || NOP_AT(0x380)) {
		fprintf(stderr, "dhtb self-test: gen-spl-unlock patched a decoy\n");
		return 1;
	}

	/* --- gen-spl-unlock-legacy: NOP the whole BL..B range -------------- */
	memset(m, 0, sizeof(m));
	wr32(m, DHTB_MAGIC);
	wr32(m + 0x30, 0x200);
	wr32(m + 0x300, 0x94000000u); /* range start */
	wr32(m + 0x304, 0x34000000u);
	wr32(m + 0x320, 0x94000000u); /* range end marker */
	wr32(m + 0x324, 0x34000000u);
	wr32(m + 0x328, 0x14000000u); /* B . */
	/* Decoy after the range: the same opening pair, no B. */
	wr32(m + 0x390, 0x94000000u);
	wr32(m + 0x394, 0x34000000u);
	patch_spl_legacy(m, &hits);
	if (hits != 1) {
		fprintf(stderr, "dhtb self-test: legacy hit %d site(s), want 1\n", hits);
		return 1;
	}
	for (k = 0x300; k < 0x32C; k += 4)
		if (!NOP_AT(k)) {
			fprintf(stderr, "dhtb self-test: legacy left 0x%x unpatched\n", k);
			return 1;
		}
	if (NOP_AT(0x390) || NOP_AT(0x394)) {
		fprintf(stderr, "dhtb self-test: legacy patched the decoy\n");
		return 1;
	}

	/* --- gen-fdl1-dl: BL / 0x34000040 / B ----------------------------- */
	memset(m, 0, sizeof(m));
	wr32(m, DHTB_MAGIC);
	wr32(m + 0x30, 0x200);
	wr32(m + 0x2FC, 0x94000000u);
	wr32(m + 0x300, 0x34000040u);
	wr32(m + 0x304, 0x14000000u);
	/* Decoy: the compare without the BL in front. */
	wr32(m + 0x380, 0x34000040u);
	wr32(m + 0x384, 0x14000000u);
	patch_fdl1(m, &hits);
	if (hits != 1) {
		fprintf(stderr, "dhtb self-test: gen-fdl1-dl hit %d site(s), want 1\n", hits);
		return 1;
	}
	for (k = 0x2FC; k <= 0x304; k += 4)
		if (!NOP_AT(k)) {
			fprintf(stderr, "dhtb self-test: gen-fdl1-dl left 0x%x unpatched\n", k);
			return 1;
		}
	if (NOP_AT(0x380) || NOP_AT(0x384)) {
		fprintf(stderr, "dhtb self-test: gen-fdl1-dl patched the decoy\n");
		return 1;
	}

#undef NOP_AT
	return 0;
}

static uint8_t *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	long n = 0;
	uint8_t *b;

	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return NULL;
	}
	if (fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) <= 0 || fseek(f, 0, SEEK_SET) != 0) {
		fprintf(stderr, "%s: %s\n", path, n == 0 ? "empty" : "cannot size file");
		fclose(f);
		return NULL;
	}
	b = malloc((size_t)n);
	if (!b) {
		fprintf(stderr, "%s: out of memory (%ld bytes)\n", path, n);
		fclose(f);
		return NULL;
	}
	if (fread(b, 1, (size_t)n, f) != (size_t)n) {
		fprintf(stderr, "%s: short read\n", path);
		free(b);
		fclose(f);
		return NULL;
	}
	fclose(f);
	*len = (size_t)n;
	return b;
}

static int write_file(const char *path, const uint8_t *buf, size_t len)
{
	FILE *f = fopen(path, "wb");

	if (!f) {
		fprintf(stderr, "create %s: %s\n", path, strerror(errno));
		return -1;
	}
	if (fwrite(buf, 1, len, f) != len) {
		fprintf(stderr, "write %s: %s\n", path, strerror(errno));
		fclose(f);
		return -1;
	}
	if (fclose(f) != 0) {
		fprintf(stderr, "close %s: %s\n", path, strerror(errno));
		return -1;
	}
	return 0;
}

/* Patchers. `hits` is reported on stderr so the menu can tell "already patched
 * or not this generation" from "patched", which the release menu cannot.
 * Each walks to rd32(m+0x30) + 0x200, exactly like the original. */

static void patch_spl(uint8_t *m, int *hits)
{
	size_t end = (size_t)rd32(m + 0x30) + 0x200;
	size_t o;

	*hits = 0;
	for (o = 0x200; o < end; o += 4) {
		if (rd32(m + o) == 0x34000060u &&
		    (rd32(m + o - 4) >> 8) == 0x940000u &&
		    rd16(m + o + 6) == 0x5280u) {
			wr32(m + o - 4, AARCH64_NOP);
			wr32(m + o, AARCH64_NOP);
			wr32(m + o + 4, AARCH64_NOP);
			wr32(m + o + 8, AARCH64_NOP);
			(*hits)++;
			o += 8;
		}
	}
}

static void patch_spl_legacy(uint8_t *m, int *hits)
{
	size_t end_bound = (size_t)rd32(m + 0x30) + 0x200;
	size_t offset, start = 0, end = 0;

	*hits = 0;
	for (offset = 0x200; offset < end_bound; offset += 4) {
		if (rd16(m + offset + 2) == 0x9400u &&
		    rd16(m + offset + 6) == 0x3400u &&
		    rd32(m + offset + 8) == 0x14000000u)
			end = offset + 0xC;
		if (!end)
			continue;
		for (start = offset - 4; start >= 0x200; start -= 4) {
			if (rd16(m + start + 2) == 0x9400u &&
			    rd16(m + start + 6) == 0x3400u)
				break;
		}
		if (start >= 0x200 && start < end) {
			size_t k;
			for (k = start; k < end; k += 4)
				wr32(m + k, AARCH64_NOP);
			(*hits)++;
			start = 0;
			end = 0;
		} else {
			start = 0;
			end = 0;
		}
	}
}

static void patch_fdl1(uint8_t *m, int *hits)
{
	size_t end = (size_t)rd32(m + 0x30) + 0x200;
	size_t o;

	*hits = 0;
	for (o = 0x200; o < end; o += 4) {
		if (rd32(m + o) == 0x34000040u &&
		    (rd32(m + o - 4) >> 8) == 0x940000u &&
		    rd32(m + o + 4) == 0x14000000u) {
			wr32(m + o - 4, AARCH64_NOP);
			wr32(m + o, AARCH64_NOP);
			wr32(m + o + 4, AARCH64_NOP);
			(*hits)++;
			o += 4;
		}
	}
}

static int run_image_tool(const char *name, const char *in, const char *out,
			  void (*patch)(uint8_t *, int *))
{
	uint8_t *buf;
	size_t len = 0, size = 0;
	int short_image = 0, patched = 0, rc;

	buf = read_file(in, &len);
	if (!buf)
		return -1;
	if (spd_dhtb_size(buf, len, &size, &short_image) != 0) {
		free(buf);
		return -1;
	}
	if (short_image) {
		/* Same as the release: print the size, write nothing. */
		printf("0x%zx\n", len);
		fprintf(stderr, "%s: %s is not a full image (header ends at 0x%zx of 0x%zx); "
			"nothing written to %s\n", name, in, size, len, out);
		free(buf);
		return 0;
	}
	if (size > len) {
		/* The original would read past its own buffer here. */
		fprintf(stderr, "%s: header size 0x%zx is past the end of %s (0x%zx); clamping\n",
			name, size, in, len);
		size = len;
	}
	if (patch)
		patch(buf, &patched);
	printf("0x%zx\n", size);
	rc = write_file(out, buf, size);
	free(buf);
	if (rc != 0)
		return -1;
	if (patch)
		fprintf(stderr, "%s: patched %d signature site(s)\n", name, patched);
	else
		fprintf(stderr, "%s: %s -> %s (%zu bytes)\n", name, in, out, size);
	return 0;
}

int spd_gen_spl_unlock(const char *in, const char *out)
{
	return run_image_tool("gen-spl-unlock", in, out, patch_spl);
}

int spd_gen_spl_unlock_legacy(const char *in, const char *out)
{
	return run_image_tool("gen-spl-unlock-legacy", in, out, patch_spl_legacy);
}

int spd_gen_fdl1_dl(const char *in, const char *out)
{
	return run_image_tool("gen-fdl1-dl", in, out, patch_fdl1);
}

int spd_dhtb_chsize(const char *in, const char *out)
{
	return run_image_tool("chsize", in, out, NULL);
}
