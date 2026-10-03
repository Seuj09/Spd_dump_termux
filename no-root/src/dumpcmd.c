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

/* spd_slot_from_bytes() (the bootloader_control parse) and spd_slot_from_table()
 * (the "_a row means slot A" walk) live in proto.c: select_ab() needs both of
 * them at the FDL2 stage, before any table is loaded here. */

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
void spd_nv_read_adjust(const char *name, char *alt, size_t cap,
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

/* Active slot: spd_dump select_ab(), already asked at the FDL2 stage of every
 * session that read a table. A session that never read one -- or whose answer
 * was dropped after a misc write or erase -- asks here instead. A refused read
 * is "not A/B" and the dump continues. Returns 0, 1 (a) or 2 (b). */
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
	/* The answer is kept for the session (see struct spd). slot_copy_path is
	 * a one-shot request for the raw 32 bytes, so it re-reads: a caller that
	 * wants them wants them written to that file now. */
	if (io->slot_known && !slot_copy_path)
		return io->slot;
	/* The FDL2 stage already asked the device (select_ab), so there is nothing
	 * left to read: the reference's selected_ab is what it is, and only a table
	 * that names an _a row can still promote "not A/B" to slot A
	 * (common.c:1046, 1131). The raw bytes are kept from that read too, so a
	 * dump asking for misc-slotinfo.img does not pay for a second one. */
	if (io->slot_bcb >= 0) {
		if (slot_copy_path && io->slot_abc_valid
			&& write_file(slot_copy_path, io->slot_abc, SLOT_ABC_LEN))
			fprintf(stderr, "slot: could not save %s\n", slot_copy_path);
		slot = io->slot_bcb;
		if (slot == 0)
			slot = spd_slot_from_table(io);
		spd_slot_set(io, slot);
		return slot;
	}
	if (find_part(io, "misc") < 0) {
		spd_slot_set(io, spd_slot_from_table(io));
		return io->slot;
	}
	if (spd_read_part_mem(io, "misc", SLOT_ABC_OFF, SLOT_ABC_LEN, abc)) {
		fprintf(stderr, "slot: misc+0x800 read failed; treating as not A/B\n");
		spd_slot_set(io, spd_slot_from_table(io));
		return io->slot;
	}
	if (slot_copy_path && write_file(slot_copy_path, abc, SLOT_ABC_LEN))
		fprintf(stderr, "slot: could not save %s\n", slot_copy_path);
	have_a = find_part(io, "uboot_a") >= 0;
	slot = spd_slot_from_bytes(abc, have_a);
	if (slot == 0)
		slot = spd_slot_from_table(io);
	fprintf(stderr, "slot: %s\n", slot == 1 ? "a" : slot == 2 ? "b" : "not A/B");
	spd_slot_set(io, slot);
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

/* DIR/metadata.<ext of SUPER_OUT>: spd_dump writes "metadata.bin" next to the
 * super image with the same name the reference hardcodes, in the folder and the
 * extension the super file itself got (spdhost's NAME.img vs NAME.bin). */
static void metadata_path(const char *super_out, char *out, size_t cap)
{
	const char *slash = strrchr(super_out, '/');
	const char *base = slash ? slash + 1 : super_out;
	const char *dot = strrchr(base, '.');
	size_t dir = slash ? (size_t)(slash - super_out) + 1 : 0;
	if (dir + strlen("metadata") + (dot ? strlen(dot) : 0) + 1 > cap) {
		out[0] = 0;
		return;
	}
	snprintf(out, cap, "%.*smetadata%s", (int)dir, super_out, dot ? dot : "");
}

/* spd_dump dump_partition()'s first rule (common.c:810): reading `super` also
 * reads `metadata`, and the size comes from the DEVICE -- check_partition(io,
 * "metadata", 1) -- not from the table, because metadata is what the loader
 * uses to describe the super layout. A device that will not size it is skipped
 * exactly as the reference skips it (its dump_partition is called with len 0,
 * the START is refused and no file is created). Writes metadata.<ext> beside
 * SUPER_OUT and returns 0 on success, -1 on a failed or impossible read. */
int spd_metadata_beside(struct spd *io, const char *super_out, int slot)
{
	char mp[1024];
	uint64_t n;
	metadata_path(super_out, mp, sizeof(mp));
	if (!mp[0]) {
		fprintf(stderr, "dump: metadata path too long for %s; not read\n", super_out);
		return -1;
	}
	n = spd_check_partition(io, "metadata", 1, slot);
	if (!n) {
		fprintf(stderr, "dump: %s: the device will not size metadata; not read\n", super_out);
		return -1;
	}
	fprintf(stderr, "dump: metadata beside super -> %s (%llu bytes)\n",
		mp, (unsigned long long)n);
	return spd_read_part(io, "metadata", 0, n, mp);
}

/* spd_dump dump_partition()'s userdata rule (common.c:811): the read asks
 * first, and a declined ask is not an error -- the reference returns 0 and
 * reads nothing. dump_partitions() never reaches it (userdata is skipped in
 * bulk dumps), so this only fires for a read the user named. Returns 0 when
 * the read may go ahead and 1 when it was declined. */
int spd_userdata_declined(const char *name, int yes)
{
	if (strncmp(name, "userdata", 8))
		return 0;
	if (spd_confirm_read(yes, name))
		return 0;
	fprintf(stderr, "dump: %s not read (declined)\n", name);
	return 1;
}

/* One entry to dump: name + byte size + output path. */
static FILE *manifest;
static int dump_one(struct spd *io, const char *name, uint64_t size, const char *outdir,
	char *failed, size_t failcap, int *nfail, int slot, int yes)
{
	char out[1024], tmp[1100], part[1100], alt[40];
	const char *read_name = name;
	uint64_t off = 0, n = size;
	if (!strcmp(name, "super") || size >= (512ull << 20))
		fprintf(stderr, "dump: %s is %llu bytes\n", name, (unsigned long long)size);
	snprintf(out, sizeof(out), "%s/%s.img", outdir, name);
	/* spd_dump dump_partition() reads metadata before it reads super, so the
	 * device sees the same order here. Its failure is not this dump's failure
	 * (the reference ignores the return value too): the super image is what
	 * was asked for. */
	if (!strcmp(name, "super"))
		spd_metadata_beside(io, out, slot);
	if (spd_userdata_declined(name, yes))
		return 0;
	spd_nv_read_adjust(name, alt, sizeof(alt), &off, &n);
	if (off)
		read_name = alt;
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
 * The slot is read from misc on every call, as the reference does. Caching it
 * per connection was wrong as soon as anything in the same process rewrote
 * misc -- `parts set-active b check-part boot` answered with the old slot's
 * row -- and there is nothing to save: read-part and check-part each resolve
 * once, so no caller resolves in a loop. */
int spd_resolve_part(struct spd *io, const char *name, char *out, size_t cap, uint64_t *size)
{
	return spd_lookup_part(io, name, spd_active_slot(io), out, cap, size);
}

/* NAME's byte size in the live table, resolved through the active slot; 0 when
 * the name is not in the table (a size-0 row reads as absent). One lookup feeds
 * both commands: check-part prints 0/1 like spd_dump check_part, part-size
 * prints the byte count like spd_dump size_part / part_size.
 *
 * spd_dump's check_part does not read the table at all -- it probes the device
 * with a 0x8 READ_START and reports whether the loader answered (common.c:1505,
 * used with need_size=0 at spd_dump.c:925) -- so it also works before a
 * partition_list. Ours is a table read and therefore needs `parts` first, which
 * is also why it can report a byte count the probe path cannot. */
uint64_t spd_check_part(struct spd *io, const char *name)
{
	char out[40];
	uint64_t size = 0;
	if (spd_resolve_part(io, name, out, sizeof(out), &size) != 0)
		return 0;
	return size;
}

/* spd_dump read_parts FILE (common.c dump_partitions, spd_dump.c:1021): read
 * every partition the list names, in the list's order, into DIR/NAME.bin.
 *
 * The list is the same XML `partition-list` writes and `repartition` reads,
 * so it goes through spd_xml_partitions() -- one parser, so the two commands
 * cannot disagree about what a record says. The reference's own rules, one
 * for one: userdata is skipped outright; a name the live table does not have
 * is skipped; splloader is read at its fixed 256 KiB rather than the row's
 * size; a size of 0xffffffff ("take the rest") asks the device instead of
 * the list; every other size is MiB. On A/B the misc block goes last, which
 * is what the reference calls "saving slot info".
 *
 * DIVERGENCE, deliberate: every output through the reference's my_fopen()
 * loses its directory and lands in savepath. Here DIR is explicit (default:
 * the `path` directory, else the current one), so the <name>.bin names are
 * taken as given. The list itself is copied into DIR as the reference does
 * ("saving dump list"), so the dump folder still documents what produced it.
 *
 * Returns nonzero if any read failed; the ones that worked stay. */
int spd_read_parts(struct spd *io, const char *xml_path, const char *dir, int copy_list)
{
	struct spd_xml_part *list = NULL;
	char out[1200], resolved[40];
	int n, i, nfail = 0;
	int slot = io->nparts > 0 ? spd_active_slot(io) : 0;

	n = spd_xml_partitions(xml_path, "read-parts", &list);
	if (n < 0)
		return -1;
	for (i = 0; i < n; i++) {
		uint64_t psz = 0, size;
		/* spd_dump: `if (!memcmp(name, "userdata", 8)) continue;` */
		if (!strncmp(list[i].name, "userdata", 8))
			continue;
		if (spd_lookup_part(io, list[i].name, slot, resolved, sizeof(resolved), &psz) < 0 ||
		    !psz) {
			/* spd_dump: `get_partition_info(); if (!gPartInfo.size) continue;` */
			fprintf(stderr, "read-parts: %s is not in the live table, skipped\n",
				list[i].name);
			continue;
		}
		if (!strncmp(list[i].name, "splloader", 9))
			size = 256 * 1024;
		else if (list[i].size == 0xffffffffu) {
			/* spd_dump dump_partitions: a 0xffffffff row is sized by the
			 * DEVICE (check_partition(io, name, 1)), not by the table --
			 * that is what "take the rest" means. A device that will not
			 * answer falls back to the row's own size, which is what
			 * spdhost did before the probe existed. */
			uint64_t probed = spd_check_partition(io, resolved, 1, slot);
			size = probed ? probed : psz;
			if (!probed)
				fprintf(stderr, "read-parts: %s: the device did not size it;"
					" using the table's %llu bytes\n", resolved,
					(unsigned long long)psz);
		} else
			size = (uint64_t)list[i].size << 20;
		snprintf(out, sizeof(out), "%s/%s.bin", dir, list[i].name);
		fprintf(stderr, "read-parts: [%d/%d] %s -> %s (%llu bytes)\n", i + 1, n,
			resolved, out, (unsigned long long)size);
		/* spd_dump dump_partition: `super` also reads `metadata`, before it. */
		if (!strcmp(resolved, "super"))
			spd_metadata_beside(io, out, slot);
		if (spd_read_part(io, resolved, 0, size, out))
			nfail++;
	}
	/* spd_dump: `if (selected_ab > 0) { "saving slot info"; dump misc 1 MiB }` */
	if (io->nparts > 0 && spd_active_slot(io) > 0) {
		snprintf(out, sizeof(out), "%s/misc.bin", dir);
		fprintf(stderr, "read-parts: saving slot info -> %s\n", out);
		if (spd_read_part(io, "misc", 0, 1048576, out))
			nfail++;
	}
	free(list);
	/* spd_dump: `if (savepath[0]) { "saving dump list"; rewrite the list into
	 * savepath }`. SAVEPATH IS EMPTY BY DEFAULT (common.c:232), so the
	 * reference only does this when the run was told where to put things --
	 * `path DIR` on its side, an explicit DIR argument or `path DIR` on ours.
	 * The source is read into memory before the destination is opened, because
	 * the two are the same file when DIR holds the list -- the reference does
	 * the same (loadfile, then my_fopen). Its failure is not fatal there
	 * either. */
	if (copy_list) {
		const char *base = strrchr(xml_path, '/');
		uint8_t *src;
		size_t got;
		FILE *in, *fo;

		base = base ? base + 1 : xml_path;
		in = fopen(xml_path, "rb");
		src = in ? malloc(1 << 20) : NULL;
		if (!in || !src) {
			fprintf(stderr, "read-parts: create dump list failed, skipping.\n");
		} else {
			got = fread(src, 1, 1 << 20, in);
			snprintf(out, sizeof(out), "%s/%s", dir, base);
			fo = fopen(out, "wb");
			if (fo && fwrite(src, 1, got, fo) == got) {
				fprintf(stderr, "read-parts: saving dump list -> %s\n", out);
			} else {
				fprintf(stderr, "read-parts: create dump list failed, skipping.\n");
			}
			if (fo)
				fclose(fo);
			free(src);
		}
		if (in)
			fclose(in);
	}
	if (nfail) {
		fprintf(stderr, "read-parts: %d of %d reads failed\n", nfail, n);
		return -1;
	}
	return 0;
}

/* dump TARGET OUTDIR, where TARGET is all, all_lite, preset_modem,
 * preset_resign, or a partition name.
 * Sizes come from the live table (bytes). all/all_lite also dump splloader
 * (256 KiB) like spd_dump r all. Keeps going on a failed read; returns nonzero
 * if any read failed. Slot is read from misc for name resolution and all_lite.
 */
int spd_dump(struct spd *io, const char *target, const char *outdir, int yes)
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
			dump_one(io, "splloader", SPLLOADER_BYTES, outdir, failed, sizeof(failed), &nfail, slot, yes);
		for (i = 0; i < io->nparts; i++) {
			if (io->ptab[i].size == 0)
				continue;
			if (skip_bulk(io->ptab[i].name, mode, slot)) {
				fprintf(stderr, "skip %s\n", io->ptab[i].name);
				continue;
			}
			dump_one(io, io->ptab[i].name, io->ptab[i].size, outdir, failed, sizeof(failed), &nfail, slot, yes);
		}
	} else if (!strcmp(target, "preset_modem")) {
		/* spd_dump r preset_modem: l_* and nr_* rows, then misc when A/B.
		 * spd_dump reads misc at a fixed 0..1048576 here (the slot block),
		 * not the table size. */
		if (slot > 0)
			dump_one(io, "misc", MISC_SLOT_BYTES, outdir, failed, sizeof(failed), &nfail, slot, yes);
		for (i = 0; i < io->nparts; i++) {
			if (!io->ptab[i].size || !preset_modem_want(io->ptab[i].name))
				continue;
			dump_one(io, io->ptab[i].name, io->ptab[i].size, outdir, failed, sizeof(failed), &nfail, slot, yes);
		}
	} else if (!strcmp(target, "preset_resign")) {
		/* spd_dump r preset_resign: index 7 down to 0, missing rows skipped. */
		for (i = PRESET_RESIGN_N - 1; i >= 0; i--) {
			const char *n = preset_resign[i];
			if (!strcmp(n, "splloader")) {
				if (find_part(io, n) < 0)
					dump_one(io, n, SPLLOADER_BYTES, outdir, failed, sizeof(failed), &nfail, slot, yes);
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
				dump_one(io, io->ptab[idx].name, io->ptab[idx].size, outdir, failed, sizeof(failed), &nfail, slot, yes);
			}
		}
	} else {
		/* single name: exact, else slot-suffixed, like spd_dump get_partition_info */
		int idx = find_part(io, target);
		if (idx < 0 && !strcmp(target, "splloader")) {
			dump_one(io, "splloader", SPLLOADER_BYTES, outdir, failed, sizeof(failed), &nfail, slot, yes);
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
		dump_one(io, io->ptab[idx].name, io->ptab[idx].size, outdir, failed, sizeof(failed), &nfail, slot, yes);
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
