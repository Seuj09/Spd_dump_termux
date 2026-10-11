#ifndef SPDHOST_PLAN_H
#define SPDHOST_PLAN_H
/* P0-4 confirm-plan: the state the core keeps between `spdhost plan` and the
 * run that executes it with `--confirm-plan SHA` (README "Confirm-plan").
 *
 * State dir (0700, owned by this uid): SPDHOST_STATE_DIR, else
 * $XDG_STATE_HOME/spdhost, else $HOME/.local/state/spdhost. On Termux that is
 * /data/data/com.termux/files/home/.local/state/spdhost; the APK sets
 * SPDHOST_STATE_DIR to a folder under its own app-private files dir.
 *   table-last          the partition table the last real `parts` read
 *   pending/<sha>.plan  an issued, unused plan (O_CREAT|O_EXCL + fsync)
 *   used/<nonce>        a consumed nonce (O_CREAT|O_EXCL + fsync): the
 *                       single-use marker, made before the first device write
 *   staging/<nonce>/    private copies of the plan's images for one run */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include "proto.h"

/* The state dir, created on first use. NULL (with a message) when it cannot
 * be made or is not private to this uid. */
const char *spd_state_dir(void);

/* Canonical text of a table and its sha256. */
char *spd_table_text(const struct spd *io);
int spd_table_sha(const struct spd *io, char out[65]);
/* Save io's table as table-last (atomic; silent; errors ignored). */
void spd_state_save_table(const struct spd *io);
/* sha256 of table-last, -1 when there is none. */
int spd_state_table_sha(char out[65]);

/* Remove expired pending plans and used nonces, and staging dirs no run
 * holds any more. */
void spd_plan_prune(time_t now);
/* Store an issued plan (TEXT is the whole plan, ending with plan-sha256=). */
int spd_plan_store(const char *sha, const char *text);
/* The pending plan SHA, malloc'd, or NULL. */
char *spd_plan_load(const char *sha);
/* Consume NONCE: 0 = this process owns it now, 1 = already used, -1 error.
 * Removes pending/<sha>.plan after the marker is on disk. */
int spd_plan_consume(const char *nonce, const char *sha, long expires);

/* sha256 + size of a whole file. 0 or -1. */
int spd_file_sha(const char *path, char out[65], uint64_t *size);
/* Execute side, per bound image: either copy PATH into the run's staging
 * dir while hashing it (*STAGED gets the copy's path) or, when the copy does
 * not fit (or SPDHOST_PLAN_STAGE=stream), keep PATH open and hash that open
 * descriptor (*STAGED = PATH). Either way the path the write will use is
 * registered with the sha/size measured here. 0 or -1. */
/* MODE: -1 decide by free space, 0 copy, 1 stream. */
int spd_plan_take_image(const char *path, const char *nonce, const char *tag, int mode,
	char *staged, size_t cap, char sha[65], uint64_t *size);
/* 1 when BYTES would be streamed rather than copied (free space or
 * SPDHOST_PLAN_STAGE), 0 copied, -1 no staging dir. */
int spd_plan_choose(const char *nonce, uint64_t bytes);
/* Register a file the run made itself (wof/wov/firstmode image). */
int spd_plan_register_file(const char *path);
/* The bound sha256 of PATH when it is registered (readback). */
const char *spd_plan_src_sha(const char *path);
/* Turn the source hooks on (writes then read only registered files). */
void spd_plan_hooks_on(void);
/* Whether a write of PATH under confirm-plan uses a staged copy. */
int spd_plan_staged_count(void);
int spd_plan_stream_count(void);

/* %XX-escape S for a plan line. */
void spd_plan_q(FILE *f, const char *s);
#endif
