#ifndef SPDHOST_WRITECMD_H
#define SPDHOST_WRITECMD_H
#include "proto.h"

enum {
	SPD_OP_WRITE = 1,
	SPD_OP_ERASE_METADATA = 2,
	SPD_OP_SET_SLOT = 3
};

struct spd_op {
	int kind;
	char name[40];
	char path[1024];
	char slot;
};

/* NULL and *n == 0 on refusal. Caller frees the returned array.
 * force_ab: 0 = follow the device/misc image, 1 = slot a, 2 = slot b
 * (only when that slot's files are actually in the directory).
 * flash_each: release-menu "pasang partisi". Write every named image,
 * including the inactive slot. Do not erase metadata and do not set the slot. */
struct spd_op *spd_plan_writes(struct spd *io, const char *dir, int force_ab, int flash_each, int *n);

/* One file onto a resolved partition. Refuses a file bigger than the live
 * row. splloader uses that row, or no cap when the row is absent (the 256 KiB
 * figure is only the dump size). fixnv1 uses the NV framing. calinv is
 * skipped (return 0). Does not write misc. vbmeta byte 0x7B is spd_verity. */
int spd_write_named(struct spd *io, const char *name, const char *path, int slot);

/* spd_dump w_force: rename the target row to "w_force" in a temporary table,
 * write the image to that name, then send the original table back. The write
 * that gets through where a plain one is refused, and the only one that does
 * not refuse a file larger than the row. Refuses splloader and misc. The
 * caller has already taken the write confirm. */
int spd_write_force(struct spd *io, const char *name, const char *path, int slot);

/* spd_dump dm_disable / dm_enable: one byte at offset 0x7B of the live
 * vbmeta (slot suffix when the unsuffixed name is absent). enable=0 writes
 * 0x01 (verity off). enable=1 writes 0x00 on each vbmeta_* that exists.
 * Refuses a row that does not cover 0x7B or is over 64MB. Sends nothing on
 * refusal. The caller has already taken the dangerous confirm. */
int spd_verity(struct spd *io, int enable);
#endif
