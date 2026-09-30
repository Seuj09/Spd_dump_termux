/* Directory restore and single-partition writes.
 * Behavior follows spd_dump load_partitions / load_partition_unify, except:
 * no temporary repartition (w_force), no vbmeta flag wipe, and runtimenv is
 * written rather than erased. The directory scan visits every regular file;
 * spd_dump's readdir loop skips one entry.
 */
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
	if (!memcmp(raw, "pgpt", 4) || !memcmp(raw, "sprdpart", 8) || !memcmp(raw, "fdl", 3) ||
		!memcmp(raw, "lk", 2) || !memcmp(raw, "0x", 2) || !memcmp(raw, "custom_exec", 11))
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
	char path[512];
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
	if (!strcmp(resolved, "calinv")) {
		fprintf(stderr, "write calinv: skipped (spd_dump does not restore calinv)\n");
		return 0;
	}
	if (file_len(path, &flen) || flen == 0) {
		fprintf(stderr, "write %s: %s is missing or empty\n", resolved, path);
		return -1;
	}
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
	if (slot > 0 || !memcmp(resolved, "splloader", 9) || io->nparts <= 0)
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

struct spd_op *spd_plan_writes(struct spd *io, const char *dir, int force_ab, int *n)
{
	DIR *dp;
	struct dirent *de;
	struct plan_item *items = NULL;
	struct spd_op *ops;
	int nitems = 0, cap = 0, i, pass, vab = 0, slot, have_a, super = 0, metadata = 0;
	char misc_path[512];
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
		char raw[256], name[40], path[512];
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
	if (force_ab && (force_ab & vab)) {
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
			char resolved[40], keep[512];
			int lk;
			if (slot == 1 && L > 2 && !strcmp(items[i].name + L - 2, "_b")) {
				fprintf(stderr, "write-parts: skip inactive %s\n", items[i].name);
				continue;
			}
			if (slot == 2 && L > 2 && !strcmp(items[i].name + L - 2, "_a")) {
				fprintf(stderr, "write-parts: skip inactive %s\n", items[i].name);
				continue;
			}
			lk = spd_lookup_part(io, items[i].name, slot, resolved, sizeof(resolved), &psz);
			if (lk != 0) {
				fprintf(stderr, "write-parts: %s is not in the live table\n", items[i].name);
				free(items);
				return NULL;
			}
			if (!strcmp(resolved, "calinv")) {
				fprintf(stderr, "write-parts: skip calinv\n");
				continue;
			}
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
	if (super && !metadata) {
		ops[*n].kind = SPD_OP_ERASE_METADATA;
		snprintf(ops[*n].name, sizeof(ops[*n].name), "metadata");
		(*n)++;
		fprintf(stderr, "write-parts: super is restored without metadata.img; metadata will be erased\n");
	}
	if (slot == 1 || slot == 2) {
		ops[*n].kind = SPD_OP_SET_SLOT;
		ops[*n].slot = slot == 1 ? 'a' : 'b';
		(*n)++;
	}
	return ops;
}
