#ifndef SPDHOST_DUMPCMD_H
#define SPDHOST_DUMPCMD_H
#include "proto.h"
enum { DUMP_ALL = 0, DUMP_ALL_LITE = 1 };
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
uint64_t spd_misc_size(struct spd *io);
int spd_misc_backup(struct spd *io, const char *out);
int spd_misc_guard_armed(void);
int spd_misc_verify(struct spd *io, const uint8_t *buf, size_t len);
#endif
