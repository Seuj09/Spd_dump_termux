#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
/* P0-4 confirm-plan state: state dir, table cache, issued plans, single-use
 * nonces, image staging and the source hooks the write paths read through
 * under --confirm-plan. See plan.h for the layout. */
#include "plan.h"
#include "sha256.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

static char state_dir[1024];
static int state_ok = -1;

static int mkdir_private(const char *path)
{
	struct stat st;
	if (mkdir(path, 0700) != 0 && errno != EEXIST)
		return -1;
	if (lstat(path, &st) != 0 || !S_ISDIR(st.st_mode))
		return -1;
	if (st.st_uid != getuid() || (st.st_mode & 022))
		return -1;
	return 0;
}

static int mkdir_parents(char *path)
{
	char *p;
	for (p = path + 1; *p; p++) {
		if (*p != '/')
			continue;
		*p = 0;
		if (mkdir(path, 0700) != 0 && errno != EEXIST) {
			*p = '/';
			return -1;
		}
		*p = '/';
	}
	return 0;
}

static const char *state_dir_resolve(int quiet)
{
	const char *e, *src = "SPDHOST_STATE_DIR";
	char tmp[1200];
	static const char *const sub[] = { "pending", "used", "staging" };
	size_t k;
	if (state_ok == 1)
		return state_dir;
	if (state_ok == 0)
		return NULL;
	state_ok = quiet ? -1 : 0;
	e = getenv("SPDHOST_STATE_DIR");
	if (e && e[0]) {
		snprintf(state_dir, sizeof(state_dir), "%s", e);
	} else if ((e = getenv("XDG_STATE_HOME")) && e[0] == '/') {
		snprintf(state_dir, sizeof(state_dir), "%s/spdhost", e);
		src = "XDG_STATE_HOME";
	} else if ((e = getenv("HOME")) && e[0] == '/') {
		snprintf(state_dir, sizeof(state_dir), "%s/.local/state/spdhost", e);
		src = "HOME";
	} else {
		if (!quiet)
			fprintf(stderr, "spdhost: no state dir (set SPDHOST_STATE_DIR or HOME)\n");
		return NULL;
	}
	if (state_dir[0] != '/') {
		if (!quiet)
			fprintf(stderr, "spdhost: state dir %s (from %s) is not an absolute path\n", state_dir, src);
		return NULL;
	}
	snprintf(tmp, sizeof(tmp), "%s/", state_dir);
	if (mkdir_parents(tmp) || mkdir_private(state_dir)) {
		if (!quiet)
			fprintf(stderr, "spdhost: state dir %s cannot be made, or is not a directory owned by"
				" this user with no group/other write\n", state_dir);
		return NULL;
	}
	for (k = 0; k < sizeof(sub) / sizeof(sub[0]); k++) {
		snprintf(tmp, sizeof(tmp), "%s/%s", state_dir, sub[k]);
		if (mkdir_private(tmp)) {
			if (!quiet)
				fprintf(stderr, "spdhost: state dir %s is not private\n", tmp);
			return NULL;
		}
	}
	state_ok = 1;
	return state_dir;
}

const char *spd_state_dir(void)
{
	return state_dir_resolve(0);
}

static int fsync_dir(const char *dir)
{
	int fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC), rc;
	if (fd < 0)
		return -1;
	rc = fsync(fd);
	close(fd);
	return rc;
}

static int write_all(int fd, const void *buf, size_t n)
{
	const char *p = buf;
	while (n) {
		ssize_t w = write(fd, p, n);
		if (w < 0 && errno == EINTR)
			continue;
		if (w <= 0)
			return -1;
		p += w;
		n -= (size_t)w;
	}
	return 0;
}

/* Exclusive create + contents + fsync(file) + fsync(dir). 0, 1 = exists, -1. */
static int create_excl(const char *dir, const char *path, const char *text)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0)
		return errno == EEXIST ? 1 : -1;
	if (write_all(fd, text, strlen(text)) || fsync(fd)) {
		close(fd);
		unlink(path);
		return -1;
	}
	if (close(fd))
		return -1;
	return fsync_dir(dir) ? -1 : 0;
}

char *spd_table_text(const struct spd *io)
{
	char *buf = NULL;
	size_t len = 0;
	FILE *f;
	int i;
	if (!io || io->nparts <= 0 || !io->ptab)
		return NULL;
	f = open_memstream(&buf, &len);
	if (!f)
		return NULL;
	fprintf(f, "# spdhost-table 1 rows %d\n", io->nparts);
	for (i = 0; i < io->nparts; i++)
		fprintf(f, "%s %llu\n", io->ptab[i].name, (unsigned long long)io->ptab[i].size);
	fclose(f);
	return buf;
}

int spd_table_sha(const struct spd *io, char out[65])
{
	char *t = spd_table_text(io);
	if (!t)
		return -1;
	sha256_hex((const uint8_t *)t, strlen(t), out);
	free(t);
	return 0;
}

void spd_state_save_table(const struct spd *io)
{
	char path[1100], tmp[1100];
	const char *d;
	char *t;
	int fd;
	t = spd_table_text(io);
	if (!t)
		return;
	/* A failure to save is silent: the CLI never needed this file. */
	d = state_dir_resolve(1);
	if (!d) {
		free(t);
		return;
	}
	snprintf(path, sizeof(path), "%s/table-last", d);
	snprintf(tmp, sizeof(tmp), "%s/table-last.%ld.tmp", d, (long)getpid());
	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd >= 0) {
		if (write_all(fd, t, strlen(t)) == 0 && fsync(fd) == 0 && close(fd) == 0) {
			if (rename(tmp, path) == 0)
				fsync_dir(d);
			else
				unlink(tmp);
		} else {
			unlink(tmp);
		}
	}
	free(t);
}

int spd_file_sha(const char *path, char out[65], uint64_t *size)
{
	struct sha256_ctx c;
	static uint8_t buf[1 << 16];
	uint64_t n = 0;
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	struct stat st;
	if (fd < 0)
		return -1;
	if (fstat(fd, &st) || !S_ISREG(st.st_mode)) {
		close(fd);
		return -1;
	}
	sha256_init(&c);
	for (;;) {
		ssize_t r = read(fd, buf, sizeof(buf));
		if (r < 0 && errno == EINTR)
			continue;
		if (r < 0) {
			close(fd);
			return -1;
		}
		if (r == 0)
			break;
		sha256_update(&c, buf, (size_t)r);
		n += (uint64_t)r;
	}
	close(fd);
	sha256_final_hex(&c, out);
	if (size)
		*size = n;
	return 0;
}

int spd_state_table_sha(char out[65])
{
	char path[1100];
	const char *d = spd_state_dir();
	if (!d)
		return -1;
	snprintf(path, sizeof(path), "%s/table-last", d);
	return spd_file_sha(path, out, NULL);
}

/* The value of "KEY=" on its own line in TEXT, as a long; -1 when absent. */
static long text_long(const char *text, const char *key)
{
	size_t kl = strlen(key);
	const char *p = text;
	while (p && *p) {
		if (!strncmp(p, key, kl) && p[kl] == '=')
			return strtol(p + kl + 1, NULL, 10);
		p = strchr(p, '\n');
		if (p)
			p++;
	}
	return -1;
}

static char *slurp(const char *path, size_t cap)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	char *b;
	ssize_t n;
	size_t got = 0;
	if (fd < 0)
		return NULL;
	b = malloc(cap + 1);
	if (!b) {
		close(fd);
		return NULL;
	}
	while (got < cap && (n = read(fd, b + got, cap - got)) > 0)
		got += (size_t)n;
	close(fd);
	b[got] = 0;
	return b;
}

static void rm_tree(const char *path)
{
	DIR *dp = opendir(path);
	struct dirent *de;
	if (dp) {
		while ((de = readdir(dp)) != NULL) {
			char p[2048];
			struct stat st;
			if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
				continue;
			snprintf(p, sizeof(p), "%s/%s", path, de->d_name);
			if (lstat(p, &st) == 0 && S_ISDIR(st.st_mode))
				rm_tree(p);
			else
				unlink(p);
		}
		closedir(dp);
	}
	rmdir(path);
}

void spd_plan_prune(time_t now)
{
	static const char *const sub[] = { "pending", "used" };
	const char *d = spd_state_dir();
	size_t k;
	DIR *dp;
	struct dirent *de;
	char p[1200];
	if (!d)
		return;
	for (k = 0; k < 2; k++) {
		snprintf(p, sizeof(p), "%s/%s", d, sub[k]);
		dp = opendir(p);
		if (!dp)
			continue;
		while ((de = readdir(dp)) != NULL) {
			char f[1500], *t;
			long exp;
			if (de->d_name[0] == '.')
				continue;
			snprintf(f, sizeof(f), "%s/%s", p, de->d_name);
			t = slurp(f, 1 << 20);
			exp = t ? text_long(t, "expires-at") : -1;
			free(t);
			/* A record that cannot be read or carries no expiry is
			 * junk; it is never accepted anyway. */
			if (exp < 0 || exp < (long)now)
				unlink(f);
		}
		closedir(dp);
	}
	/* Staging dirs: a run holds staging/<nonce>/.lock (flock) while it
	 * lives; one nobody holds was left by a run that died. */
	snprintf(p, sizeof(p), "%s/staging", d);
	dp = opendir(p);
	if (!dp)
		return;
	while ((de = readdir(dp)) != NULL) {
		char f[1500], l[1600];
		int fd;
		if (de->d_name[0] == '.')
			continue;
		snprintf(f, sizeof(f), "%s/%s", p, de->d_name);
		snprintf(l, sizeof(l), "%s/.lock", f);
		fd = open(l, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
		if (fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0) {
			close(fd);
			continue;
		}
		if (fd >= 0)
			close(fd);
		rm_tree(f);
	}
	closedir(dp);
}

static int sha_ok(const char *s)
{
	return s && strlen(s) == 64 && strspn(s, "0123456789abcdef") == 64;
}

int spd_plan_store(const char *sha, const char *text)
{
	char dir[1100], path[1200];
	const char *d = spd_state_dir();
	if (!d || !sha_ok(sha))
		return -1;
	snprintf(dir, sizeof(dir), "%s/pending", d);
	snprintf(path, sizeof(path), "%s/%s.plan", dir, sha);
	return create_excl(dir, path, text) ? -1 : 0;
}

char *spd_plan_load(const char *sha)
{
	char path[1200];
	const char *d = spd_state_dir();
	if (!d || !sha_ok(sha))
		return NULL;
	snprintf(path, sizeof(path), "%s/pending/%s.plan", d, sha);
	return slurp(path, 4 << 20);
}

int spd_plan_consume(const char *nonce, const char *sha, long expires)
{
	char dir[1100], path[1200], text[160];
	const char *d = spd_state_dir();
	int rc;
	if (!d || strlen(nonce) != 32 || strspn(nonce, "0123456789abcdef") != 32)
		return -1;
	snprintf(dir, sizeof(dir), "%s/used", d);
	snprintf(path, sizeof(path), "%s/%s", dir, nonce);
	snprintf(text, sizeof(text), "plan-sha256=%s\nexpires-at=%ld\n", sha, expires);
	rc = create_excl(dir, path, text);
	if (rc)
		return rc;
	snprintf(dir, sizeof(dir), "%s/pending", d);
	snprintf(path, sizeof(path), "%s/%s.plan", dir, sha);
	unlink(path);
	fsync_dir(dir);
	return 0;
}

/* ---- sources: the files a confirm-plan run may write from ---- */

struct src {
	char path[1100];
	char sha[65];
	uint64_t size;
	int fd;        /* held open (stream mode and staged copies) */
	int staged;
	struct sha256_ctx run;
	uint64_t sent;
};
static struct src *srcs;
static int nsrcs, staged_n, stream_n;
static char run_stage[1100];
static int stage_lock = -1;

static void stage_cleanup(void)
{
	if (run_stage[0]) {
		rm_tree(run_stage);
		run_stage[0] = 0;
	}
}

static int src_add(const char *path, const char *sha, uint64_t size, int fd, int staged)
{
	struct src *g = realloc(srcs, (size_t)(nsrcs + 1) * sizeof(*srcs));
	if (!g)
		return -1;
	srcs = g;
	memset(&srcs[nsrcs], 0, sizeof(srcs[nsrcs]));
	snprintf(srcs[nsrcs].path, sizeof(srcs[nsrcs].path), "%s", path);
	snprintf(srcs[nsrcs].sha, sizeof(srcs[nsrcs].sha), "%s", sha);
	srcs[nsrcs].size = size;
	srcs[nsrcs].fd = fd;
	srcs[nsrcs].staged = staged;
	nsrcs++;
	return 0;
}

static int src_find(const char *path)
{
	int k;
	for (k = nsrcs - 1; k >= 0; k--)
		if (!strcmp(srcs[k].path, path))
			return k;
	return -1;
}

const char *spd_plan_src_sha(const char *path)
{
	int k = src_find(path);
	return k >= 0 ? srcs[k].sha : NULL;
}

static int stage_dir(const char *nonce)
{
	const char *d;
	char l[1200];
	if (run_stage[0])
		return 0;
	d = spd_state_dir();
	if (!d)
		return -1;
	snprintf(run_stage, sizeof(run_stage), "%s/staging/%s", d, nonce);
	if (mkdir_private(run_stage)) {
		run_stage[0] = 0;
		return -1;
	}
	snprintf(l, sizeof(l), "%s/.lock", run_stage);
	stage_lock = open(l, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (stage_lock < 0 || flock(stage_lock, LOCK_EX | LOCK_NB) != 0) {
		run_stage[0] = 0;
		return -1;
	}
	atexit(stage_cleanup);
	return 0;
}

static int want_stream(const char *path, uint64_t size)
{
	const char *m = getenv("SPDHOST_PLAN_STAGE");
	struct statvfs vs;
	(void)path;
	if (m && !strcmp(m, "stream"))
		return 1;
	if (m && !strcmp(m, "copy"))
		return 0;
	/* Copy only with the image plus 64 MiB to spare. */
	if (statvfs(run_stage, &vs) != 0)
		return 1;
	return (uint64_t)vs.f_bavail * vs.f_frsize < size + (64ull << 20);
}

int spd_plan_choose(const char *nonce, uint64_t bytes)
{
	if (stage_dir(nonce))
		return -1;
	return want_stream(NULL, bytes);
}

int spd_plan_take_image(const char *path, const char *nonce, const char *tag, int mode,
	char *staged, size_t cap, char sha[65], uint64_t *size)
{
	static uint8_t buf[1 << 16];
	struct sha256_ctx c;
	struct stat st;
	uint64_t n = 0;
	int in, out = -1, stream;
	const char *base;
	char dst[1300];

	if (stage_dir(nonce)) {
		fprintf(stderr, "confirm-plan: cannot make a private staging dir; nothing sent\n");
		return -1;
	}
	in = open(path, O_RDONLY | O_CLOEXEC);
	if (in < 0 || fstat(in, &st) || !S_ISREG(st.st_mode)) {
		fprintf(stderr, "confirm-plan: cannot open %s as a regular file; nothing sent\n", path);
		if (in >= 0)
			close(in);
		return -1;
	}
	stream = mode >= 0 ? mode : want_stream(path, (uint64_t)st.st_size);
	if (!stream) {
		base = strrchr(path, '/');
		base = base ? base + 1 : path;
		snprintf(dst, sizeof(dst), "%s/%s", run_stage, tag);
		if (mkdir(dst, 0700) != 0 && errno != EEXIST) {
			close(in);
			return -1;
		}
		snprintf(dst, sizeof(dst), "%s/%s/%s", run_stage, tag, base);
		out = open(dst, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
		if (out < 0) {
			fprintf(stderr, "confirm-plan: cannot stage %s: %s\n", path, strerror(errno));
			close(in);
			return -1;
		}
	}
	sha256_init(&c);
	for (;;) {
		ssize_t r = read(in, buf, sizeof(buf));
		if (r < 0 && errno == EINTR)
			continue;
		if (r < 0) {
			fprintf(stderr, "confirm-plan: read %s: %s\n", path, strerror(errno));
			goto fail;
		}
		if (r == 0)
			break;
		sha256_update(&c, buf, (size_t)r);
		if (out >= 0 && write_all(out, buf, (size_t)r)) {
			fprintf(stderr, "confirm-plan: staging %s: %s\n", path, strerror(errno));
			goto fail;
		}
		n += (uint64_t)r;
	}
	sha256_final_hex(&c, sha);
	*size = n;
	if (out >= 0) {
		if (fsync(out)) {
			fprintf(stderr, "confirm-plan: staging %s: %s\n", path, strerror(errno));
			goto fail;
		}
		close(in);
		snprintf(staged, cap, "%s", dst);
		staged_n++;
		return src_add(dst, sha, n, out, 1);
	}
	/* Stream: the write reads this same open descriptor again, hashing as it
	 * sends; a mismatch at the end marks the partition suspect. */
	snprintf(staged, cap, "%s", path);
	stream_n++;
	return src_add(path, sha, n, in, 0);
fail:
	close(in);
	if (out >= 0) {
		close(out);
		unlink(dst);
	}
	return -1;
}

int spd_plan_register_file(const char *path)
{
	char sha[65];
	uint64_t n = 0;
	int fd;
	if (spd_file_sha(path, sha, &n))
		return -1;
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	return src_add(path, sha, n, fd, 0);
}

int spd_plan_staged_count(void) { return staged_n; }
int spd_plan_stream_count(void) { return stream_n; }

static FILE *h_open(const char *path, int *h)
{
	int k = src_find(path), fd;
	FILE *f;
	if (k < 0) {
		fprintf(stderr, "confirm-plan: refusing to write from %s: it is not an image in the"
			" confirmed plan; nothing sent for it\n", path);
		return NULL;
	}
	fd = dup(srcs[k].fd);
	if (fd < 0 || lseek(fd, 0, SEEK_SET) != 0 || !(f = fdopen(fd, "rb"))) {
		if (fd >= 0)
			close(fd);
		fprintf(stderr, "confirm-plan: cannot reopen %s\n", path);
		return NULL;
	}
	sha256_init(&srcs[k].run);
	srcs[k].sent = 0;
	*h = k;
	return f;
}

static void h_update(int h, const void *buf, size_t n)
{
	if (h < 0 || h >= nsrcs)
		return;
	sha256_update(&srcs[h].run, buf, n);
	srcs[h].sent += n;
}

static int h_final(int h, const char *part)
{
	char got[65];
	if (h < 0 || h >= nsrcs)
		return -1;
	sha256_final_hex(&srcs[h].run, got);
	if (srcs[h].sent == srcs[h].size && !strcmp(got, srcs[h].sha)) {
		fprintf(stderr, "confirm-plan: %s: the %llu bytes sent hash to the planned sha256 %s\n",
			part, (unsigned long long)srcs[h].sent, got);
		return 0;
	}
	fprintf(stderr, "confirm-plan: SUSPECT %s: the bytes sent (%llu, sha256 %s) are not the"
		" planned image (%llu, sha256 %s); %s changed during the write. Stopping before"
		" the session ends; reflash %s from a good image. Backups are kept.\n",
		part, (unsigned long long)srcs[h].sent, got, (unsigned long long)srcs[h].size,
		srcs[h].sha, srcs[h].path, part);
	return -1;
}

static int h_check_buf(const char *path, const void *buf, size_t n, const char *what)
{
	int k = src_find(path);
	char got[65];
	if (k < 0) {
		fprintf(stderr, "confirm-plan: refusing %s from %s: not an image in the confirmed"
			" plan; nothing sent for it\n", what, path);
		return -1;
	}
	sha256_hex(buf, n, got);
	if ((uint64_t)n != srcs[k].size || strcmp(got, srcs[k].sha)) {
		fprintf(stderr, "confirm-plan: refusing %s: %s now hashes to %s (%zu bytes), the plan"
			" bound %s (%llu bytes); nothing sent for it\n", what, path, got, n,
			srcs[k].sha, (unsigned long long)srcs[k].size);
		return -1;
	}
	return 0;
}

static const struct spd_src_hooks plan_hooks = { h_open, h_update, h_final, h_check_buf };

void spd_plan_hooks_on(void)
{
	spd_src_hooks = &plan_hooks;
}

void spd_plan_q(FILE *f, const char *s)
{
	static const char ok[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/+:@,-";
	if (!s) {
		fputs("%00", f);
		return;
	}
	if (!*s) {
		fputs("''", f);
		return;
	}
	for (; *s; s++) {
		if (strchr(ok, *s))
			fputc(*s, f);
		else
			fprintf(f, "%%%02X", (unsigned char)*s);
	}
}
