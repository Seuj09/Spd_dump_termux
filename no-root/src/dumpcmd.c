/* In-session helpers built on the live partition table (io->ptab), so a
 * refresh + dump runs on ONE spdhost connection (no FDL2 drop between the
 * `parts` read and the reads). Name/size/slot handling matches the vendored
 * spd_dump: see spd_dump/spd_dump.c ~955-998 (r all/all_lite, splloader),
 * spd_dump/common.c ~1046-1072 (select_ab) and ~1106-1124 (unit divisor).
 *
 * fseeko/ftello must be declared. On arm32 an implicit declaration passes
 * the 64-bit off_t in the wrong registers, and clang rejects it.
 */
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "proto.h"
#include "dumpcmd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <unistd.h>

/* SPLLOADER_BYTES lives in proto.h: spd_list_parts() prints the same id. */
#define MISC_SLOT_BYTES 1048576u
/* spd_dump select_ab reads 0x20 bytes at misc+0x800, not the whole partition. */
#define SLOT_ABC_OFF 0x800u
#define SLOT_ABC_LEN 32u

/* AOSP bootloader_control (spd_dump common.h): slot_suffix[4], magic, version,
 * nb_slot:3..., slot_info[4] (2 bytes each). ABC is those 32 bytes, already
 * sliced at misc+0x800. Returns 1/2 for slot a/b, 0 for "not A/B". */
int spd_slot_from_bytes(const uint8_t *abc, int have_uboot_a);

static int slot_from_abc(const uint8_t *abc, int have_uboot_a)
{
	int nb, p0, p1, ok0, ok1, t0, t1, d;
	nb = abc[9] & 7;
	if (nb != 2)
		return 0;
	p0 = abc[12] & 15; t0 = (abc[12] >> 4) & 7; ok0 = abc[12] >> 7;
	p1 = abc[14] & 15; t1 = (abc[14] >> 4) & 7; ok1 = abc[14] >> 7;
	/* ab_compare_slots(slot_info[1], slot_info[0]) < 0 -> slot b */
	if (p1 != p0) d = p0 - p1;
	else if (ok1 != ok0) d = ok0 - ok1;
	else d = t0 - t1;
	if (!have_uboot_a)
		return 0; /* spd_dump: no uboot_a means not really A/B */
	return d < 0 ? 2 : 1;
}

int spd_slot_from_bytes(const uint8_t *abc, int have_uboot_a)
{
	return slot_from_abc(abc, have_uboot_a);
}

static uint32_t crc32_le(const uint8_t *p, int n)
{
	uint32_t crc = ~0u;
	while (n--) {
		int b;
		crc ^= *p++;
		for (b = 0; b < 8; b++)
			crc = (crc & 1) ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
	}
	return crc ^ ~0u;
}

int spd_fill_slot_abc(uint8_t abc[32], char which)
{
	int slot, i;
	if (which != 'a' && which != 'b')
		return -1;
	memset(abc, 0, 32);
	abc[0] = '_';
	abc[1] = (uint8_t)which;
	abc[4] = 0x42; abc[5] = 0x43; abc[6] = 0x41; abc[7] = 0x42; /* "BCAB" */
	abc[8] = 1; /* version */
	abc[9] = 2; /* nb_slot */
	slot = which - 'a';
	/* slot_info[i] is 2 bytes at offset 12. priority:4, tries:3, success:1. */
	abc[12 + slot * 2] = (uint8_t)(15 | (6 << 4));
	abc[12 + (1 - slot) * 2] = (uint8_t)(14 | (1 << 4));
	{
		uint32_t c = crc32_le(abc, 0x1c);
		for (i = 0; i < 4; i++)
			abc[28 + i] = (uint8_t)(c >> (8 * i));
	}
	return 0;
}

int spd_pack_slot_file(char which, const char *in_path, const char *out_path)
{
	FILE *fi, *fo;
	uint8_t *buf, abc[32];
	off_t sz;
	fi = fopen(in_path, "rb");
	if (!fi) {
		fprintf(stderr, "pack-slot: open %s: %s\n", in_path, strerror(errno));
		return -1;
	}
	if (fseeko(fi, 0, SEEK_END) != 0 || (sz = ftello(fi)) < 0x820 || fseeko(fi, 0, SEEK_SET) != 0) {
		fprintf(stderr, "pack-slot: %s must be a full misc image (at least 0x820 bytes)\n", in_path);
		fclose(fi);
		return -1;
	}
	buf = malloc((size_t)sz);
	if (!buf || fread(buf, 1, (size_t)sz, fi) != (size_t)sz) {
		fprintf(stderr, "pack-slot: short read\n");
		free(buf);
		fclose(fi);
		return -1;
	}
	fclose(fi);
	if (spd_fill_slot_abc(abc, which)) {
		free(buf);
		return -1;
	}
	memcpy(buf + 0x800, abc, 32);
	fo = fopen(out_path, "wb");
	if (!fo || fwrite(buf, 1, (size_t)sz, fo) != (size_t)sz) {
		fprintf(stderr, "pack-slot: write %s failed\n", out_path);
		if (fo)
			fclose(fo);
		free(buf);
		return -1;
	}
	fclose(fo);
	free(buf);
	fprintf(stderr, "pack-slot: %c -> %s (%lld bytes, slot block at 0x800)\n",
		which, out_path, (long long)sz);
	return 0;
}

/* spd_dump dump_partition: a name containing "nv1" is read from the same
 * name with its last '1' turned into '2', starting at offset 512, length
 * shortened by 512. The output file keeps the original name. */
static void nv_read_adjust(const char *name, char *alt, size_t cap,
	uint64_t *off, uint64_t *n)
{
	const char *p;
	size_t i;
	*off = 0;
	if (!strstr(name, "nv1"))
		return;
	p = strrchr(name, '1');
	if (!p)
		return;
	i = (size_t)(p - name);
	if (i + strlen(p) >= cap)
		return;
	memcpy(alt, name, i);
	alt[i] = '2';
	memcpy(alt + i + 1, p + 1, strlen(p + 1) + 1);
	*off = 512;
	if (*n > 512)
		*n -= 512;
	fprintf(stderr, "dump: %s reads %s at offset 512, %llu bytes (spd_dump nv1)\n",
		name, alt, (unsigned long long)*n);
}

static int find_part(struct spd *io, const char *name)
{
	int i;
	for (i = 0; i < io->nparts; i++)
		if (strcmp(io->ptab[i].name, name) == 0)
			return i;
	return -1;
}

int spd_lookup_part(struct spd *io, const char *name, int slot,
	char *out, size_t cap, uint64_t *size)
{
	int i, all_digit;
	char alt[40];
	if (!name || !name[0] || strlen(name) > 35 || cap < 36)
		return -1;
	all_digit = 1;
	for (i = 0; name[i]; i++)
		if (!isdigit((unsigned char)name[i]))
			all_digit = 0;
	if (all_digit) {
		int id = atoi(name);
		if (id == 0) {
			snprintf(out, cap, "splloader");
			*size = SPLLOADER_BYTES;
			return 0;
		}
		if (io->nparts <= 0) {
			/* -2 is "no table yet". Fill out and *size exactly as the
			 * non-numeric -2 below does: the caller compares the
			 * resolved name, so returning here with out untouched
			 * made `write-part 5 FILE` (or `read-part 5`) strcmp an
			 * uninitialised buffer. */
			snprintf(out, cap, "%s", name);
			*size = 0;
			return -2;
		}
		if (id < 1 || id > io->nparts)
			return -1;
		snprintf(out, cap, "%s", io->ptab[id - 1].name);
		*size = io->ptab[id - 1].size;
		return *size ? 0 : -1;
	}
	/* spd_dump get_partition_info: splloader* is 256 KiB even with no table row. */
	if (!strncmp(name, "splloader", 9)) {
		snprintf(out, cap, "%s", name);
		*size = SPLLOADER_BYTES;
		return 0;
	}
	if (io->nparts <= 0) {
		snprintf(out, cap, "%s", name);
		*size = 0;
		return -2;
	}
	i = find_part(io, name);
	if (i < 0 && slot > 0) {
		snprintf(alt, sizeof(alt), "%s_%c", name, slot == 1 ? 'a' : 'b');
		i = find_part(io, alt);
	}
	if (i < 0)
		return -1;
	snprintf(out, cap, "%s", io->ptab[i].name);
	*size = io->ptab[i].size;
	return *size ? 0 : -1;
}

/* Active slot: one 32-byte read at misc+0x800 (spd_dump select_ab). A refused
 * read is "not A/B" and the dump continues. Returns 0, 1 (a) or 2 (b). */
static int write_file(const char *path, const uint8_t *buf, size_t len)
{
	FILE *f = fopen(path, "wb");
	if (!f)
		return -1;
	if (fwrite(buf, 1, len, f) != len) {
		fclose(f);
		return -1;
	}
	return fclose(f);
}

static const char *slot_copy_path;
int spd_active_slot(struct spd *io)
{
	uint8_t abc[SLOT_ABC_LEN];
	int slot, have_a;
	if (find_part(io, "misc") < 0)
		return 0;
	if (spd_read_part_mem(io, "misc", SLOT_ABC_OFF, SLOT_ABC_LEN, abc)) {
		fprintf(stderr, "slot: misc+0x800 read failed; treating as not A/B\n");
		return 0;
	}
	if (slot_copy_path && write_file(slot_copy_path, abc, SLOT_ABC_LEN))
		fprintf(stderr, "slot: could not save %s\n", slot_copy_path);
	have_a = find_part(io, "uboot_a") >= 0;
	slot = slot_from_abc(abc, have_a);
	fprintf(stderr, "slot: %s\n", slot == 1 ? "a" : slot == 2 ? "b" : "not A/B");
	return slot;
}

static int skip_bulk(const char *n, int mode, int slot)
{
	/* spd_dump r all/all_lite: memcmp prefixes blackbox/cache/userdata. */
	if (!strncmp(n, "blackbox", 8) || !strncmp(n, "cache", 5) || !strncmp(n, "userdata", 8))
		return 1;
	if (mode == DUMP_ALL_LITE) {
		size_t l = strlen(n);
		if (slot == 1 && l > 2 && !strcmp(n + l - 2, "_b"))
			return 1;
		if (slot == 2 && l > 2 && !strcmp(n + l - 2, "_a"))
			return 1;
	}
	return 0;
}

/* One entry to dump: name + byte size + output path. */
static FILE *manifest;
static int dump_one(struct spd *io, const char *name, uint64_t size, const char *outdir,
	char *failed, size_t failcap, int *nfail)
{
	char out[1024], tmp[1100], part[1100], alt[40];
	const char *read_name = name;
	uint64_t off = 0, n = size;
	if (!strcmp(name, "super") || size >= (512ull << 20))
		fprintf(stderr, "dump: %s is %llu bytes\n", name, (unsigned long long)size);
	nv_read_adjust(name, alt, sizeof(alt), &off, &n);
	if (off)
		read_name = alt;
	snprintf(out, sizeof(out), "%s/%s.img", outdir, name);
	snprintf(tmp, sizeof(tmp), "%s.tmp", out);
	snprintf(part, sizeof(part), "%s.partial", out);
	/* manifest: "start NAME BYTES FILE" before, "ok|fail NAME" after. A start
	 * without an ok line (spdhost died mid-read) is a failure too. BYTES is
	 * what will be read (nv1 is 512 bytes shorter than the table size). */
	if (manifest) {
		fprintf(manifest, "start %s %llu %s.img\n", name, (unsigned long long)n, name);
		fflush(manifest);
	}
	unlink(part);
	/* Read into NAME.img.tmp; only a complete read replaces NAME.img. A
	 * failed one is left as NAME.img.partial (an older NAME.img stays). */
	if (spd_read_part(io, read_name, off, n, tmp) == 0) {
		if (rename(tmp, out) == 0) {
			if (manifest) {
				fprintf(manifest, "ok %s\n", name);
				fflush(manifest);
			}
			return 0;
		}
		fprintf(stderr, "rename %s: %s\n", tmp, strerror(errno));
	} else if (access(tmp, F_OK) == 0) {
		rename(tmp, part);
	}
	if (manifest) {
		fprintf(manifest, "fail %s\n", name);
		fflush(manifest);
	}
	{
		(*nfail)++;
		if (strlen(failed) + strlen(name) + 2 < failcap) {
			strcat(failed, " ");
			strcat(failed, name);
		}
		return -1;
	}
}

/* spd_dump r preset_modem: every l_* and nr_* row, plus the misc slot block
 * when the device is A/B (selected_ab > 0). The modem/NV preset. */
static int preset_modem_want(const char *n)
{
	return !strncmp(n, "l_", 2) || !strncmp(n, "nr_", 3);
}

/* spd_dump r preset_resign: the re-sign set, index 7 down to 0, missing rows
 * skipped. splloader is not a table row on every chip: it is a fixed offset. */
static const char *const preset_resign[] = {
	"vbmeta", "splloader", "uboot", "sml", "trustos", "teecfg", "boot", "recovery"
};
#define PRESET_RESIGN_N ((int)(sizeof(preset_resign) / sizeof(preset_resign[0])))

/* Resolve NAME the way spd_dump get_partition_info does: exact, then NAME_a /
 * NAME_b for the live slot (so `boot` finds `boot_a` on a slot-a phone). OUT
 * (>= 40 bytes) gets the canonical table name, *SIZE the byte size.
 * 0 = found, -1 = not in the table, -2 = no table yet.
 * The slot is read from misc once per connection and cached: a script calling
 * this in a loop should not pay a misc read per call. */
int spd_resolve_part(struct spd *io, const char *name, char *out, size_t cap, uint64_t *size)
{
	static struct spd *slot_io;
	static int slot;
	if (slot_io != io) {
		slot_io = io;
		slot = spd_active_slot(io);
	}
	return spd_lookup_part(io, name, slot, out, cap, size);
}

/* check-part NAME: size in bytes, 0 when the name is not in the live table.
 * A size-0 row reads as absent, like spd_dump check_part. */
uint64_t spd_check_part(struct spd *io, const char *name)
{
	char out[40];
	uint64_t size = 0;
	if (spd_resolve_part(io, name, out, sizeof(out), &size) != 0)
		return 0;
	return size;
}

/* dump TARGET OUTDIR, where TARGET is all, all_lite, preset_modem,
 * preset_resign, or a partition name.
 * Sizes come from the live table (bytes). all/all_lite also dump splloader
 * (256 KiB) like spd_dump r all. Keeps going on a failed read; returns nonzero
 * if any read failed. Slot is read from misc for name resolution and all_lite.
 */
int spd_dump(struct spd *io, const char *target, const char *outdir)
{
	char failed[1024] = "";
	int nfail = 0, i, mode, slot;
	/* One spdhost process can dump several names (the imei set). The first
	 * dump creates the manifest; a later dump in that process appends. */
	static int manifest_started;
	if (io->nparts <= 0) {
		fprintf(stderr, "dump: no partition table (run `parts` first)\n");
		return -1;
	}
	{
		char mp[1100], sp[1100];
		snprintf(mp, sizeof(mp), "%s/dump-manifest.txt", outdir);
		snprintf(sp, sizeof(sp), "%s/misc-slotinfo.img", outdir);
		manifest = fopen(mp, manifest_started ? "a" : "w");
		if (!manifest) {
			fprintf(stderr, "dump: cannot write %s: %s\n", mp, strerror(errno));
			return -1;
		}
		manifest_started = 1;
		slot_copy_path = sp;
		slot = spd_active_slot(io);
		slot_copy_path = NULL;
		fprintf(manifest, "slot %s\n", slot == 1 ? "a" : slot == 2 ? "b" : "none");
		fflush(manifest);
	}

	if (!strcmp(target, "all") || !strcmp(target, "all_lite")) {
		mode = strcmp(target, "all_lite") ? DUMP_ALL : DUMP_ALL_LITE;
		if (find_part(io, "splloader") < 0)
			dump_one(io, "splloader", SPLLOADER_BYTES, outdir, failed, sizeof(failed), &nfail);
		for (i = 0; i < io->nparts; i++) {
			if (io->ptab[i].size == 0)
				continue;
			if (skip_bulk(io->ptab[i].name, mode, slot)) {
				fprintf(stderr, "skip %s\n", io->ptab[i].name);
				continue;
			}
			dump_one(io, io->ptab[i].name, io->ptab[i].size, outdir, failed, sizeof(failed), &nfail);
		}
	} else if (!strcmp(target, "preset_modem")) {
		/* spd_dump r preset_modem: l_* and nr_* rows, then misc when A/B.
		 * spd_dump reads misc at a fixed 0..1048576 here (the slot block),
		 * not the table size. */
		if (slot > 0)
			dump_one(io, "misc", MISC_SLOT_BYTES, outdir, failed, sizeof(failed), &nfail);
		for (i = 0; i < io->nparts; i++) {
			if (!io->ptab[i].size || !preset_modem_want(io->ptab[i].name))
				continue;
			dump_one(io, io->ptab[i].name, io->ptab[i].size, outdir, failed, sizeof(failed), &nfail);
		}
	} else if (!strcmp(target, "preset_resign")) {
		/* spd_dump r preset_resign: index 7 down to 0, missing rows skipped. */
		for (i = PRESET_RESIGN_N - 1; i >= 0; i--) {
			const char *n = preset_resign[i];
			if (!strcmp(n, "splloader")) {
				if (find_part(io, n) < 0)
					dump_one(io, n, SPLLOADER_BYTES, outdir, failed, sizeof(failed), &nfail);
				continue;
			}
			{
				int idx = find_part(io, n);
				if (idx < 0 && slot > 0) {
					char nm[40];
					snprintf(nm, sizeof(nm), "%s_%c", n, slot == 1 ? 'a' : 'b');
					idx = find_part(io, nm);
				}
				if (idx < 0)
					continue; /* spd_dump falls through to the next name */
				dump_one(io, io->ptab[idx].name, io->ptab[idx].size, outdir, failed, sizeof(failed), &nfail);
			}
		}
	} else {
		/* single name: exact, else slot-suffixed, like spd_dump get_partition_info */
		int idx = find_part(io, target);
		if (idx < 0 && !strcmp(target, "splloader")) {
			dump_one(io, "splloader", SPLLOADER_BYTES, outdir, failed, sizeof(failed), &nfail);
			goto done;
		}
		if (idx < 0 && slot > 0) {
			char nm[40];
			snprintf(nm, sizeof(nm), "%s_%c", target, slot == 1 ? 'a' : 'b');
			idx = find_part(io, nm);
		}
		if (idx < 0) {
			fprintf(stderr, "dump: no partition '%s' in the live table\n", target);
			fprintf(manifest, "missing %s\n", target);
			fclose(manifest);
			manifest = NULL;
			return -1;
		}
		dump_one(io, io->ptab[idx].name, io->ptab[idx].size, outdir, failed, sizeof(failed), &nfail);
	}
done:
	fclose(manifest);
	manifest = NULL;
	if (nfail) {
		fprintf(stderr, "dump failed (%d):%s\n", nfail, failed);
		return 1;
	}
	return 0;
}

/* ---- misc guard: backup before a misc write, verify after it ---- */
static uint8_t *guard_before;
static uint64_t guard_len;

uint64_t spd_misc_size(struct spd *io)
{
	int i = find_part(io, "misc");
	return i >= 0 && io->ptab[i].size ? io->ptab[i].size : MISC_SLOT_BYTES;
}

/* misc-backup OUT: read the whole misc partition (size from the live table,
 * else 1048576 like spd_dump's slot save), write OUT, read OUT back from
 * disk and compare. Any failure is fatal to the session: the caller must not
 * go on to a misc write. */
int spd_misc_backup(struct spd *io, const char *out)
{
	uint64_t n = spd_misc_size(io), off;
	uint8_t chk[65536];
	FILE *f;
	free(guard_before);
	guard_before = NULL;
	if (!n || n > (uint64_t)SIZE_MAX) {
		fprintf(stderr, "misc-backup: refusing a %llu-byte misc read\n", (unsigned long long)n);
		goto fail;
	}
	guard_before = malloc((size_t)n);
	if (!guard_before)
		goto fail;
	if (spd_read_part_mem(io, "misc", 0, n, guard_before))
		goto fail;
	if (write_file(out, guard_before, (size_t)n))
		goto fail;
	f = fopen(out, "rb");
	if (!f)
		goto fail;
	for (off = 0; off < n; ) {
		size_t m = (size_t)((n - off) > sizeof(chk) ? sizeof(chk) : (n - off));
		if (fread(chk, 1, m, f) != m || memcmp(chk, guard_before + off, m)) {
			fclose(f);
			goto fail;
		}
		off += m;
	}
	if (fgetc(f) != EOF) {
		fclose(f);
		goto fail;
	}
	fclose(f);
	guard_len = n;
	fprintf(stderr, "misc-backup: %llu bytes -> %s (read back OK)\n", (unsigned long long)n, out);
	return 0;
fail:
	free(guard_before);
	guard_before = NULL;
	guard_len = 0;
	fprintf(stderr, "misc-backup FAILED (%s); refusing any misc write in this session\n", out);
	return -1;
}

int spd_misc_guard_armed(void)
{
	return guard_before != NULL;
}

/* After writing BUF (LEN bytes at offset 0) to misc: read the whole misc
 * back; [0,LEN) must equal BUF and [LEN,end) must equal the last image we
 * accepted. The file from misc-backup stays the pre-session copy. The
 * in-memory baseline moves forward so a later 2048-byte BCB (reboot-recovery
 * after set-active) still checks that the slot bytes were not clobbered. */
int spd_misc_verify(struct spd *io, const uint8_t *buf, size_t len)
{
	uint8_t *now;
	int rc = -1;
	if (!guard_before || len > guard_len)
		return -1;
	now = malloc(guard_len);
	if (!now)
		return -1;
	if (spd_read_part_mem(io, "misc", 0, guard_len, now) == 0) {
		if (memcmp(now, buf, len))
			fprintf(stderr, "misc-verify: first %zu bytes differ from what was written\n", len);
		else if (memcmp(now + len, guard_before + len, guard_len - len))
			fprintf(stderr, "misc-verify: bytes after %zu changed (should be untouched)\n", len);
		else {
			memcpy(guard_before, buf, len);
			rc = 0;
		}
	}
	free(now);
	if (rc == 0)
		fprintf(stderr, "misc-verify: OK (%zu bytes written, rest of %llu unchanged)\n",
			len, (unsigned long long)guard_len);
	return rc;
}
