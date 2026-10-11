/* P0-3 event channel. See events.h and README "Event channel".
 *
 * The rule this file exists to keep: the transport never waits for the
 * reader. Each event is formatted into one line (at most EV_LINE bytes,
 * well under PIPE_BUF, so a pipe or FIFO takes it whole or not at all) and
 * written once without blocking:
 *   - sockets: send(MSG_DONTWAIT | MSG_NOSIGNAL); the descriptor's flags are
 *     left alone;
 *   - pipes, FIFOs, ttys: O_NONBLOCK is set on the descriptor (and put back
 *     at the end) because write() has no per-call flag;
 *   - regular files: plain write(), which does not wait on a reader.
 * A line that cannot be written right now (EAGAIN, EINTR) is dropped and
 * counted; the next line that does go out is preceded by a `dropped` event
 * with the count. A short write (a socket or a tty can do that) keeps the rest of
 * that one line in a small pending buffer, flushed (never waited for) before
 * the next line, so lines are never interleaved or cut; while it is pending,
 * new lines are dropped. EPIPE, EBADF and other errors mean the reader is
 * gone: the channel turns off and every later event counts as dropped.
 * SIGPIPE is ignored while events are on so a closed pipe can never kill the
 * run. Every event except the `dropped` notice has a seq number, dropped or
 * not, so a reader can also see the gaps itself. */
#define _GNU_SOURCE
#include "events.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define EV_LINE 1024
#define EV_PEND 4096

int spd_ev_fd = -1;

static int ev_sock;          /* send() with MSG_DONTWAIT|MSG_NOSIGNAL */
static int ev_restore = -1;  /* original file status flags to put back */
static int ev_dead;          /* reader gone: everything counts as dropped */
static int ev_ended;
static unsigned long long ev_seq;
static unsigned long long ev_dropped_total, ev_dropped_unreported;
static long long ev_t0;
static char ev_pend[EV_PEND];
static size_t ev_pend_len;

static long long ev_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static int all_digits(const char *s)
{
	if (!*s)
		return 0;
	for (; *s; s++)
		if (*s < '0' || *s > '9')
			return 0;
	return 1;
}

int spd_ev_check_spec(const char *spec)
{
	if (!spec || !spec[0])
		return -1;
	if (all_digits(spec)) {
		long v;
		if (strlen(spec) > 9)
			return -1;
		v = strtol(spec, NULL, 10);
		if (v < 3 || fcntl((int)v, F_GETFD) == -1)
			return -1;
	}
	return 0;
}

/* One non-blocking write attempt. Returns bytes written, 0 for "not now",
 * -1 for "the reader is gone". */
static ssize_t ev_try(const char *p, size_t n)
{
	ssize_t w;
	if (ev_sock)
		w = send(spd_ev_fd, p, n, MSG_DONTWAIT | MSG_NOSIGNAL);
	else
		w = write(spd_ev_fd, p, n);
	if (w >= 0)
		return w;
	if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
		return 0;
	return -1;
}

static void ev_kill(void)
{
	ev_dead = 1;
	ev_pend_len = 0;
}

/* Push what is pending; 1 when nothing is left pending. */
static int ev_flush(void)
{
	ssize_t w;
	if (!ev_pend_len)
		return 1;
	w = ev_try(ev_pend, ev_pend_len);
	if (w < 0) {
		ev_kill();
		return 0;
	}
	memmove(ev_pend, ev_pend + w, ev_pend_len - (size_t)w);
	ev_pend_len -= (size_t)w;
	return ev_pend_len == 0;
}

static int ev_head(char *b, size_t cap, const char *ev)
{
	return snprintf(b, cap, "{\"v\":1,\"seq\":%llu,\"t\":%lld,\"ev\":\"%s\"",
		++ev_seq, ev_ms() - ev_t0, ev);
}

/* Write LINE (n bytes, ending in '\n') now or drop it. */
static void ev_put(const char *line, size_t n)
{
	char out[2 * EV_LINE];
	size_t len = 0;
	ssize_t w;

	if (ev_dead || !ev_flush()) {
		ev_dropped_total++;
		ev_dropped_unreported++;
		return;
	}
	if (ev_dropped_unreported) {
		/* No seq of its own: seq numbers belong to real events only, so
		 * their gaps are exactly the drops this notice counts. */
		int k = snprintf(out, sizeof(out),
			"{\"v\":1,\"t\":%lld,\"ev\":\"dropped\",\"count\":%llu,\"total\":%llu}\n",
			ev_ms() - ev_t0, ev_dropped_unreported, ev_dropped_total);
		len = (size_t)k;
	}
	memcpy(out + len, line, n);
	len += n;
	w = ev_try(out, len);
	if (w < 0) {
		ev_kill();
		ev_dropped_total++;
		ev_dropped_unreported++;
		return;
	}
	if (w == 0) {
		/* Not now: this line is lost; the dropped notice (if any) waits
		 * for the next line that gets through. */
		ev_dropped_total++;
		ev_dropped_unreported++;
		return;
	}
	ev_dropped_unreported = 0;
	if ((size_t)w < len) {
		/* A socket or tty can write short. Keep the rest of this line. */
		size_t rest = len - (size_t)w;
		if (rest > sizeof(ev_pend))
			rest = sizeof(ev_pend);
		memcpy(ev_pend, out + w, rest);
		ev_pend_len = rest;
	}
}

void spd_event(const char *ev, const char *fmt, ...)
{
	char line[EV_LINE];
	int k;
	va_list ap;

	if (spd_ev_fd < 0)
		return;
	k = ev_head(line, sizeof(line) - 2, ev);
	if (fmt && fmt[0] && k < (int)sizeof(line) - 2) {
		line[k++] = ',';
		va_start(ap, fmt);
		k += vsnprintf(line + k, sizeof(line) - 2 - (size_t)k, fmt, ap);
		va_end(ap);
	}
	if (k > (int)sizeof(line) - 3) {
		/* Too long for one line: send a well-formed marker instead. */
		k = snprintf(line, sizeof(line) - 2, "{\"v\":1,\"seq\":%llu,\"t\":%lld,\"ev\":\"%s\",\"truncated\":true",
			ev_seq, ev_ms() - ev_t0, ev);
	}
	line[k++] = '}';
	line[k++] = '\n';
	ev_put(line, (size_t)k);
}

void spd_ev_progress(const char *op, const char *name, uint64_t done, uint64_t total,
	uint64_t *last)
{
	char q[160];
	if (spd_ev_fd < 0)
		return;
	if (done < total && done - *last < (1u << 20) && done >= *last)
		return;
	*last = done;
	spd_event("progress", "\"op\":\"%s\",\"name\":%s,\"done\":%llu,\"total\":%llu", op,
		spd_ev_q(name, q, sizeof(q)), (unsigned long long)done, (unsigned long long)total);
}

const char *spd_ev_q(const char *s, char *buf, unsigned cap)
{
	unsigned o = 0;
	if (cap < 3) {
		if (cap)
			buf[0] = 0;
		return buf;
	}
	buf[o++] = '"';
	for (; s && *s && o + 8 < cap; s++) {
		unsigned char c = (unsigned char)*s;
		if (c == '"' || c == '\\') {
			buf[o++] = '\\';
			buf[o++] = (char)c;
		} else if (c < 0x20) {
			o += (unsigned)snprintf(buf + o, cap - o, "\\u%04x", c);
		} else {
			buf[o++] = (char)c;
		}
	}
	buf[o++] = '"';
	buf[o] = 0;
	return buf;
}

static void ev_atexit(void)
{
	spd_ev_end(-1);
}

void spd_ev_end(int rc)
{
	if (spd_ev_fd < 0 || ev_ended)
		return;
	ev_ended = 1;
	spd_event("end", "\"rc\":%d,\"dropped\":%llu", rc, ev_dropped_total);
	if (ev_pend_len)
		(void)ev_flush(); /* one last try; never waits */
	if (ev_restore >= 0)
		(void)fcntl(spd_ev_fd, F_SETFL, ev_restore);
}

void spd_ev_open(const char *spec, const char *build_sha, const char *build_dirty, int protocol)
{
	int fd;
	struct stat st;
	char q[96];

	if (!spec)
		return;
	if (all_digits(spec)) {
		fd = (int)strtol(spec, NULL, 10);
		/* Ours alone from here: children (termux-usb, popen) must not hold
		 * the reader's pipe open. FD_CLOEXEC is per descriptor, not shared. */
		(void)fcntl(fd, F_SETFD, FD_CLOEXEC);
	} else {
		/* O_NONBLOCK: a FIFO with no reader fails with ENXIO instead of
		 * waiting for one. */
		fd = open(spec, O_WRONLY | O_CREAT | O_APPEND | O_NONBLOCK | O_CLOEXEC | O_NOCTTY, 0600);
		if (fd < 0) {
			fprintf(stderr, "events: %s: %s; events off\n", spec, strerror(errno));
			return;
		}
	}
	if (fstat(fd, &st) != 0) {
		fprintf(stderr, "events: fd %d: %s; events off\n", fd, strerror(errno));
		if (!all_digits(spec))
			close(fd);
		return;
	}
	ev_sock = S_ISSOCK(st.st_mode);
	if (!ev_sock && !S_ISREG(st.st_mode)) {
		int fl = fcntl(fd, F_GETFL);
		if (fl >= 0 && !(fl & O_NONBLOCK) && fcntl(fd, F_SETFL, fl | O_NONBLOCK) == 0)
			ev_restore = fl;
	}
	signal(SIGPIPE, SIG_IGN);
	ev_t0 = ev_ms();
	spd_ev_fd = fd;
	atexit(ev_atexit);
	spd_event("start", "\"build_sha\":%s,\"build_dirty\":\"%s\",\"protocol\":%d,\"pid\":%ld",
		spd_ev_q(build_sha, q, sizeof(q)), build_dirty, protocol, (long)getpid());
}
