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
	char path[512];
	char slot;
};

/* NULL and *n == 0 on refusal. Caller frees the returned array.
 * force_ab: 0 = follow the device/misc image, 1 = slot a, 2 = slot b
 * (only when that slot's files are actually in the directory). */
struct spd_op *spd_plan_writes(struct spd *io, const char *dir, int force_ab, int *n);

/* One file onto a resolved partition. Refuses a file bigger than the table
 * size. fixnv1 uses the NV framing. calinv is skipped (return 0). Does not
 * write misc and does not clear vbmeta flags. */
int spd_write_named(struct spd *io, const char *name, const char *path, int slot);
#endif
