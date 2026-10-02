/* fseeko/ftello: hidden by -std=c11 unless POSIX is asked for explicitly.
 * -D_FILE_OFFSET_BITS=64 then makes off_t 64-bit, so a PAC larger than 2 GB
 * is addressable on 32-bit builds too. */
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64

#include "pac.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

/* Layout, confirmed against the vendor `unpac`. */
#define PAC_HEAD_SIZE  2124u
#define PAC_ENTRY_SIZE 2580u
#define PAC_MAGIC      0xFFFAFFFAu
#define PAC_MAX_PARTS  1024u            /* count >= this is rejected */
#define PAC_NAME_CHARS 256u             /* UTF-16 code units in id/fileName */
#define PAC_VER_CHARS  22u
#define PAC_ALIAS_CHARS 100u
#define PAC_COPY_BUF   (64u * 1024u)    /* PACs are GBs; never slurp one */

#define H_VERSION  0x000u
#define H_HISIZE   0x02Cu
#define H_LOSIZE   0x030u
#define H_PRODUCT  0x034u
#define H_FIRMWARE 0x234u
#define H_COUNT    0x434u
#define H_DIROFF   0x438u
#define H_ALIAS    0x450u
#define H_MAGIC    0x844u
#define H_CRC1     0x848u
#define H_CRC2     0x84Au

#define E_LENGTH 0x000u
#define E_ID     0x004u
#define E_NAME   0x204u
#define E_HISIZE 0x5FCu
#define E_HIOFF  0x600u
#define E_LOSIZE 0x604u
#define E_FLAG   0x608u
#define E_CHECK  0x60Cu
#define E_LOOFF  0x610u
#define E_NADDR  0x618u
#define E_ADDR   0x61Cu

struct pac_head {
	uint32_t count;
	uint16_t crc1, crc2;
	char version[PAC_VER_CHARS + 1];
	char product[PAC_NAME_CHARS + 1];
	char firmware[PAC_NAME_CHARS + 1];
	char alias[PAC_ALIAS_CHARS + 1];
};

struct pac_ent {
	uint64_t size, offset;
	uint32_t flag, naddr;
	char id[PAC_NAME_CHARS + 1];
	char name[PAC_NAME_CHARS + 1];
};

static uint16_t rd16(const uint8_t *p)
{
	return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t rd32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
		((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* Fixed-width UTF-16LE, NUL padded. Anything outside printable ASCII becomes
 * '?', which is what the vendor tool prints for the same bytes. */
static void pac_str(char *out, size_t outsz, const uint8_t *p, unsigned nchars)
{
	size_t o = 0;
	unsigned i;

	for (i = 0; i < nchars && o + 1 < outsz; i++) {
		uint16_t c = rd16(p + 2 * i);
		if (!c)
			break;
		out[o++] = (c >= 0x20 && c < 0x7F) ? (char)c : '?';
	}
	out[o] = '\0';
}

/* CRC-16/ARC: reflected poly 0x8005 (0xA001), init 0, no final xor. */
static uint16_t crc16_update(uint16_t crc, const uint8_t *p, size_t n)
{
	size_t i;
	int b;

	for (i = 0; i < n; i++) {
		crc ^= p[i];
		for (b = 0; b < 8; b++)
			crc = (crc & 1) ? (uint16_t)((crc >> 1) ^ 0xA001)
					: (uint16_t)(crc >> 1);
	}
	return crc;
}

static int file_size(FILE *f, uint64_t *out)
{
	off_t n;

	if (fseeko(f, 0, SEEK_END) != 0)
		return -1;
	n = ftello(f);
	if (n < 0)
		return -1;
	if (fseeko(f, 0, SEEK_SET) != 0)
		return -1;
	*out = (uint64_t)n;
	return 0;
}

static int read_at(FILE *f, uint64_t off, void *buf, size_t n)
{
	if (fseeko(f, (off_t)off, SEEK_SET) != 0)
		return -1;
	return fread(buf, 1, n, f) == n ? 0 : -1;
}

/* `*` matches any run (including '/', like the vendor matcher); `?` matches one
 * character. Matching is case-sensitive. */
static int wildcard_match(const char *pat, const char *s)
{
	while (*pat) {
		if (*pat == '*') {
			while (*pat == '*')
				pat++;
			if (!*pat)
				return 1;
			for (;; s++) {
				if (wildcard_match(pat, s))
					return 1;
				if (!*s)
					return 0;
			}
		}
		if (*pat == '?') {
			if (!*s)
				return 0;
		} else if (*pat != *s) {
			return 0;
		}
		pat++;
		s++;
	}
	return *s == '\0';
}

int spd_pac_selftest(void)
{
	static const uint8_t nine[] = "123456789";
	struct {
		const char *pat, *str;
		int want;
	} wc[] = {
		{ "*",        "",            1 },
		{ "*",        "boot",        1 },
		{ "boot*",    "boot_a",      1 },
		{ "boot*",    "vboot",       0 },
		{ "*_a",      "boot_a",      1 },
		{ "*_a",      "boot_b",      0 },
		{ "b??t_a",   "boot_a",      1 },
		{ "b??t_a",   "bt_a",        0 },
		{ "boot_a",   "boot_a",      1 },
		{ "boot_a",   "boot_a_x",    0 },
		{ "*a*b*",    "xaybz",       1 },
		{ "*a*b*",    "xbyaz",       0 },
		{ "super*",   "super",       1 },
		{ "SUPER*",   "super",       0 }, /* case-sensitive, like the vendor */
	};
	size_t i;

	/* CRC-16/ARC (reflected 0x8005, init 0, no final xor). 0xbb3d for
	 * "123456789" is the standard check value; the rest pin the init and the
	 * empty-input case. */
	if (crc16_update(0, nine, sizeof(nine) - 1) != 0xbb3d) {
		fprintf(stderr, "pac self-test: crc16(\"123456789\") = 0x%04x, want 0xbb3d\n",
			crc16_update(0, nine, sizeof(nine) - 1));
		return 1;
	}
	if (crc16_update(0, NULL, 0) != 0x0000 || crc16_update(0, nine, 0) != 0x0000) {
		fprintf(stderr, "pac self-test: crc16 of nothing is not 0\n");
		return 1;
	}
	if (crc16_update(0, (const uint8_t *)"A", 1) != 0x30c0 ||
	    crc16_update(0, (const uint8_t *)"DHTB", 4) != 0x172a) {
		fprintf(stderr, "pac self-test: crc16 short-vector mismatch\n");
		return 1;
	}
	/* Chaining two halves must equal one pass over the whole. */
	if (crc16_update(crc16_update(0, nine, 4), nine + 4, 5) != 0xbb3d) {
		fprintf(stderr, "pac self-test: crc16 is not resumable\n");
		return 1;
	}

	for (i = 0; i < sizeof(wc) / sizeof(wc[0]); i++) {
		if (wildcard_match(wc[i].pat, wc[i].str) != wc[i].want) {
			fprintf(stderr, "pac self-test: wildcard %s vs %s = %d, want %d\n",
				wc[i].pat, wc[i].str,
				wildcard_match(wc[i].pat, wc[i].str), wc[i].want);
			return 1;
		}
	}
	return 0;
}

/* No names means everything. Otherwise a pattern selects an entry when it
 * matches either the file name or the partition id, as the vendor tool does. */
static int selected(const struct pac_ent *e, char **names, int nnames)
{
	int i;

	for (i = 0; i < nnames; i++)
		if (wildcard_match(names[i], e->name) ||
		    wildcard_match(names[i], e->id))
			return 1;
	return nnames == 0;
}

static void print_head_crc(const uint8_t *hdr, const struct pac_head *h)
{
	uint16_t calc = crc16_update(0, hdr, H_CRC1);

	printf("head_crc: 0x%04x", h->crc1);
	if (h->crc1 != calc)
		printf(" (expected 0x%04x)", calc);
	printf("\n");
}

static void print_entry(const uint8_t *ent, const struct pac_ent *e)
{
	uint32_t i;

	/* The vendor prints single digits in decimal and 10+ in hex. Odd, but
	 * it is what the golden output says, so it is what we print. */
	if (e->flag < 10)
		printf("type = %u", e->flag);
	else
		printf("type = 0x%x", e->flag);
	if (e->size)
		printf(", size = 0x%llx", (unsigned long long)e->size);
	if (e->offset)
		printf(", offset = 0x%llx", (unsigned long long)e->offset);
	for (i = 0; i < e->naddr; i++) {
		uint32_t a = rd32(ent + E_ADDR + 4u * i);
		if (!a)
			continue;
		if (i == 0)
			printf(", addr = 0x%x", a);
		else
			printf(", addr%u = 0x%x", i, a);
	}
	printf(", id = \"%s\"", e->id);
	if (e->name[0])
		printf(", name = \"%s\"", e->name);
	printf("\n");
}

static void parse_entry_buf(const uint8_t *ent, struct pac_ent *e)
{
	memset(e, 0, sizeof *e);
	e->size = ((uint64_t)rd32(ent + E_HISIZE) << 32) | rd32(ent + E_LOSIZE);
	e->offset = ((uint64_t)rd32(ent + E_HIOFF) << 32) | rd32(ent + E_LOOFF);
	e->flag = rd32(ent + E_FLAG);
	e->naddr = rd32(ent + E_NADDR);
	/* Bound the address array so a crafted count cannot run off the entry. */
	if (e->naddr > (PAC_ENTRY_SIZE - E_ADDR) / 4u)
		e->naddr = (PAC_ENTRY_SIZE - E_ADDR) / 4u;
	pac_str(e->id, sizeof e->id, ent + E_ID, PAC_NAME_CHARS);
	pac_str(e->name, sizeof e->name, ent + E_NAME, PAC_NAME_CHARS);
}

/* Read entry `idx` into `raw` (PAC_ENTRY_SIZE bytes) and decode it. */
static int read_entry(FILE *f, uint64_t idx, uint8_t *raw, struct pac_ent *e)
{
	if (read_at(f, PAC_HEAD_SIZE + idx * PAC_ENTRY_SIZE, raw, PAC_ENTRY_SIZE) != 0)
		return -1;
	if (rd32(raw + E_LENGTH) != PAC_ENTRY_SIZE) {
		fprintf(stderr, "unexpected struct size\n");
		return -1;
	}
	parse_entry_buf(raw, e);
	return 0;
}

static int load_head(FILE *f, uint8_t *hdr, struct pac_head *h)
{
	if (read_at(f, 0, hdr, PAC_HEAD_SIZE) != 0) {
		fprintf(stderr, "fopen(input) failed\n");
		return -1;
	}
	if (rd32(hdr + H_MAGIC) != PAC_MAGIC) {
		fprintf(stderr, "bad pac_magic\n");
		return -1;
	}
	memset(h, 0, sizeof *h);
	h->count = rd32(hdr + H_COUNT);
	h->crc1 = rd16(hdr + H_CRC1);
	h->crc2 = rd16(hdr + H_CRC2);
	pac_str(h->version, sizeof h->version, hdr + H_VERSION, PAC_VER_CHARS);
	pac_str(h->product, sizeof h->product, hdr + H_PRODUCT, PAC_NAME_CHARS);
	pac_str(h->firmware, sizeof h->firmware, hdr + H_FIRMWARE, PAC_NAME_CHARS);
	pac_str(h->alias, sizeof h->alias, hdr + H_ALIAS, PAC_ALIAS_CHARS);
	return 0;
}

/* The directory check happens after the header is read, and the vendor tool
 * prints the header first, so the caller prints before calling this. */
static int check_dir(const uint8_t *hdr, const struct pac_head *h)
{
	if (rd32(hdr + H_DIROFF) != PAC_HEAD_SIZE) {
		fprintf(stderr, "unexpected directory offset\n");
		return -1;
	}
	if (h->count >= PAC_MAX_PARTS) {
		fprintf(stderr, "too many files\n");
		return -1;
	}
	return 0;
}

static int pac_list(FILE *f, const uint8_t *hdr, const struct pac_head *h,
		    char **names, int nnames)
{
	uint8_t raw[PAC_ENTRY_SIZE];
	struct pac_ent e;
	uint32_t i;

	printf("pac_version: %s\n", h->version);
	printf("pac_size: %u\n", rd32(hdr + H_LOSIZE));
	printf("fw_name: %s\n", h->product);
	printf("fw_version: %s\n", h->firmware);
	printf("fw_alias: %s\n", h->alias);
	print_head_crc(hdr, h);
	if (check_dir(hdr, h) != 0)
		return 1;
	for (i = 0; i < h->count; i++) {
		if (read_entry(f, i, raw, &e) != 0)
			return 1;
		if (selected(&e, names, nnames))
			print_entry(raw, &e);
	}
	return 0;
}

static int pac_check(FILE *f, const uint8_t *hdr, const struct pac_head *h)
{
	uint8_t buf[PAC_COPY_BUF];
	uint64_t total, end, off;
	uint16_t crc = 0;
	size_t n;

	print_head_crc(hdr, h);
	/* The vendor tool checks the directory here: head_crc is printed first,
	 * then a bad directory offset or an out-of-range count stops it before
	 * the data CRC is computed. */
	if (check_dir(hdr, h) != 0)
		return 1;
	if (file_size(f, &total) != 0) {
		fprintf(stderr, "cannot size the pac\n");
		return 1;
	}
	/* The data CRC covers [2124, dwLoSize). Clamp to the real file size so a
	 * header claiming more than the file holds cannot walk off the end. */
	end = rd32(hdr + H_LOSIZE);
	if (end > total)
		end = total;
	if (end < PAC_HEAD_SIZE)
		end = PAC_HEAD_SIZE;
	for (off = PAC_HEAD_SIZE; off < end; off += n) {
		n = (size_t)((end - off) < sizeof buf ? (end - off) : sizeof buf);
		if (read_at(f, off, buf, n) != 0) {
			fprintf(stderr, "read failed\n");
			return 1;
		}
		crc = crc16_update(crc, buf, n);
	}
	/* Stored value first, computed as the expectation -- same shape as
	 * head_crc above, and what the vendor tool prints. */
	printf("data_crc: 0x%04x", h->crc2);
	if (h->crc2 != crc)
		printf(" (expected 0x%04x)", crc);
	printf("\n");
	return 0;
}

static int mkdir_p(const char *dir)
{
	char tmp[4096];
	size_t i, len;

	len = strlen(dir);
	if (len == 0 || len >= sizeof tmp)
		return -1;
	memcpy(tmp, dir, len + 1);
	if (tmp[len - 1] == '/')
		tmp[--len] = '\0';
	for (i = 1; i < len; i++) {
		if (tmp[i] != '/')
			continue;
		tmp[i] = '\0';
		if (mkdir(tmp, 0755) != 0 && errno != EEXIST)
			return -1;
		tmp[i] = '/';
	}
	if (mkdir(tmp, 0755) != 0 && errno != EEXIST)
		return -1;
	return 0;
}

static int copy_out(FILE *in, uint64_t off, uint64_t size, const char *path)
{
	uint8_t buf[PAC_COPY_BUF];
	FILE *out = fopen(path, "wb");
	uint64_t done = 0;

	if (!out) {
		fprintf(stderr, "fopen(%s) failed\n", path);
		return -1;
	}
	while (done < size) {
		size_t n = (size_t)((size - done) < sizeof buf ? (size - done)
							       : sizeof buf);
		if (read_at(in, off + done, buf, n) != 0) {
			fprintf(stderr, "read failed at 0x%llx\n",
				(unsigned long long)(off + done));
			fclose(out);
			return -1;
		}
		if (fwrite(buf, 1, n, out) != n) {
			fprintf(stderr, "write %s: %s\n", path, strerror(errno));
			fclose(out);
			return -1;
		}
		done += n;
	}
	if (fclose(out) != 0) {
		fprintf(stderr, "close %s: %s\n", path, strerror(errno));
		return -1;
	}
	return 0;
}

static int pac_extract(FILE *f, const uint8_t *hdr, const struct pac_head *h,
		       char **names, int nnames, const char *outdir)
{
	uint8_t raw[PAC_ENTRY_SIZE];
	struct pac_ent e;
	uint32_t i;
	uint64_t total;

	if (check_dir(hdr, h) != 0)
		return 1;
	if (file_size(f, &total) != 0) {
		fprintf(stderr, "cannot size input\n");
		return 1;
	}
	if (outdir && mkdir_p(outdir) != 0) {
		fprintf(stderr, "cannot create %s: %s\n", outdir, strerror(errno));
		return 1;
	}
	for (i = 0; i < h->count; i++) {
		char path[8192];

		if (read_entry(f, i, raw, &e) != 0)
			return 1;
		if (!selected(&e, names, nnames))
			continue;
		/* Nothing to write: empty name, or no payload. */
		if (!e.name[0] || e.size == 0 || e.offset == 0)
			continue;
		printf("%s\n", e.name);
		/* Refuse anything that could escape the output directory. The
		 * vendor tool stops here too (though its exit status depends on
		 * whether another entry follows, which we do not copy). */
		if (strpbrk(e.name, "/\\:")) {
			printf("!!! unsafe filename detected\n");
			return 1;
		}
		if (e.offset > total || e.size > total - e.offset) {
			fprintf(stderr, "%s: payload 0x%llx+0x%llx is past the end "
				"of the pac (0x%llx)\n", e.name,
				(unsigned long long)e.offset,
				(unsigned long long)e.size,
				(unsigned long long)total);
			return 1;
		}
		if (outdir)
			snprintf(path, sizeof path, "%s/%s", outdir, e.name);
		else
			snprintf(path, sizeof path, "%s", e.name);
		if (copy_out(f, e.offset, e.size, path) != 0)
			return 1;
	}
	return 0;
}

static void usage(void)
{
	/* First line is byte-identical to the vendor tool's; the rest is ours. */
	fprintf(stderr,
		"Usage: unpac [-d dir] {list|extract|check} firmware.pac [names]\n"
		"  list     print the header and the partitions\n"
		"  extract  write each selected partition's payload\n"
		"  check    verify the header and payload CRCs\n"
		"Names may use * and ?; an entry matches on its file name or its id.\n");
}

int spd_pac_main(int argc, char **argv)
{
	const char *outdir = NULL;
	const char *mode, *path;
	char **names;
	int nnames, i = 1, rc;
	uint8_t hdr[PAC_HEAD_SIZE];
	struct pac_head h;
	FILE *f;

	if (i < argc && strcmp(argv[i], "-d") == 0) {
		if (i + 1 >= argc) {
			usage();
			return 1;
		}
		outdir = argv[i + 1];
		i += 2;
	}
	if (i + 1 >= argc) {
		usage();
		return 1;
	}
	mode = argv[i++];
	path = argv[i++];
	names = argv + i;
	nnames = argc - i;

	if (strcmp(mode, "list") != 0 && strcmp(mode, "extract") != 0 &&
	    strcmp(mode, "check") != 0) {
		/* The vendor tool says just this, and only uses the usage text
		 * when the whole argument shape is wrong. */
		fprintf(stderr, "unknown mode\n");
		return 1;
	}
	/* -d is accepted and ignored outside extract, as upstream does. */

	f = fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "fopen(input) failed\n");
		return 1;
	}
	rc = load_head(f, hdr, &h);
	if (rc == 0) {
		if (strcmp(mode, "list") == 0)
			rc = pac_list(f, hdr, &h, names, nnames);
		else if (strcmp(mode, "check") == 0)
			rc = pac_check(f, hdr, &h);
		else
			rc = pac_extract(f, hdr, &h, names, nnames, outdir);
	}
	fclose(f);
	/* load_head() reports failure as -1, which would leave the shell seeing
	 * 255. Every other failure here is already 1, so normalise. */
	return rc == 0 ? 0 : 1;
}
