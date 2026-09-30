/* In-session partition dumps that take names and sizes from the live table
 * read by `parts` earlier in the same session (so a table refresh and the
 * dump never need two USB sessions), plus read-back verification. */
#include "proto.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define SPLLOADER_BYTES (256u * 1024u) /* spd_dump get_partition_info / r all */
#define MISC_SLOT_BYTES 1048576u       /* spd_dump "saving slot info" misc read */

static const struct spd_part *find_part(const struct spd *io, const char *name)
{
	int i;
	for (i = 0; i < io->nparts; i++)
		if (strcmp(io->ptab[i].name, name) == 0)
			return &io->ptab[i];
	return NULL;
}

/* spd_dump ab_compare_slots(): bitfields priority:4 tries:3 successful:1. */
static int ab_compare(uint8_t a, uint8_t b)
{
	int pa = a & 15, pb = b & 15, ta = (a >> 4) & 7, tb = (b >> 4) & 7, sa = a >> 7, sb = b >> 7;
	if (pa != pb)
		return pb - pa;
	if (sa != sb)
		return sb - sa;
	return tb - ta;
}

/* spd_dump select_ab(): bootloader_control at misc+0x800; nb_slot (byte 9,
 * low 3 bits) must be 2; slot b if ab_compare_slots(b, a) < 0, else a; then
 * no uboot_a -> 0 (not A/B). Returns 0 (none), 1 (a) or 2 (b). */
int spd_slot_from_misc(const struct spd *io, const uint8_t *misc, size_t len)
{
	int sel;
	if (len < 0x820)
		return 0;
	if ((misc[0x809] & 7) != 2)
		return 0;
	sel = ab_compare(misc[0x80e], misc[0x80c]) < 0 ? 2 : 1;
	if (!find_part(io, "uboot_a"))
		sel = 0;
	return sel;
}

static int has_suffix(const char *s, const char *suf)
{
	size_t n = strlen(s), m = strlen(suf);
	return n > m && strcmp(s + n - m, suf) == 0;
}

static int write_all(const char *path, const uint8_t *p, size_t n)
{
	FILE *f = fopen(path, "wb");
	if (!f)
		return -1;
	if (fwrite(p, 1, n, f) != n) {
		fclose(f);
		return -1;
	}
	return fclose(f);
}

/* One partition: read into OUT.tmp, then rename to OUT only when the file is
 * exactly SIZE bytes; otherwise leave OUT (an older dump) alone and keep the
 * short data
