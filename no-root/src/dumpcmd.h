#ifndef SPDHOST_DUMPCMD_H
#define SPDHOST_DUMPCMD_H
#include "proto.h"
enum { DUMP_ALL = 0, DUMP_ALL_LITE = 1, DUMP_PRESET_MODEM = 2, DUMP_PRESET_RESIGN = 3 };
int spd_active_slot(struct spd *io);
/* spd_slot_from_bytes() / spd_slot_from_table() are in proto.h: select_ab()
 * needs them before this layer's table is loaded. */
/* spd_dump set_active's 32 bytes for 'a' or 'b' (CRC-32 of the first 0x1C). */
int spd_fill_slot_abc(uint8_t abc[32], char which);
/* Offline: copy IN and patch offset 0x800. No USB. */
int spd_pack_slot_file(char which, const char *in_path, const char *out_path);
/* 0 = found (out/size set). -1 = not in the live table. -2 = no table yet
 * (out is the name as given, size 0). slot 1/2 tries NAME_a / NAME_b. */
int spd_lookup_part(struct spd *io, const char *name, int slot,
	char *out, size_t cap, uint64_t *size);
/* YES authorizes the read of userdata, which spd_dump gates behind
 * check_confirm("read userdata") (common.c:811). A "no" skips that read. */
int spd_dump(struct spd *io, const char *target, const char *outdir, int yes);
/* main.c's typed confirm, read side: 1 = go ahead, 0 = the caller skips. */
int spd_confirm_read(int yes, const char *what);
/* The two read rules spd_dump's dump_partition() applies to every caller,
 * read_part included. spd_metadata_beside reads `metadata` (sized by the device)
 * into a file beside SUPER_OUT, extension and all; spd_userdata_declined is 1
 * when a userdata read was declined and must be skipped. */
int spd_metadata_beside(struct spd *io, const char *super_out, int slot);
int spd_userdata_declined(const char *name, int yes);
/* The nv1 rule: an "nv1" name reads its "...2..." twin at offset 512, size less
 * 512. *OFF is 0 when the name was not one, and ALT (>= 40 bytes) is untouched
 * then. Shared by the dump path and read-part so the two cannot drift. */
void spd_nv_read_adjust(const char *name, char *alt, size_t cap, uint64_t *off, uint64_t *n);
/* NAME's byte size from the live table, 0 when absent. check-part prints it as
 * 0/1 (spd_dump check_part), part-size prints the number (spd_dump size_part).
 * splloader is 256 KiB even with no table row (it is a raw offset on NAND). */
uint64_t spd_check_part(struct spd *io, const char *name);

/* spd_dump read_parts FILE: dump every partition the XML list names into
 * DIR/NAME.bin, in the list's order. Nonzero when any read failed. The list is
 * copied into DIR only when the caller names one (COPY_LIST), matching
 * spd_dump's `if (savepath[0])` -- with no `path DIR` the reference leaves the
 * list where it found it. */
int spd_read_parts(struct spd *io, const char *xml_path, const char *dir, int copy_list);
/* spd_dump get_partition_info: exact name, then NAME_a / NAME_b for the live
 * slot. OUT (>= 40 bytes) gets the canonical name, *SIZE the byte size.
 * 0 = found, -1 = not in the table, -2 = no table yet. */
int spd_resolve_part(struct spd *io, const char *name, char *out, size_t cap, uint64_t *size);
uint64_t spd_misc_size(struct spd *io);
int spd_misc_backup(struct spd *io, const char *out);
int spd_misc_guard_armed(void);
int spd_misc_verify(struct spd *io, const uint8_t *buf, size_t len);
#endif
