/* In-session helpers built on the live partition table (io->ptab), so a
 * refresh + dump runs on ONE spdhost connection (no FDL2 drop between the
 * `parts` read and the reads). Name/size/slot handling matches the vendored
 * spd_dump: see spd_dump/spd_dump.c ~955-998 (r all/all_lite, splloader),
 * spd_dump/common.c ~1046-1072 (select_ab) and ~1106-1124 (unit divisor).
 */
#include "proto.h"
#include "dumpcmd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

#define SPLLOADER_BYTES (256u * 1024u)
#define MISC_SLOT_BYTES 1048576u

/* AOSP bootloader_control at misc+0x800 (spd_dump common.h): slot_suffix[4],
 * magic, version, nb_slot:3..., slot_info[4] (2 bytes each). Returns 1/2 for
 * slot a/b, 0 for "not A/B" (spd_dump select_ab semantics). */
static int slot_from_misc(const uint8_t *misc, size_t len, int have_uboot_a)
{
	const uint8_t *abc;
	int nb, p0, p1, ok0, ok1, t0, t1, d;
	if (len < 0x820)
		return 0;
	abc = misc + 0x800;
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

static int find_part(struct spd *io, const char *name)
{
	int i;
	for (i = 0; i < io->nparts; i++)
		if (strcmp(io->ptab[i].name, name) == 0)
			return i;
	return -1;
}

/* Decide the active slot for this table (reads misc 0 1048576 like spd_dump's
 * "saving slot info"). Returns 0 (not A/B), 1 (a) or 2 (b). */
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
	uint8_t *misc;
	int slot, have_a;
	if (find_part(io, "misc") < 0)
		return 0;
	misc = malloc(MISC_SLOT_BYTES);
	if (!misc)
		return 0;
	if (spd_read_part_mem(io, "misc", 0, MISC_SLOT_BYTES, misc)) {
		fprintf(stderr, "slot: misc read failed; treating as not A/B\n");
		free(misc);
		return 0;
	}
	if (slot_copy_path && write_file(slot_copy_path, misc, MISC_SLOT_BYTES))
		fprintf(stderr, "slot: could not save %s\n", slot_copy_path);
	have_a = find_part(io, "uboot_a") >= 0;
	slot = slot_from_misc(misc, MISC_SLOT_BYTES, have_a);
	free(misc);
	fprintf(stderr, "slot: %s\n", slot == 1 ? "a" : slot == 2 ? "b" : "not A/B");
	return slot;
}

static int skip_bulk(const char *n, int mode, int slot)
{
	/* spd_dump r all/all_lite: memcmp prefixes blackbox/cache/userdata. */
	if (!memcmp(n, "blackbox", 8) || !memcmp(n, "cache", 5) || !memcmp(n, "userdata", 8))
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
	char out[1024], tmp[1100], part[1100];
	snprintf(out, sizeof(out), "%s/%s.img", outdir, name);
	snprintf(tmp, sizeof(tmp), "%s.tmp", out);
	snprintf(part, sizeof(part), "%s.partial", out);
	/* manifest: "start NAME BYTES FILE" before, "ok|fail NAME" after. A start
	 * without an ok line (spdhost died mid-read) is a failure too. */
	if (manifest) {
		fprintf(manifest, "start %s %llu %s.img\n", name, (unsigned long long)size, name);
		fflush(manifest);
	}
	unlink(part);
	/* Read into NAME.img.tmp; only a complete read replaces NAME.img. A
	 * failed one is left as NAME.img.partial (an older NAME.img stays). */
	if (spd_read_part(io, name, 0, size, tmp) == 0) {
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
	return 0;
}

/* dump TARGET OUTDIR, where TARGET is all, all_lite, or a partition name.
 * Sizes come from the live table (bytes). all/all_lite also dump splloader
 * (256 KiB) like spd_dump r all. Keeps going on a failed read; returns nonzero
 * if any read failed. Slot is read from misc for name resolution and all_lite.
 */
int spd_dump(struct spd *io, const char *target, const char *outdir)
{
	char failed[1024] = "";
	int nfail = 0, i, mode, slot;
	if (io->nparts <= 0) {
		fprintf(stderr, "dump: no partition table (run `parts` first)\n");
		return -1;
	}
	{
		char mp[1100], sp[1100];
		snprintf(mp, sizeof(mp), "%s/dump-manifest.txt", outdir);
		snprintf(sp, sizeof(sp), "%s/misc-slotinfo.img", outdir);
		manifest = fopen(mp, "w");
		if (!manifest) {
			fprintf(stderr, "dump: cannot write %s: %s\n", mp, strerror(errno));
			return -1;
		}
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
	uint64_t n = spd_misc_size(io);
	uint8_t *chk;
	FILE *f;
	free(guard_before);
	guard_before = malloc(n);
	chk = malloc(n);
	if (!guard_before || !chk)
		goto fail;
	if (spd_read_part_mem(io, "misc", 0, n, guard_before))
		goto fail;
	if (write_file(out, guard_before, n))
		goto fail;
	f = fopen(out, "rb");
	if (!f || fread(chk, 1, n, f) != n || fgetc(f) != EOF || memcmp(chk, guard_before, n)) {
		if (f)
			fclose(f);
		goto fail;
	}
	fclose(f);
	free(chk);
	guard_len = n;
	fprintf(stderr, "misc-backup: %llu bytes -> %s (read back OK)\n", (unsigned long long)n, out);
	return 0;
fail:
	free(chk);
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
 * back; [0,LEN) must equal BUF and [LEN,end) must equal the backup. */
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
		else
			rc = 0;
	}
	free(now);
	if (rc == 0)
		fprintf(stderr, "misc-verify: OK (%zu bytes written, rest of %llu unchanged)\n",
			len, (unsigned long long)guard_len);
	return rc;
}
