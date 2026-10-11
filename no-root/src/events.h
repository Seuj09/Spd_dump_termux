#ifndef SPDHOST_EVENTS_H
#define SPDHOST_EVENTS_H

#include <stdint.h>

/* P0-3 event channel: `--events FD|PATH` writes one JSON object per line
 * (README "Event channel"). Never blocks and never slows the transport:
 * every write is non-blocking, an event that cannot go out at once is
 * dropped and counted, and a reader that went away turns the channel off.
 *
 * spd_ev_fd is -1 when events are off; the SPD_EV* macros test it before
 * evaluating any argument, so with events off they cost one compare. */
extern int spd_ev_fd;

/* Check a --events argument without opening anything. 0 if usable. */
int spd_ev_check_spec(const char *spec);
/* Open the channel (FD: digits, an open descriptor >= 3; anything else a
 * PATH). Never fails the run: a channel that cannot be opened is reported
 * once on stderr and stays off. Emits the `start` event. */
void spd_ev_open(const char *spec, const char *build_sha, const char *build_dirty, int protocol);
/* One event: EV is the type, FMT/... the rest of the object's fields
 * (printf-style, already JSON: use spd_ev_q for strings), or "" for none. */
void spd_event(const char *ev, const char *fmt, ...)
	__attribute__((format(printf, 2, 3)));
/* Byte progress, throttled: an event when DONE reaches TOTAL or moved
 * 1 MiB past *LAST (which the caller keeps per transfer, starting at 0). */
void spd_ev_progress(const char *op, const char *name, uint64_t done, uint64_t total,
	uint64_t *last);
/* The final `end` event (rc, total dropped). Idempotent; atexit runs it with
 * rc -1 for a run that ended in exit() rather than a return from main. */
void spd_ev_end(int rc);
/* S as a JSON string literal (quotes included) in BUF; truncated to fit. */
const char *spd_ev_q(const char *s, char *buf, unsigned cap);

#define SPD_EV(...) do { if (spd_ev_fd >= 0) spd_event(__VA_ARGS__); } while (0)
#define SPD_EV_PROGRESS(...) do { if (spd_ev_fd >= 0) spd_ev_progress(__VA_ARGS__); } while (0)

#endif
