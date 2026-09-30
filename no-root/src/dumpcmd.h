#ifndef SPDHOST_DUMPCMD_H
#define SPDHOST_DUMPCMD_H
#include "proto.h"
enum { DUMP_ALL = 0, DUMP_ALL_LITE = 1 };
int spd_active_slot(struct spd *io);
int spd_dump(struct spd *io, const char *target, const char *outdir);
uint64_t spd_misc_size(struct spd *io);
int spd_misc_backup(struct spd *io, const char *out);
int spd_misc_guard_armed(void);
int spd_misc_verify(struct spd *io, const uint8_t *buf, size_t len);
#endif
