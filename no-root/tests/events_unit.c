/* P0-3: drive src/events.c directly (tests/events.sh). One mode per run:
 *   fill   pipe of 4096 bytes nobody reads: 200 events, then drain, 3 more,
 *          end; prints every line that got through to stdout.
 *   epipe  read end closed before the first event: no SIGPIPE death.
 *   sock   socketpair nobody reads: send never blocks, flags untouched.
 *   flags  pipe: O_NONBLOCK on while open, restored by spd_ev_end.
 *   long   an oversized event and JSON escaping; prints the lines. */
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
	if (!strcmp(mode, "flags")) {
		int before = fcntl(p[1], F_GETFL), during, after;
		snprintf(spec, sizeof(spec), "%d", p[1]);
		spd_ev_open(spec, "unit", "0", 1);
		during = fcntl(p[1], F_GETFL);
		spd_ev_end(0);
		after = fcntl(p[1], F_GETFL);
		printf("flags before_nb=%d during_nb=%d after_nb=%d cloexec=%d\n", !!(before & O_NONBLOCK),
			!!(during & O_NONBLOCK), !!(after & O_NONBLOCK), !!(fcntl(p[1], F_GETFD) & FD_CLOEXEC));
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
