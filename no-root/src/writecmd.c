/* Directory restore and single-partition writes.
 * Behavior follows spd_dump load_partitions / load_partition_unify, except:
 * no temporary repartition (w_force), runtimenv is written rather than
 * erased, and load_partition_unify's vbmeta 0x7B patch (write_bak_image) is
 * applied to a copy in memory instead of to the user's file on disk.
 * The directory scan visits every regular file;
 * spd_dump's readdir loop skips one entry.
 *
 * fseeko/ftello must be declared. On arm32 an implicit declaration passes
 * the 64-bit off_t in the wrong registers, and clang rejects it.
 */
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "writecmd.h"
#include "dumpcmd.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include "sha256.h"

static int file_len(const char *path, uint64_t *out)
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

/* Dump lookup reports every splloader* name as 256 KiB. A write uses the
 * live row's byte size, and no cap when that row is absent: spd_dump sends
 * the file either way. A row that really is 256 KiB still refuses a larger file. */
static uint64_t write_byte_limit(struct spd *io, const char *resolved, uint64_t lookup_size)
{
	int i;
	if (strncmp(resolved, "splloader", 9) != 0)
		return lookup_size;
	if (!io || io->nparts <= 0)
		return 0;
	for (i = 0; i < io->nparts; i++) {
		if (!strcmp(io->ptab[i].name, resolved))
			return io->ptab[i].size;
	}
	return 0;
}

static int junk_file(const char *raw, const char *name)
{
	size_t n = strlen(raw);
	if (n >= 4 && (!strcmp(raw + n - 4, ".xml") || !strcmp(raw + n - 4, ".exe") ||
		!strcmp(raw + n - 4, ".txt")))
		return 1;
	if (n >= 8 && !strcmp(raw + n - 8, ".partial"))
		return 1;
	if (n >= 4 && !strcmp(raw + n - 4, ".tmp"))
		return 1;
	/* strncmp, not memcmp: a short name must not be read past its terminator. */
	if (!strncmp(raw, "pgpt", 4) || !strncmp(raw, "sprdpart", 8) || !strncmp(raw, "fdl", 3) ||
		!strncmp(raw, "lk", 2) || !strncmp(raw, "0x", 2) || !strncmp(raw, "custom_exec", 11))
		return 1;
	if (!strcmp(name, "SHA256SUMS") || !strcmp(name, "misc-slotinfo") ||
		!strncmp(name, "misc-before-", 12) || !strncmp(name, "persist-before-", 15))
		return 1;
	return 0;
}

static int rank_of(const char *name)
{
	if (!strcmp(name, "splloader") || !strcmp(name, "uboot_a") || !strcmp(name, "uboot_b") ||
		!strcmp(name, "vbmeta_a") || !strcmp(name, "vbmeta_b"))
		return 0;
	if (!strcmp(name, "uboot") || !strcmp(name, "vbmeta") || !strncmp(name, "vbmeta_", 7))
		return 1;
	if (!strcmp(name, "super"))
		return 3;
	if (!strcmp(name, "metadata"))
		return 4;
	return 2;
}

/* Index of the table row named RESOLVED, or -1. Exact match: a lookup name is
 * already the row's own spelling by the time either caller asks. */
static int table_row_of(struct spd *io, const char *resolved)
{
	int i;
	for (i = 0; i < io->nparts; i++)
		if (!strcmp(io->ptab[i].name, resolved))
			return i;
	return -1;
}

/* The rename dance load_partition_force() (common.c 1302) performs: send the
 * live table with row IDX renamed to "w_force", write the image under that
 * name, then send the table back. The loader checks a write against the names
 * it knows, so a name it has never seen is not checked -- that is the whole
 * point, and why the reference uses it for the primary half of every
 * load_partition_unify() that has a NAME_bak row, not only for w_force.
 *
 * WHAT names the caller in the messages ("w-force", "write"). Returns 0 when
 * the write ran and the table was put back, -1 otherwise -- a failed restore is
 * reported as such, because the device is then left holding a table with a
 * "w_force" row where the target used to be. */
static int force_row_write(struct spd *io, int idx, const char *resolved, const char *path,
	const char *what)
{
	int rc;

	rc = spd_repartition_echo(io, idx, "w_force");
	if (rc == -2) {
		fprintf(stderr, "%s %s: refused before anything was sent; nothing written"
			" (the table has a row that is not a whole MiB, listed above)\n",
			what, resolved);
		return -1;
	}
	if (rc) {
		fprintf(stderr, "%s %s: the device refused the temporary table; nothing written\n",
			what, resolved);
		return -1;
	}
	rc = spd_write_part(io, "w_force", path);
	/* Back to the real name whether the write ran or not: the row is the
	 * phone's, and leaving it renamed is worse than a failed write. */
	if (spd_repartition_echo(io, idx, resolved)) {
		fprintf(stderr, "%s %s: FAILED to put the table back; the device now has a"
			" 'w_force' row in place of %s. Re-send the table (repartition, or"
			" partition-list then repartition) before using the phone.\n",
			what, resolved, resolved);
		return -1;
	}
	if (rc) {
		fprintf(stderr, "%s %s: the write failed; the table is back to normal\n",
			what, resolved);
		return -1;
	}
	fprintf(stderr, "%s %s: done, table restored\n", what, resolved);
	return 0;
}

struct plan_item {
	char name[40];
	char path[1024];
	int rank;
};

/* The *_bak half of spd_dump's load_partition_unify (common.c ~2126): on a
 * phone whose table has a same-size NAME_bak row, the image is written twice,
 * once under each name. For vbmeta the reference zeroes byte 0x7B of the image
 * first. 0x7B is the low byte of the AVB header's big-endian flags word at
 * 0x78 (bit0 hashtree disabled, bit1 verification disabled; see avb_flags
 * below) -- spd_dump's dm_disable() writes 0x01 there, dm_enable() 0x00
 * (common.c 2017-2026) -- so the backup copy always lands with both flags
 * clear, i.e. verification enabled, whatever the image carries; the primary
 * keeps the image's own byte, because it is written before this runs.
 *
 * The reference reaches for that byte with fopen(fn, "rb+") on the file the
 * user named, so a restore silently edits their dump on disk. Patching a copy
 * in memory instead sends the device exactly the bytes spd_dump sends it while
 * leaving the file its owner's; a second restore, or a re-dump, then does not
 * depend on whether a flash already ran. An image too short to hold the offset
 * is sent unchanged -- the reference would grow the file by a zero byte to
 * reach 0x7B, which is not a behavior worth copying. */
static int write_bak_image(struct spd *io, const char *bak, const char *path,
	const char *resolved, uint64_t flen)
{
	uint8_t *buf;
	int rc;

	if (strcmp(resolved, "vbmeta") != 0)
		return spd_write_part(io, bak, path);
	if (flen <= 0x7B) {
		fprintf(stderr, "write %s_bak: %s is %llu bytes, too short to hold the 0x7b verity"
			" byte; writing it unchanged\n", resolved, path, (unsigned long long)flen);
		return spd_write_part(io, bak, path);
	}
	if (flen > (64ull << 20) || flen > (uint64_t)SIZE_MAX) {
		fprintf(stderr, "write %s_bak: %s is %llu bytes, over the 64MB patch cap;"
			" writing it unchanged\n", resolved, path, (unsigned long long)flen);
		return spd_write_part(io, bak, path);
	}
	buf = malloc((size_t)flen);
	if (!buf) {
		fprintf(stderr, "write %s_bak: out of memory for a %llu-byte image; not written\n",
			resolved, (unsigned long long)flen);
		return -1;
	}
	{
		FILE *f = fopen(path, "rb");
		size_t got = f ? fread(buf, 1, (size_t)flen, f) : 0;
		if (f)
			fclose(f);
		if (got != (size_t)flen) {
			fprintf(stderr, "write %s_bak: short read on %s; not written\n", resolved, path);
			free(buf);
			return -1;
		}
	}
	/* flen was checked against the row above, so the byte is inside the file. */
	fprintf(stderr, "write %s_bak: vbmeta verity byte 0x7b: %02x -> 00 (spd_dump"
		" load_partition_unify)\n", resolved, buf[0x7B]);
	buf[0x7B] = 0;
	rc = spd_write_part_buf(io, bak, buf, (size_t)flen);
	free(buf);
	return rc;
}

/* spd_dump w_mem_to_part_offset() (common.c 2073). The reference works
 * through a file because load_partition_unify() takes a path; so does this.
 * The file name is the name the user typed, not the resolved row -- that is
 * what the reference builds (`snprintf(dfile, "%s.bin", name)`), and it is
 * also the only name available when the table has not been read yet.
 *
 * `part too large` is the reference's own guard: its offset fields are 32-bit
 * (dump_partition takes uint32_t), so a partition past 4 GiB cannot be read
 * into a file to patch in the first place. */
int spd_mem_to_part_file(struct spd *io, const char *name, uint64_t offset,
	const uint8_t *mem, size_t len, const char *dir, int slot, char *out, size_t out_sz)
{
	char resolved[40];
	char tmp[1200];
	uint64_t psz = 0;
	FILE *f;
	int lk;

	/* The reference blacklists these three before anything else: they are
	 * the partitions whose contents the phone rewrites on every boot, so a
	 * patched copy is meaningless (and on a live device, harmful). */
	if (strstr(name, "fixnv") || strstr(name, "runtimenv") || strstr(name, "userdata")) {
		fprintf(stderr, "wof/wov %s: blacklisted (fixnv / runtimenv / userdata),"
			" as in spd_dump\n", name);
		return -1;
	}
	lk = spd_lookup_part(io, name, slot, resolved, sizeof(resolved), &psz);
	if (lk < 0 || !psz) {
		/* The reference's own guard, and its words: `part not exist`. It gets
		 * here with gPartInfo.size == 0, which its get_partition_info(io,name,1)
		 * can only reach for a name that is not in the table -- so an
		 * unresolved row is a refusal there too, never a write. Every menu
		 * write path reads the table (`parts`) before it writes. */
		fprintf(stderr, "wof/wov %s: part not exist\n", name);
		return -1;
	}
	if (psz > 0xffffffffu) {
		fprintf(stderr, "wof/wov %s: partition is %llu bytes, past the 32-bit"
			" limit spd_dump reads it with\n", name, (unsigned long long)psz);
		return -1;
	}
	if (offset > psz) {
		fprintf(stderr, "wof/wov %s: offset %llu is past the end of the %llu-byte"
			" partition\n", name, (unsigned long long)offset, (unsigned long long)psz);
		return -1;
	}
	if (dir && dir[0])
		snprintf(tmp, sizeof(tmp), "%s/%s.bin", dir, name);
	else
		snprintf(tmp, sizeof(tmp), "%s.bin", name);
	if (strlen(tmp) + 1 > out_sz) {
		fprintf(stderr, "wof/wov %s: path too long\n", name);
		return -1;
	}
	strcpy(out, tmp);

	if (offset == 0) {
		f = fopen(out, "wb");
		if (!f) {
			fprintf(stderr, "wof/wov %s: open %s: %s\n", name, out, strerror(errno));
			return -1;
		}
		if (len && fwrite(mem, 1, len, f) != len) {
			fprintf(stderr, "wof/wov %s: write %s failed\n", name, out);
			fclose(f);
			return -1;
		}
		if (fclose(f) != 0) {
			fprintf(stderr, "wof/wov %s: close %s: %s\n", name, out, strerror(errno));
			return -1;
		}
		fprintf(stderr, "wof/wov %s: %zu bytes at offset 0 -> %s\n", name, len, out);
		return 0;
	}

	/* Past offset 0: the whole partition, then the patch. A short or failed
	 * read leaves nothing behind (the reference removes the file). */
	if (spd_read_part(io, resolved, 0, psz, out)) {
		remove(out);
		fprintf(stderr, "wof/wov %s: could not read the whole partition; nothing written\n",
			name);
		return -1;
	}
	f = fopen(out, "rb+");
	if (!f) {
		fprintf(stderr, "wof/wov %s: reopen %s: %s\n", name, out, strerror(errno));
		remove(out);
		return -1;
	}
	if (fseeko(f, (off_t)offset, SEEK_SET) != 0 || (len && fwrite(mem, 1, len, f) != len)) {
		fprintf(stderr, "wof/wov %s: patch at %llu in %s failed\n", name,
			(unsigned long long)offset, out);
		fclose(f);
		remove(out);
		return -1;
	}
	if (fclose(f) != 0) {
		fprintf(stderr, "wof/wov %s: close %s: %s\n", name, out, strerror(errno));
		remove(out);
		return -1;
	}
	fprintf(stderr, "wof/wov %s: %zu bytes at offset %llu of %llu -> %s\n", name, len,
		(unsigned long long)offset, (unsigned long long)psz, out);
	return 0;
}

int spd_write_named(struct spd *io, const char *name, const char *path, int slot)
{
	char resolved[40], bak[48];
	uint64_t psz = 0, bsz = 0, flen = 0, live = 0;
	int lk, bk, idx, failed = 0, rc;
	if (!strcmp(name, "misc")) {
		fprintf(stderr, "write %s: misc goes through the backup path\n", name);
		return -1;
	}
	lk = spd_lookup_part(io, name, slot, resolved, sizeof(resolved), &psz);
	if (lk == -1) {
		fprintf(stderr, "write %s: not in the live partition table\n", name);
		return -1;
	}
	if (lk == -2)
		fprintf(stderr, "write %s: no partition table yet; sending this name as given\n", name);
	/* The literal check above is not enough: a numeric id is expanded by
	 * spd_lookup_part() to the table row's real name, so `write-part 5 FILE`
	 * reaches here with resolved="misc" and would write raw bytes to misc with
	 * none of the size/backup/read-back guards write_misc_image() enforces.
	 * (write-parts already compares the resolved name this way.) */
	if (!strcmp(resolved, "misc")) {
		fprintf(stderr, "write %s: resolves to misc, which goes through the backup path\n",
			name);
		return -1;
	}
	if (!strcmp(resolved, "calinv")) {
		fprintf(stderr, "write calinv: skipped (spd_dump does not restore calinv)\n");
		return 0;
	}
	if (file_len(path, &flen) || flen == 0) {
		fprintf(stderr, "write %s: %s is missing or empty\n", resolved, path);
		return -1;
	}
	psz = write_byte_limit(io, resolved, psz);
	if (psz && flen > psz) {
		fprintf(stderr, "write %s: file is %llu bytes, partition is %llu; nothing sent\n",
			resolved, (unsigned long long)flen, (unsigned long long)psz);
		return -1;
	}
	if (strstr(resolved, "fixnv1"))
		return spd_write_nv(io, resolved, path);
	if (strstr(resolved, "runtimenv"))
		fprintf(stderr, "write %s: spd_dump erases runtimenv instead of restoring the file; writing the file\n",
			resolved);
	/* Which half of spd_dump's load_partition_unify() (common.c 2102) this
	 * write is. The reference takes the plain write when the device is A/B --
	 * except for vbmeta, whose `if (vbmeta) isVBMETA = 1; else if (selected_ab
	 * > 0 || ...)` chain never reaches the early return (common.c 2108-2114)
	 * -- and when splloader is the target, when there is no table, or when no
	 * NAME_bak row exists. Otherwise the primary goes through load_partition_force()
	 * and, if the device's size for the primary equals the NAME_bak row, the
	 * image is written a second time under NAME_bak. */
	if ((slot > 0 && strcmp(resolved, "vbmeta")) ||
		io->storage == SPD_STORAGE_NAND || !strncmp(resolved, "splloader", 9) ||
		io->nparts <= 0 || strlen(resolved) + 4 >= sizeof(bak))
		return spd_write_part(io, resolved, path);
	snprintf(bak, sizeof(bak), "%s_bak", resolved);
	bk = spd_lookup_part(io, bak, 0, bak, sizeof(bak), &bsz);
	if (bk != 0)
		return spd_write_part(io, resolved, path);

	/* size0 is not the row's size: load_partition_unify() asks the DEVICE,
	 * `size0 = check_partition(io, name0, 1)` (common.c 2122), and compares
	 * that against the NAME_bak row. It runs before the force write, as in the
	 * reference, and it is the same probe read-part uses for a 0xffffffff size
	 * -- so the frames here are the reference's, including the NAND fallback
	 * that sets io->storage. */
	/* H1: the primary half echoes the whole table back to the phone in MiB.
	 * A row that is not a whole MiB would go back rounded down, so refuse the
	 * pair here, before any frame -- the probe below included. */
	if (spd_ptab_mib_unsafe(io, (unsigned)io->nparts, "write")) {
		fprintf(stderr, "write %s: refused; %s has a %s_bak twin, which spd_dump writes with"
			" a temporary repartition, and this table cannot be sent back unchanged."
			" Nothing written.\n", resolved, resolved, resolved);
		return -1;
	}
	live = spd_check_partition(io, resolved, 1, slot);

	/* The primary half. load_partition_force() renames the row to "w_force"
	 * and back for the same reason the standalone w-force command exists: the
	 * loader does not size-check a name it has never seen, and a dual-copy
	 * phone's row for uboot or vbmeta is not the size of the image being
	 * restored. It runs before the size comparison, as in the reference --
	 * the rename is not conditional on size0 == size1. */
	idx = table_row_of(io, resolved);
	if (idx < 0) {
		fprintf(stderr, "write %s: %s is not a table row\n", resolved, resolved);
		return -1;
	}
	failed = force_row_write(io, idx, resolved, path, "write") != 0;
	/* load_partition_force() is void and its caller never looks at the result
	 * (common.c 1321, 2126), so a primary that fails does NOT stop the
	 * NAME_bak copy there. Match that: the second copy is the one that boots
	 * when the first is broken, which is why the pair is written at all. The
	 * failure is still reported, and still fails the command. */
	if (failed)
		fprintf(stderr, "write %s: the primary copy failed; writing %s_bak anyway,"
			" as spd_dump does\n", resolved, resolved);

	if (live != bsz) {
		fprintf(stderr, "write %s_bak: the device reports %s as %llu bytes and %s_bak is"
			" %llu; the second copy is not written (spd_dump writes it only when they"
			" match)\n", resolved, resolved, (unsigned long long)live, resolved,
			(unsigned long long)bsz);
		return failed ? -1 : 0;
	}
	fprintf(stderr, "write %s_bak: same size, normal write (no repartition)\n", resolved);
	rc = write_bak_image(io, bak, path, resolved, flen);
	return (failed || rc) ? -1 : 0;
}

/* spd_dump's w_force: the write that gets through when a plain write does not.
 *
 * load_partition_force() (common.c ~1302) renames the target row to the
 * literal "w_force" in a temporary table, sends that table, writes the image
 * to the name "w_force", then sends the original table back. The reference
 * does this on every `w` where a NAME_bak row exists, and exposes it directly
 * as `w_force NAME FILE`.
 *
 * Why it works: the loader checks a write against the partition names it
 * knows, so a name it has never seen is not checked. That is also why this is
 * the one write that does not refuse a file larger than the row -- the row is
 * not what stops it, so a file past the row's size is exactly the case this
 * exists for. It is printed, not blocked, and never sent without a confirm.
 *
 * Two rows are refused outright. splloader is the reference's own blacklist
 * (spd_dump.c ~1139); it is a raw offset rather than a table row, and a
 * restore that fails midway would leave the phone with no row to write back.
 * misc keeps our rule from spd_write_named(): it goes through the backup path
 * with its own guards, rename or not. */
int spd_write_force(struct spd *io, const char *name, const char *path, int slot)
{
	char resolved[40];
	uint64_t psz = 0, flen = 0;
	int idx;

	/* spd_dump refuses this verb outright on a NAND phone, before it even looks
	 * for the table (spd_dump.c:1130): on UBI the layout is not the GPT one, so
	 * a renamed row means nothing, and the force is how a phone loses its table.
	 * IO->STORAGE is set by the flash-info exchange in the fdl2 stage, by every
	 * table read, and by a refused 0xffffffff size probe. */
	if (io->storage == SPD_STORAGE_NAND) {
		fprintf(stderr, "w-force is not allowed on NAND(UBI) devices\n");
		return -1;
	}
	if (io->nparts <= 0) {
		fprintf(stderr, "w-force %s: no partition table (run parts in this session first)\n", name);
		return -1;
	}
	/* The row is looked up by name, so a numeric id has to resolve to the
	 * row it names before the index search -- exactly as spd_write_named
	 * does, and for the same reason: `w-force 5 FILE` must not rename row 5
	 * when the table says row 5 is something else. SLOT is the active slot,
	 * so `w-force boot FILE` on an A/B phone renames boot_a. */
	if (spd_lookup_part(io, name, slot, resolved, sizeof(resolved), &psz)) {
		fprintf(stderr, "w-force %s: not in the live partition table\n", name);
		return -1;
	}
	idx = table_row_of(io, resolved);
	if (idx < 0) {
		fprintf(stderr, "w-force %s: %s is not a table row\n", name, resolved);
		return -1;
	}
	if (!strncmp(resolved, "splloader", 9) || !strcmp(resolved, "misc")) {
		fprintf(stderr, "w-force %s: refused; splloader (the reference blacklists it) and misc"
			" (its own backup path) are never force-written\n", resolved);
		return -1;
	}
	if (file_len(path, &flen) || flen == 0) {
		fprintf(stderr, "w-force %s: %s is missing or empty\n", resolved, path);
		return -1;
	}
	fprintf(stderr, "w-force %s: renaming table row %d to 'w_force', writing %llu bytes, then"
		" sending the table back\n", resolved, idx + 1, (unsigned long long)flen);
	if (psz && flen > psz)
		fprintf(stderr, "w-force %s: WARNING the file is %llu bytes and the row is %llu;"
			" a force write does not stop at the row, so it can run into the next"
			" partition\n", resolved, (unsigned long long)flen, (unsigned long long)psz);

	return force_row_write(io, idx, resolved, path, "w-force");
}

struct spd_op *spd_plan_writes(struct spd *io, const char *dir, int force_ab, int flash_each, int *n)
{
	DIR *dp;
	struct dirent *de;
	struct plan_item *items = NULL;
	struct spd_op *ops;
	int nitems = 0, cap = 0, i, pass, vab = 0, slot, have_a, super = 0, metadata = 0;
	char misc_path[1024];
	misc_path[0] = 0;
	*n = 0;
	if (!dir || !dir[0]) {
		fprintf(stderr, "write-parts: missing directory\n");
		return NULL;
	}
	if (io->nparts <= 0) {
		fprintf(stderr, "write-parts: no partition table (run parts in this session first)\n");
		return NULL;
	}
	dp = opendir(dir);
	if (!dp) {
		fprintf(stderr, "write-parts: open %s: %s\n", dir, strerror(errno));
		return NULL;
	}
	while ((de = readdir(dp)) != NULL) {
		char raw[256], name[40], path[1024];
		struct stat st;
		size_t namelen;
		char *dot;
		if (de->d_name[0] == '.')
			continue;
		snprintf(raw, sizeof(raw), "%s", de->d_name);
		snprintf(path, sizeof(path), "%s/%s", dir, de->d_name);
		if (stat(path, &st) != 0 || !S_ISREG(st.st_mode))
			continue;
		namelen = strlen(raw);
		dot = strrchr(raw, '.');
		if (dot && (size_t)(dot - raw) < sizeof(name)) {
			memcpy(name, raw, (size_t)(dot - raw));
			name[dot - raw] = 0;
		} else if (namelen < sizeof(name)) {
			snprintf(name, sizeof(name), "%s", raw);
		} else {
			fprintf(stderr, "write-parts: skipping long name %s\n", raw);
			continue;
		}
		if (junk_file(de->d_name, name))
			continue;
		namelen = strlen(name);
		if (namelen >= 4 && !strcmp(name + namelen - 4, "_bak"))
			continue;
		if (namelen > 2 && !strcmp(name + namelen - 2, "_a"))
			vab |= 1;
		else if (namelen > 2 && !strcmp(name + namelen - 2, "_b"))
			vab |= 2;
		if (!strcmp(name, "misc"))
			snprintf(misc_path, sizeof(misc_path), "%s", path);
		if (nitems >= cap) {
			struct plan_item *grown;
			cap = cap ? cap * 2 : 16;
			grown = realloc(items, (size_t)cap * sizeof(*items));
			if (!grown) {
				free(items);
				closedir(dp);
				return NULL;
			}
			items = grown;
		}
		snprintf(items[nitems].name, sizeof(items[nitems].name), "%s", name);
		snprintf(items[nitems].path, sizeof(items[nitems].path), "%s", path);
		items[nitems].rank = 0;
		nitems++;
	}
	closedir(dp);
	if (nitems == 0) {
		fprintf(stderr, "write-parts: no partition images in %s\n", dir);
		free(items);
		return NULL;
	}
	have_a = 0;
	for (i = 0; i < io->nparts; i++)
		if (!strcmp(io->ptab[i].name, "uboot_a"))
			have_a = 1;
	slot = spd_active_slot(io);
	if (flash_each) {
		fprintf(stderr,
			"write-files: device slot %s; every named image is written; the slot is not changed\n",
			slot == 1 ? "a" : slot == 2 ? "b" : "not A/B");
	} else if (force_ab && (force_ab & vab)) {
		slot = force_ab;
		fprintf(stderr, "write-parts: forced slot %s\n", slot == 1 ? "a" : "b");
	} else if (misc_path[0]) {
		FILE *mf = fopen(misc_path, "rb");
		uint8_t abc[32];
		int from_file = 0;
		if (mf && fseeko(mf, 0x800, SEEK_SET) == 0 && fread(abc, 1, 32, mf) == 32) {
			from_file = spd_slot_from_bytes(abc, have_a);
		}
		if (mf)
			fclose(mf);
		if (from_file)
			slot = from_file;
		else if (vab & 1)
			slot = 1;
		else if (vab & 2)
			slot = 2;
		fprintf(stderr, "write-parts: slot from %s -> %s\n", misc_path,
			slot == 1 ? "a" : slot == 2 ? "b" : "not A/B");
	}
	/* Drop the inactive slot's files, then resolve names against the table. */
	{
		int w = 0;
		for (i = 0; i < nitems; i++) {
			size_t L = strlen(items[i].name);
			uint64_t psz = 0, flen = 0;
			char resolved[40], keep[1024];
			int lk;
			/* Restore drops the inactive slot. A one-file flash (release
			 * menu option 2) writes the name the user put in input/. */
			if (!flash_each && slot == 1 && L > 2 && !strcmp(items[i].name + L - 2, "_b")) {
				fprintf(stderr, "write-parts: skip inactive %s\n", items[i].name);
				continue;
			}
			if (!flash_each && slot == 2 && L > 2 && !strcmp(items[i].name + L - 2, "_a")) {
				fprintf(stderr, "write-parts: skip inactive %s\n", items[i].name);
				continue;
			}
			lk = spd_lookup_part(io, items[i].name, slot, resolved, sizeof(resolved), &psz);
			if (lk != 0) {
				fprintf(stderr,
					"write-parts: skip %s (not in the live table); the rest of this restore continues\n",
					items[i].name);
				continue;
			}
			if (!strcmp(resolved, "calinv")) {
				fprintf(stderr, "write-parts: skip calinv\n");
				continue;
			}
			psz = write_byte_limit(io, resolved, psz);
			/* L3: a folder flash or restore never writes more than 256 KiB
			 * to splloader -- the size every splloader dump is (dumpcmd's
			 * lookup) -- even when the table has no row to cap it with, or
			 * a bigger one. A larger splloader.img in a folder is not a
			 * dump of it, and it aborts the plan like any oversized image. */
			if (!strncmp(resolved, "splloader", 9) && (psz == 0 || psz > SPLLOADER_BYTES))
				psz = SPLLOADER_BYTES;
			/* L2: misc is 2048 bytes (a BCB) or the whole live row, and
			 * nothing else is safe to write. preset_modem saves it at a fixed
			 * 1 MiB, so a phone whose misc row is another size refused the
			 * WHOLE restore here. Skip that one row, loudly, instead: misc
			 * is left exactly as it is and every other image still goes. */
			if (!strcmp(resolved, "misc") && !file_len(items[i].path, &flen) &&
				flen != 2048 && flen != psz) {
				fprintf(stderr, "write-parts: skip misc: %s is %llu bytes, and misc takes 2048"
					" bytes or the whole partition (%llu). misc is NOT written; the rest of"
					" this restore continues\n", items[i].path, (unsigned long long)flen,
					(unsigned long long)psz);
				continue;
			}
			if (file_len(items[i].path, &flen) || flen == 0 || (psz && flen > psz)) {
				fprintf(stderr, "write-parts: %s is empty or larger than the partition (%llu > %llu)\n",
					resolved, (unsigned long long)flen, (unsigned long long)psz);
				free(items);
				return NULL;
			}
			if (strstr(resolved, "fixnv1") && spd_nv_image_ok(items[i].path)) {
				fprintf(stderr,
					"write-parts: skip %s (not an NV image); the rest of this restore continues\n",
					resolved);
				continue;
			}
			snprintf(keep, sizeof(keep), "%s", items[i].path);
			snprintf(items[w].name, sizeof(items[w].name), "%s", resolved);
			snprintf(items[w].path, sizeof(items[w].path), "%s", keep);
			items[w].rank = rank_of(resolved);
			if (!strcmp(resolved, "super"))
				super = 1;
			if (!strcmp(resolved, "metadata"))
				metadata = 1;
			w++;
		}
		nitems = w;
	}
	if (nitems == 0) {
		fprintf(stderr, "write-parts: nothing left to write after slot filtering\n");
		free(items);
		return NULL;
	}
	ops = calloc((size_t)nitems + 2, sizeof(*ops));
	if (!ops) {
		free(items);
		return NULL;
	}
	for (pass = 0; pass <= 4; pass++) {
		for (i = 0; i < nitems; i++) {
			if (items[i].rank != pass)
				continue;
			ops[*n].kind = SPD_OP_WRITE;
			ops[*n].slot = slot == 1 ? 'a' : slot == 2 ? 'b' : 0;
			snprintf(ops[*n].name, sizeof(ops[*n].name), "%s", items[i].name);
			snprintf(ops[*n].path, sizeof(ops[*n].path), "%s", items[i].path);
			(*n)++;
		}
	}
	free(items);
	if (!flash_each && super && !metadata) {
		char meta_name[40];
		uint64_t meta_sz = 0;
		if (spd_lookup_part(io, "metadata", 0, meta_name, sizeof(meta_name), &meta_sz) == 0) {
			ops[*n].kind = SPD_OP_ERASE_METADATA;
			snprintf(ops[*n].name, sizeof(ops[*n].name), "metadata");
			(*n)++;
			fprintf(stderr, "write-parts: super is restored without metadata.img; metadata will be erased\n");
		} else {
			fprintf(stderr,
				"write-parts: super is restored without metadata.img, and metadata is not in the live table; leaving it alone\n");
		}
	}
	if (!flash_each && (slot == 1 || slot == 2)) {
		ops[*n].kind = SPD_OP_SET_SLOT;
		ops[*n].slot = slot == 1 ? 'a' : 'b';
		(*n)++;
	}
	return ops;
}

/* AvbVBMetaImageHeader (libavb avb_vbmeta_image.h): "AVB0" at 0, and
 * `uint32_t flags` at 120 = 0x78, big-endian like every header field. 0x7B is
 * the LOW byte of that word: bit0 AVB_VBMETA_IMAGE_FLAGS_HASHTREE_DISABLED
 * (avbtool --disable-verity), bit1 ..._VERIFICATION_DISABLED
 * (--disable-verification). spd_dump's dm_disable/dm_enable write 0x01/0x00
 * there, so verity 0 sets hashtree-disabled and clears verification-disabled.
 * The header is inside the signed data, so only an UNLOCKED bootloader boots
 * the patched image. */
#define AVB_FLAGS_OFF 0x78

static uint32_t avb_flags(const uint8_t *b)
{
	return (uint32_t)b[AVB_FLAGS_OFF] << 24 | (uint32_t)b[AVB_FLAGS_OFF + 1] << 16 |
		(uint32_t)b[AVB_FLAGS_OFF + 2] << 8 | b[AVB_FLAGS_OFF + 3];
}

/* V1: the partition as read, saved before the patch goes out. Returns 0 and
 * the path + sha256 printed, or -1 (nothing is written then). */
static int verity_backup(const char *dir, const char *resolved, const uint8_t *buf, size_t len)
{
	char path[1024], stamp[32], hex[65];
	time_t now = time(NULL);
	struct tm tmv;
	FILE *fo;
	int n, k;

	if (!dir || !dir[0])
		dir = ".";
	if (!localtime_r(&now, &tmv) || !strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", &tmv))
		snprintf(stamp, sizeof(stamp), "%lld", (long long)now);
	for (k = 0; k < 100; k++) {
		if (k)
			n = snprintf(path, sizeof(path), "%s/vbmeta-before-%s-%s-%d.img", dir, resolved, stamp, k);
		else
			n = snprintf(path, sizeof(path), "%s/vbmeta-before-%s-%s.img", dir, resolved, stamp);
		if (n < 0 || (size_t)n >= sizeof(path)) {
			fprintf(stderr, "verity: backup path under %s is too long; %s not written\n", dir, resolved);
			return -1;
		}
		{
			int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
			fo = fd >= 0 ? fdopen(fd, "wb") : NULL;
			if (fd >= 0 && !fo)
				close(fd);
		}
		if (fo || errno != EEXIST)
			break;
	}
	if (!fo) {
		fprintf(stderr, "verity: cannot create the backup %s: %s; %s not written\n",
			path, strerror(errno), resolved);
		return -1;
	}
	if (fwrite(buf, 1, len, fo) != len || fclose(fo) != 0) {
		fprintf(stderr, "verity: writing the backup %s failed; %s not written\n", path, resolved);
		remove(path);
		return -1;
	}
	sha256_hex(buf, len, hex);
	fprintf(stderr, "verity: original %s saved to %s (%llu bytes) sha256 %s\n",
		resolved, path, (unsigned long long)len, hex);
	return 0;
}

/* Whole-partition rewrite of one byte at 0x7B. Returns 0 written, 1 absent,
 * -1 refused or failed (a failed read does not write). */
static int verity_one(struct spd *io, const char *name, int slot, uint8_t val, int missing_ok,
	const char *bdir)
{
	char resolved[40];
	uint64_t sz = 0;
	uint8_t *buf;
	int lk;

	lk = spd_lookup_part(io, name, slot, resolved, sizeof(resolved), &sz);
	if (lk != 0 || sz == 0) {
		if (missing_ok)
			fprintf(stderr, "verity: skip %s (not in the live table)\n", name);
		return 1;
	}
	/* R1: a guessed table unit may have scaled this row; size it by the
	 * device instead, or do not touch it. */
	if (io->ptab_unit_bad) {
		uint64_t probed = spd_check_partition(io, resolved, 1, 0);
		if (!probed) {
			fprintf(stderr, "verity: table unit unverified and the device gave no size for %s;"
				" not written\n", resolved);
			return -1;
		}
		if (probed != sz)
			fprintf(stderr, "verity: table unit unverified; using the device's size for %s:"
				" %llu bytes (table says %llu)\n", resolved,
				(unsigned long long)probed, (unsigned long long)sz);
		sz = probed;
	}
	if (sz <= 0x7B) {
		fprintf(stderr,
			"verity: %s is %llu bytes; offset 0x7b is past the end; not written\n",
			resolved, (unsigned long long)sz);
		return -1;
	}
	if (sz > (64ull << 20) || sz > (uint64_t)SIZE_MAX) {
		fprintf(stderr,
			"verity: %s is %llu bytes, over the 64MB patch cap; not written\n",
			resolved, (unsigned long long)sz);
		return -1;
	}
	buf = malloc((size_t)sz);
	if (!buf) {
		fprintf(stderr, "verity: out of memory for %s; not written\n", resolved);
		return -1;
	}
	if (spd_read_part_mem(io, resolved, 0, sz, buf)) {
		free(buf);
		fprintf(stderr, "verity: read %s failed; that partition was not written\n", resolved);
		return -1;
	}
	/* V1: only a real vbmeta image is patched. A wrong row, an erased one
	 * or garbage would otherwise get a byte flipped and go back. */
	if (memcmp(buf, "AVB0", 4) != 0) {
		fprintf(stderr, "verity: %s does not start with the AVB0 magic (got %02x %02x %02x %02x);"
			" it is not a vbmeta image, so it was not patched or written\n",
			resolved, buf[0], buf[1], buf[2], buf[3]);
		free(buf);
		return -1;
	}
	if (verity_backup(bdir, resolved, buf, (size_t)sz)) {
		free(buf);
		return -1;
	}
	{
		uint32_t before = avb_flags(buf), after;
		buf[0x7B] = val;
		after = avb_flags(buf);
		fprintf(stderr, "DANGEROUS verity: %s byte 0x7b: %02x -> %02x (%llu-byte rewrite);"
			" AVB flags (BE u32 at 0x78) 0x%08x -> 0x%08x%s\n",
			resolved, (unsigned)((before) & 0xff), val, (unsigned long long)sz, before, after,
			(after & 1) ? " [hashtree disabled]" : "");
	}
	if (spd_write_part_buf(io, resolved, buf, (size_t)sz)) {
		free(buf);
		return -1;
	}
	free(buf);
	return 0;
}

int spd_verity(struct spd *io, int enable, const char *backup_dir)
{
	static const char *list[] = {
		"vbmeta", "vbmeta_system", "vbmeta_vendor",
		"vbmeta_system_ext", "vbmeta_product", "vbmeta_odm", NULL
	};
	int slot, i, wrote = 0, rc;
	uint8_t val = enable ? 0x00 : 0x01;

	if (!io || io->nparts <= 0) {
		fprintf(stderr, "verity: run parts first; nothing sent\n");
		return -1;
	}
	slot = spd_active_slot(io);
	if (!enable) {
		rc = verity_one(io, "vbmeta", slot, val, 0, backup_dir);
		if (rc != 0) {
			if (rc > 0)
				fprintf(stderr, "verity: vbmeta is not in the live table; nothing sent\n");
			else
				fprintf(stderr, "verity: vbmeta was not patched\n");
			return -1;
		}
		return 0;
	}
	for (i = 0; list[i]; i++) {
		rc = verity_one(io, list[i], slot, val, 1, backup_dir);
		if (rc < 0) {
			fprintf(stderr, "verity: stopped on %s\n", list[i]);
			return -1;
		}
		if (rc == 0)
			wrote = 1;
	}
	if (!wrote) {
		fprintf(stderr, "verity: no vbmeta partition was in the live table; nothing sent\n");
		return -1;
	}
	return 0;
}
