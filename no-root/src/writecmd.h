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

/* spd_dump w_mem_to_part_offset(): build the image file the wof / wov /
 * firstmode commands write and then flash, and hand back its path.
 *
 * At OFFSET 0 the file is exactly MEM[LEN] (spd_dump: fopen "wb" + fwrite).
 * Past 0 the whole partition is read into the file first and MEM is written
 * into it at OFFSET (spd_dump: dump_partition, then fopen "rb+", fseek,
 * fwrite) -- the phone has no partial write, so the rest of the partition has
 * to come from the phone. DIR is the `path` save directory, or NULL for the
 * current one. OUT receives DIR/NAME.bin (the name as typed, as the reference
 * builds it; the write itself still goes to the resolved row).
 *
 * Nothing is written to the phone here. 0 on success, -1 on refusal. */
int spd_mem_to_part_file(struct spd *io, const char *name, uint64_t offset,
	const uint8_t *mem, size_t len, const char *dir, int slot, char *out, size_t out_sz);
#endif
