/* P0-3: drive src/events.c directly (tests/events.sh). One mode per run:
 *   fill   pipe of 4096 bytes nobody reads: 200 events, then drain, 3 more,
 *          end; prints every line that got through to stdout.
 *   epipe  read end closed before the first event: no SIGPIPE death.
 *   sock   socketpair nobody reads: send never blocks, flags untouched.
 *   flags  pipe: a private descriptor; the caller's flags never change.
 *   fallback  no private descriptor (forced): O_NONBLOCK on the shared one
 *          while open, restored by spd_ev_end.
 *   stdout no private descriptor and the fd is a dup of stdout: events off.
 *   setfl  no private descriptor and F_SETFL fails (forced): events off.
 *   long   an oversized event and JSON escaping; prints the lines.
 *   utf8   non-ASCII, invalid bytes and cuts that would land mid-character;
 *          prints the lines.
 * Built with -DSPD_EV_TEST for spd_ev_test_hooks. */
#define _GNU_SOURCE
#include "events.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static long long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static void drain(int r)
{
	char b[8192];
	ssize_t n;
	int fl = fcntl(r, F_GETFL);
	fcntl(r, F_SETFL, fl | O_NONBLOCK);
	while ((n = read(r, b, sizeof(b))) > 0)
		fwrite(b, 1, (size_t)n, stdout);
	fcntl(r, F_SETFL, fl);
}

int main(int argc, char **argv)
{
	int p[2];
	char spec[16];
	const char *mode = argc > 1 ? argv[1] : "";
	int i;

	if (!strcmp(mode, "sock")) {
		long long t0, worst = 0;
		int fl0;
		if (socketpair(AF_UNIX, SOCK_STREAM, 0, p))
			return 90;
		fl0 = fcntl(p[1], F_GETFL);
		snprintf(spec, sizeof(spec), "%d", p[1]);
		spd_ev_open(spec, "unit", "0", 1);
		for (i = 0; i < 5000; i++) {
			t0 = now_ms();
			spd_event("progress", "\"op\":\"read\",\"name\":\"x\",\"done\":%d,\"total\":5000,\"pad\":\"%0200d\"", i, 0);
			if (now_ms() - t0 > worst)
				worst = now_ms() - t0;
		}
		spd_ev_end(0);
		printf("sock worst_ms=%lld flags_same=%d\n", worst, fcntl(p[1], F_GETFL) == fl0);
		return 0;
	}
	if (pipe(p))
		return 90;
	if (!strcmp(mode, "epipe")) {
		close(p[0]);
		snprintf(spec, sizeof(spec), "%d", p[1]);
		spd_ev_open(spec, "unit", "0", 1);
		for (i = 0; i < 10; i++)
			spd_event("cmd", "\"name\":\"x\",\"state\":\"start\"");
		spd_ev_end(0);
		printf("epipe alive\n");
		return 0;
	}
	if (!strcmp(mode, "flags") || !strcmp(mode, "fallback")) {
		int before, during, after, priv_nb, priv;
		char b[2048];
		ssize_t n;
		if (!strcmp(mode, "fallback"))
			spd_ev_test_hooks(1, 0);
		before = fcntl(p[1], F_GETFL);
		snprintf(spec, sizeof(spec), "%d", p[1]);
		spd_ev_open(spec, "unit", "0", 1);
		during = fcntl(p[1], F_GETFL);
		priv = spd_ev_fd >= 0 && spd_ev_fd != p[1];
		priv_nb = spd_ev_fd >= 0 && !!(fcntl(spd_ev_fd, F_GETFL) & O_NONBLOCK);
		spd_ev_end(0);
		after = fcntl(p[1], F_GETFL);
		n = read(p[0], b, sizeof(b) - 1);
		b[n > 0 ? n : 0] = 0;
		printf("%s before_nb=%d during_nb=%d after_nb=%d cloexec=%d private=%d private_nb=%d lines=%d\n", mode,
			!!(before & O_NONBLOCK), !!(during & O_NONBLOCK), !!(after & O_NONBLOCK),
			!!(fcntl(p[1], F_GETFD) & FD_CLOEXEC), priv, priv_nb,
			(int)(strstr(b, "\"ev\":\"start\"") && strstr(b, "\"ev\":\"end\"")) + (int)!!strchr(b, '\n'));
		return 0;
	}
	if (!strcmp(mode, "stdout") || !strcmp(mode, "setfl")) {
		int fd = p[1], fl0;
		if (!strcmp(mode, "stdout")) {
			/* stdout is the pipe; the events fd is a dup of it (3>&1). */
			dup2(p[1], 1);
			fd = dup(1);
			spd_ev_test_hooks(1, 0);
		} else {
			spd_ev_test_hooks(1, 1);
		}
		fl0 = fcntl(fd, F_GETFL);
		snprintf(spec, sizeof(spec), "%d", fd);
		spd_ev_open(spec, "unit", "0", 1);
		fprintf(stderr, "%s off=%d flags_same=%d\n", mode, spd_ev_fd < 0, fcntl(fd, F_GETFL) == fl0);
		return 0;
	}
	if (!strcmp(mode, "utf8")) {
		char q[16], q96[96], q160[160], big[400];
		snprintf(spec, sizeof(spec), "%d", p[1]);
		spd_ev_open(spec, "unit", "0", 1);
		/* valid: e-acute, CJK, emoji */
		spd_event("status", "\"key\":\"ok\",\"value\":%s",
			spd_ev_q("/sdcard/\xc3\xa9t\xc3\xa9/\xe4\xb8\xad\xf0\x9f\x98\x80.bin", q160, sizeof(q160)));
		/* invalid: bad lead, stray continuation, overlong, surrogate, cut short */
		spd_event("status", "\"key\":\"bad\",\"value\":%s",
			spd_ev_q("x\xff\xfey\x80\xc0\xaf\xed\xa0\x80\xe4\xb8", q160, sizeof(q160)));
		/* 86 x 'a' + 4 x e-acute through q[96]: the cut would land mid-character */
		memset(big, 'a', 86);
		strcpy(big + 86, "\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9");
		spd_event("status", "\"key\":\"cut96\",\"value\":%s", spd_ev_q(big, q96, sizeof(q96)));
		/* a long non-ASCII path through q[160], as a loader progress name */
		memset(big, 0, sizeof(big));
		strcpy(big, "/sdcard/");
		for (i = 0; i < 60; i++)
			strcat(big, "\xe4\xb8\xad");
		strcat(big, "/fdl1-dl.bin");
		{
			uint64_t last = 0;
			spd_ev_progress("loader", big, 10, 10, &last);
		}
		/* exactly fits: no mark */
		spd_event("status", "\"key\":\"fit\",\"value\":%s", spd_ev_q("abcdefghijklm", q, sizeof(q)));
		spd_event("status", "\"key\":\"fit1\",\"value\":%s", spd_ev_q("abcdefghijklmn", q, sizeof(q)));
		spd_ev_end(0);
		drain(p[0]);
		return 0;
	}
	if (!strcmp(mode, "long")) {
		char big[3000];
		char q[64];
		memset(big, 'a', sizeof(big) - 1);
		big[sizeof(big) - 1] = 0;
		snprintf(spec, sizeof(spec), "%d", p[1]);
		spd_ev_open(spec, "unit", "0", 1);
		spd_event("status", "\"key\":\"k\",\"value\":\"%s\"", big);
		spd_event("status", "\"key\":%s,\"value\":\"v\"", spd_ev_q("a\"b\\c\n\x01", q, sizeof(q)));
		spd_ev_end(0);
		drain(p[0]);
		return 0;
	}
	if (!strcmp(mode, "fill")) {
		long long t0, worst = 0;
		fcntl(p[1], F_SETPIPE_SZ, 4096);
		snprintf(spec, sizeof(spec), "%d", p[1]);
		spd_ev_open(spec, "unit", "0", 1);
		for (i = 0; i < 200; i++) {
			t0 = now_ms();
			spd_event("progress", "\"op\":\"read\",\"name\":\"x\",\"done\":%d,\"total\":200,\"pad\":\"%060d\"", i, 0);
			if (now_ms() - t0 > worst)
				worst = now_ms() - t0;
		}
		drain(p[0]);
		for (i = 0; i < 3; i++)
			spd_event("cmd", "\"name\":\"after%d\",\"state\":\"start\"", i);
		spd_ev_end(0);
		drain(p[0]);
		fprintf(stderr, "fill worst_ms=%lld\n", worst);
		return 0;
	}
	return 2;
}
