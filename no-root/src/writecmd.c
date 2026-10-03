/* Directory restore and single-partition writes.
 * Behavior follows spd_dump load_partitions / load_partition_unify, except:
 * no temporary repartition (w_force), and runtimenv is written rather than
 * erased. vbmeta byte 0x7B is only spd_verity(), not a side effect of write.
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
		!strncmp(name, "misc-before-", 12))
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

struct plan_item {
	char name[40];
	char path[1024];
	int rank;
};

int spd_write_named(struct spd *io, const char *name, const char *path, int slot)
{
	char resolved[40], bak[48];
	uint64_t psz = 0, flen = 0;
	int lk, bk;
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
	if (spd_write_part(io, resolved, path))
		return -1;
	/* Same-size *_bak, and only when the device is not A/B. No repartition
	 * rename and no vbmeta flag change (spd_dump's w_force / byte 0x7B). */
	if (slot > 0 || !strncmp(resolved, "splloader", 9) || io->nparts <= 0)
		return 0;
	if (strlen(resolved) + 4 >= sizeof(bak))
		return 0;
	snprintf(bak, sizeof(bak), "%s_bak", resolved);
	bk = spd_lookup_part(io, bak, 0, bak, sizeof(bak), &psz);
	if (bk != 0)
		return 0;
	{
		uint64_t primary = 0;
		char primary_name[40];
		if (spd_lookup_part(io, resolved, 0, primary_name, sizeof(primary_name), &primary) ||
			primary != psz)
			return 0;
	}
	if (flen > psz)
		return 0;
	fprintf(stderr, "write %s_bak: same size, normal write (no repartition)\n", resolved);
	return spd_write_part(io, bak, path);
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
 * with its own guards, rename or not.
 *
 * Returns 0 when the write ran and the original table was put back, -1
 * otherwise. A failed restore is reported as such: the device is then left
 * holding a table with a "w_force" row where the target used to be. */
int spd_write_force(struct spd *io, const char *name, const char *path, int slot)
{
	char resolved[40];
	uint64_t psz = 0, flen = 0;
	int idx = -1, i, rc;

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
	for (i = 0; i < io->nparts; i++)
		if (!strcmp(io->ptab[i].name, resolved)) {
			idx = i;
			break;
		}
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

	if (spd_repartition_echo(io, idx, "w_force")) {
		fprintf(stderr, "w-force %s: the device refused the temporary table; nothing written\n",
			resolved);
		return -1;
	}
	rc = spd_write_part(io, "w_force", path);
	/* Back to the real name whether the write ran or not: the row is the
	 * phone's, and leaving it renamed is worse than a failed write. */
	if (spd_repartition_echo(io, idx, resolved)) {
		fprintf(stderr, "w-force %s: FAILED to put the table back; the device now has a"
			" 'w_force' row in place of %s. Re-send the table (repartition, or"
			" partition-list then repartition) before using the phone.\n", resolved, resolved);
		return -1;
	}
	if (rc) {
		fprintf(stderr, "w-force %s: the write failed; the table is back to normal\n", resolved);
		return -1;
	}
	fprintf(stderr, "w-force %s: done, table restored\n", resolved);
	return 0;
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
			if (file_len(items[i].path, &flen) || flen == 0 || (psz && flen > psz)) {
				fprintf(stderr, "write-parts: %s is empty or larger than the partition (%llu > %llu)\n",
					resolved, (unsigned long long)flen, (unsigned long long)psz);
				free(items);
				return NULL;
			}
			if (!strcmp(resolved, "misc") && flen != 2048 && flen != psz) {
				fprintf(stderr, "write-parts: misc image must be 2048 bytes or the whole partition\n");
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

/* Whole-partition rewrite of one byte at 0x7B. Returns 0 written, 1 absent,
 * -1 refused or failed (a failed read does not write). */
static int verity_one(struct spd *io, const char *name, int slot, uint8_t val, int missing_ok)
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
	fprintf(stderr, "DANGEROUS verity: %s byte 0x7b: %02x -> %02x (%llu-byte rewrite)\n",
		resolved, buf[0x7B], val, (unsigned long long)sz);
	buf[0x7B] = val;
	if (spd_write_part_buf(io, resolved, buf, (size_t)sz)) {
		free(buf);
		return -1;
	}
	free(buf);
	return 0;
}

int spd_verity(struct spd *io, int enable)
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
		rc = verity_one(io, "vbmeta", slot, val, 0);
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
		rc = verity_one(io, list[i], slot, val, 1);
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
