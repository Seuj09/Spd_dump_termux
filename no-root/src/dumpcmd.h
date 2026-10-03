#ifndef SPDHOST_DUMPCMD_H
#define SPDHOST_DUMPCMD_H
#include "proto.h"
enum { DUMP_ALL = 0, DUMP_ALL_LITE = 1, DUMP_PRESET_MODEM = 2, DUMP_PRESET_RESIGN = 3 };
int spd_active_slot(struct spd *io);
/* 32-byte bootloader_control at misc+0x800. 1 = a, 2 = b, 0 = not A/B. */
int spd_slot_from_bytes(const uint8_t *abc, int have_uboot_a);
/* spd_dump set_active's 32 bytes for 'a' or 'b' (CRC-32 of the first 0x1C). */
int spd_fill_slot_abc(uint8_t abc[32], char which);
/* Offline: copy IN and patch offset 0x800. No USB. */
int spd_pack_slot_file(char which, const char *in_path, const char *out_path);
/* 0 = found (out/size set). -1 = not in the live table. -2 = no table yet
 * (out is the name as given, size 0). slot 1/2 tries NAME_a / NAME_b. */
int spd_lookup_part(struct spd *io, const char *name, int slot,
	char *out, size_t cap, uint64_t *size);
int spd_dump(struct spd *io, const char *target, const char *outdir);
/* NAME's byte size from the live table, 0 when absent. check-part prints it as
 * 0/1 (spd_dump check_part), part-size prints the number (spd_dump size_part).
 * splloader is 256 KiB even with no table row (it is a raw offset on NAND). */
uint64_t spd_check_part(struct spd *io, const char *name);
/* spd_dump get_partition_info: exact name, then NAME_a / NAME_b for the live
 * slot. OUT (>= 40 bytes) gets the canonical name, *SIZE the byte size.
 * 0 = found, -1 = not in the table, -2 = no table yet. */
int spd_resolve_part(struct spd *io, const char *name, char *out, size_t cap, uint64_t *size);
uint64_t spd_misc_size(struct spd *io);
int spd_misc_backup(struct spd *io, const char *out);
int spd_misc_guard_armed(void);
int spd_misc_verify(struct spd *io, const uint8_t *buf, size_t len);
#endif
