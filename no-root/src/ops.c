/* P0-7: `ops dump` (session) and `images list` (offline). See ops.h.
 * The dump itself is spd_dump() (dumpcmd.c), unchanged: this file adds the
 * free-space preflight that runs on the live table before the first read
 * (A8, audit6 C4), and the manifest check + meta/SHA256SUMS that menu.sh did
 * in bash (verify_dump_manifest / record_sha256), so the menu and the APK get
 * the same answer from one implementation. */
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "proto.h"
#include "dumpcmd.h"
#include "writecmd.h"
#include "events.h"
#include "plan.h"
#include "sha256.h"
#include "ops.h"
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>
#include <unistd.h>

#define OPS_HEADROOM_MIB 64ul /* menu.sh require_free_space's default */
#define OPS_NAME_MAX 40       /* struct spd partition names (char[40]) */

static const char *const imei_set[] = {
	"miscdata", "prodnv", "l_fixnv1", "l_fixnv2", "l_runtimenv1", "l_runtimenv2"
};
#define IMEI_N ((int)(sizeof(imei_set) / sizeof(imei_set[0])))

static int alone_word(const char *p)
{
	return !strcmp(p, "all") || !strcmp(p, "all_lite") || !strcmp(p, "preset_modem") ||
		!strcmp(p, "preset_resign") || !strcmp(p, "imei");
}

static int name_ok(const char *p)
{
	size_t n = strlen(p), k;
	if (!n || n >= OPS_NAME_MAX || p[0] == '.' || p[0] == '-')
		return 0;
	for (k = 0; k < n; k++)
		if (p[k] == '/' || p[k] <= ' ' || p[k] == 0x7f)
			return 0;
	return 1;
}

int spd_ops_dump_args(int argc, char **argv, int i, struct spd_ops_dump_args *a)
{
	memset(a, 0, sizeof(*a));
	a->headroom_mib = OPS_HEADROOM_MIB;
	if (i + 1 >= argc || strcmp(argv[i + 1], "dump")) {
		fprintf(stderr, "ops: need `ops dump DIR --preset P`, `ops misc-reboot recovery|fastboot DIR`"
			" or `ops set-active a|b DIR`\n");
		return -1;
	}
	if (i + 2 >= argc || !argv[i + 2][0] || argv[i + 2][0] == '-') {
		fprintf(stderr, "ops dump: missing DIR\n");
		return -1;
	}
	a->dir = argv[i + 2];
	i += 3;
	while (i < argc && !strncmp(argv[i], "--", 2)) {
		if (!strcmp(argv[i], "--preset")) {
			if (i + 1 >= argc) {
				fprintf(stderr, "ops dump: --preset needs a value\n");
				return -1;
			}
			if (a->npreset >= SPD_OPS_MAX_PRESETS) {
				fprintf(stderr, "ops dump: at most %d presets\n", SPD_OPS_MAX_PRESETS);
				return -1;
			}
			if (!alone_word(argv[i + 1]) && !name_ok(argv[i + 1])) {
				fprintf(stderr, "ops dump: bad preset '%s' (all, all_lite, preset_modem,"
					" preset_resign, imei, or a partition name)\n", argv[i + 1]);
				return -1;
			}
			a->preset[a->npreset++] = argv[i + 1];
			i += 2;
		} else if (!strcmp(argv[i], "--headroom")) {
			char *end = NULL;
			unsigned long v;
			if (i + 1 >= argc) {
				fprintf(stderr, "ops dump: --headroom needs MiB\n");
				return -1;
			}
			errno = 0;
			v = strtoul(argv[i + 1], &end, 10);
			if (end == argv[i + 1] || *end || errno || v > 1048576ul) {
				fprintf(stderr, "ops dump: bad --headroom %s (MiB, 0..1048576)\n", argv[i + 1]);
				return -1;
			}
			a->headroom_mib = v;
			i += 2;
		} else {
			fprintf(stderr, "ops dump: unknown option %s\n", argv[i]);
			return -1;
		}
	}
	if (!a->npreset) {
		fprintf(stderr, "ops dump: need --preset all|all_lite|preset_modem|preset_resign|imei|NAME\n");
		return -1;
	}
	if (a->npreset > 1) {
		int k;
		for (k = 0; k < a->npreset; k++)
			if (alone_word(a->preset[k])) {
				fprintf(stderr, "ops dump: --preset %s must be the only preset\n", a->preset[k]);
				return -1;
			}
	}
	return i;
}

/* The names spd_dump is called with, in order (imei expands to its set). */
static int dump_targets(const struct spd_ops_dump_args *a, const char **t, int cap)
{
	int k, n = 0;
	if (a->npreset == 1 && !strcmp(a->preset[0], "imei")) {
		for (k = 0; k < IMEI_N && n < cap; k++)
			t[n++] = imei_set[k];
		return n;
	}
	for (k = 0; k < a->npreset && n < cap; k++)
		t[n++] = a->preset[k];
	return n;
}

static int path_join(char *out, size_t cap, const char *a, const char *b)
{
	int n = snprintf(out, cap, "%s/%s", a, b);
	return n > 0 && (size_t)n < cap ? 0 : -1;
}

/* ---- meta/SHA256SUMS (entry names relative to DIR, as menu.sh writes them) ---- */

/* SUMS path for writing: DIR/meta/SHA256SUMS. An old flat dump's root
 * SHA256SUMS moves into meta/ on the first write (menu sha256sums_path). */
static int sums_write_path(const char *dir, char *out, size_t cap)
{
	char legacy[1100];
	struct stat st;
	if (path_join(out, cap, dir, "meta/SHA256SUMS") || path_join(legacy, sizeof(legacy), dir, "SHA256SUMS"))
		return -1;
	if (stat(out, &st) != 0 && stat(legacy, &st) == 0 && S_ISREG(st.st_mode)) {
		if (rename(legacy, out) != 0) {
			fprintf(stderr, "ops dump: cannot move %s into meta/: %s\n", legacy, strerror(errno));
			return -1;
		}
	}
	return 0;
}

/* The name part of a SHA256SUMS line ("<hex>  NAME"), or NULL. */
static const char *sums_key(const char *line)
{
	const char *p = line;
	while ((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f'))
		p++;
	if (p == line || p[0] != ' ' || p[1] != ' ')
		return NULL;
	return p + 2;
}

/* Replace KEY's line with HEX (or drop it when HEX is NULL). Atomic: the new
 * file is written beside the old one and renamed over it. */
static int sums_set(const char *dir, const char *key, const char *hex)
{
	char path[1100], tmp[1200], *line = NULL;
	size_t lcap = 0;
	ssize_t got;
	FILE *in, *out;
	int fd, rc = 0, present = 0;
	if (sums_write_path(dir, path, sizeof(path)))
		return -1;
	in = fopen(path, "r");
	if (!in && !hex)
		return 0;
	snprintf(tmp, sizeof(tmp), "%s.XXXXXX", path);
	fd = mkstemp(tmp);
	if (fd < 0) {
		fprintf(stderr, "ops dump: cannot write beside %s: %s\n", path, strerror(errno));
		if (in)
			fclose(in);
		return -1;
	}
	{
		/* mkstemp makes 0600; keep the old file's mode, else 0644 less umask. */
		struct stat st;
		mode_t um = umask(0);
		umask(um);
		fchmod(fd, in && fstat(fileno(in), &st) == 0 ? (st.st_mode & 07777) : (0644 & ~um));
	}
	out = fdopen(fd, "w");
	if (!out) {
		close(fd);
		unlink(tmp);
		if (in)
			fclose(in);
		return -1;
	}
	while (in && (got = getline(&line, &lcap, in)) > 0) {
		const char *k;
		size_t kl;
		if (line[got - 1] == '\n')
			line[--got] = 0;
		k = sums_key(line);
		kl = k ? strlen(k) : 0;
		if (k && kl == strlen(key) && !memcmp(k, key, kl)) {
			present = 1;
			continue;
		}
		fprintf(out, "%s\n", line);
	}
	free(line);
	if (in)
		fclose(in);
	if (hex)
		fprintf(out, "%s  %s\n", hex, key);
	if (fflush(out) || ferror(out) || fsync(fileno(out)))
		rc = -1;
	if (fclose(out))
		rc = -1;
	if (!rc && !hex && !present) {
		unlink(tmp); /* nothing to drop; leave the file as it was */
		return 0;
	}
	if (rc || rename(tmp, path)) {
		fprintf(stderr, "ops dump: cannot update %s\n", path);
		unlink(tmp);
		return -1;
	}
	return 0;
}

/* sha256 of PATH; *BYTES gets its length. -1 on a read error. */
static int hash_file(const char *path, char hex[65], uint64_t *bytes)
{
	static uint8_t buf[1 << 20];
	struct sha256_ctx c;
	size_t n;
	FILE *f = fopen(path, "rb");
	*bytes = 0;
	if (!f)
		return -1;
	sha256_init(&c);
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
		sha256_update(&c, buf, n);
		*bytes += n;
	}
	if (ferror(f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	sha256_final_hex(&c, hex);
	return 0;
}

/* ---- the manifest check (menu.sh verify_dump_manifest, in C) ---- */
struct mrow {
	char tag[16], name[OPS_NAME_MAX], file[OPS_NAME_MAX + 8];
	unsigned long long bytes;
};

static void ev_file(const char *name, const char *file, uint64_t bytes, const char *state, const char *hex)
{
	char qn[96], qf[112];
	if (spd_ev_fd < 0)
		return;
	if (hex)
		spd_event("dump-file", "\"name\":%s,\"file\":%s,\"bytes\":%llu,\"state\":\"%s\",\"sha256\":\"%s\"",
			spd_ev_q(name, qn, sizeof(qn)), spd_ev_q(file, qf, sizeof(qf)),
			(unsigned long long)bytes, state, hex);
	else
		spd_event("dump-file", "\"name\":%s,\"file\":%s,\"bytes\":%llu,\"state\":\"%s\"",
			spd_ev_q(name, qn, sizeof(qn)), spd_ev_q(file, qf, sizeof(qf)),
			(unsigned long long)bytes, state);
}

static int check_manifest(const char *dir, int *nfiles, int *nbad)
{
	char mp[1100], *line = NULL;
	size_t lcap = 0;
	ssize_t got;
	struct mrow *rows = NULL;
	int nrows = 0, cap = 0, i, j;
	FILE *m;
	*nfiles = *nbad = 0;
	if (path_join(mp, sizeof(mp), dir, "meta/dump-manifest.txt"))
		return -1;
	m = fopen(mp, "r");
	if (!m) {
		fprintf(stderr, "ops dump: FAILED: no %s\n", mp);
		return -1;
	}
	while ((got = getline(&line, &lcap, m)) > 0) {
		struct mrow r;
		memset(&r, 0, sizeof(r));
		if (sscanf(line, "%15s %39s %llu %47s", r.tag, r.name, &r.bytes, r.file) < 2)
			continue;
		if (nrows >= cap) {
			struct mrow *g;
			cap = cap ? cap * 2 : 64;
			g = realloc(rows, (size_t)cap * sizeof(*rows));
			if (!g) {
				free(rows);
				free(line);
				fclose(m);
				return -1;
			}
			rows = g;
		}
		rows[nrows++] = r;
	}
	free(line);
	fclose(m);
	fprintf(stderr, "Verifying (size == expected, then sha256 -> %s/meta/SHA256SUMS)\n", dir);
	for (i = 0; i < nrows; i++) {
		struct mrow *r = &rows[i];
		int ok = 0, unver = 0;
		char path[1200], hex[65];
		uint64_t have = 0;
		struct stat st;
		if (!strcmp(r->tag, "missing")) {
			(*nbad)++;
			fprintf(stderr, "FAIL %s: not in the live table\n", r->name);
			ev_file(r->name, "", 0, "missing", NULL);
			continue;
		}
		if (strcmp(r->tag, "start"))
			continue;
		(*nfiles)++;
		/* The outcome is the first ok/unverified/fail after this start. */
		for (j = i + 1; j < nrows; j++) {
			if (strcmp(rows[j].name, r->name))
				continue;
			if (!strcmp(rows[j].tag, "start"))
				break;
			ok = !strcmp(rows[j].tag, "ok");
			unver = !strcmp(rows[j].tag, "unverified");
			break;
		}
		if (path_join(path, sizeof(path), dir, r->file)) {
			(*nbad)++;
			continue;
		}
		if (unver) {
			char uv[1300];
			snprintf(uv, sizeof(uv), "%s.unverified", path);
			(*nbad)++;
			fprintf(stderr, "UNVERIFIED %s: read at a guessed table unit; the device would not size it.\n"
				"     kept as %s.unverified; NOT recorded in SHA256SUMS; may be truncated.\n",
				r->name, r->file);
			sums_set(dir, r->file, NULL);
			ev_file(r->name, r->file, stat(uv, &st) == 0 ? (uint64_t)st.st_size : 0, "unverified", NULL);
			continue;
		}
		if (ok && stat(path, &st) == 0 && S_ISREG(st.st_mode) && (uint64_t)st.st_size == r->bytes &&
			hash_file(path, hex, &have) == 0 && have == r->bytes && sums_set(dir, r->file, hex) == 0) {
			fprintf(stderr, "ok   %s %llu sha256 %s\n", r->file, (unsigned long long)have, hex);
			ev_file(r->name, r->file, have, "ok", hex);
			continue;
		}
		(*nbad)++;
		if (!ok)
			fprintf(stderr, "FAIL %s: read did not complete (expected %llu bytes)%s\n", r->name, r->bytes,
				stat(path, &st) == 0 ? "; the file there is an OLDER copy, not from this session" : "");
		else
			fprintf(stderr, "FAIL %s: %s is not %llu bytes or could not be hashed\n", r->name, r->file, r->bytes);
		ev_file(r->name, r->file, r->bytes, "failed", NULL);
	}
	free(rows);
	return 0;
}

static void remove_stale(const char *dir, const char *rel)
{
	char p[1100];
	if (!path_join(p, sizeof(p), dir, rel))
		unlink(p);
}

int spd_ops_dump(struct spd *io, const struct spd_ops_dump_args *a, int yes)
{
	const char *t[SPD_OPS_MAX_PRESETS > IMEI_N ? SPD_OPS_MAX_PRESETS : IMEI_N];
	char meta[1100], raw[1100], mp[1100];
	uint64_t need = 0, avail = 0, headroom = (uint64_t)a->headroom_mib << 20;
	int nt, k, slot, files = 0, nmiss = 0, have_avail = 0, nfail = 0, nfiles = 0, nbad = 0;
	struct stat st;
	struct statvfs vf;
	FILE *m;

	if (mkdir(a->dir, 0755) != 0 && errno != EEXIST) {
		fprintf(stderr, "ops dump: mkdir %s: %s\n", a->dir, strerror(errno));
		return 1;
	}
	if (stat(a->dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
		fprintf(stderr, "ops dump: %s is not a folder\n", a->dir);
		return 1;
	}
	if (path_join(meta, sizeof(meta), a->dir, "meta") || path_join(raw, sizeof(raw), meta, "partition_list.txt") ||
		path_join(mp, sizeof(mp), meta, "dump-manifest.txt")) {
		fprintf(stderr, "ops dump: path too long\n");
		return 1;
	}
	if (mkdir(meta, 0755) != 0 && errno != EEXIST) {
		fprintf(stderr, "ops dump: mkdir %s: %s\n", meta, strerror(errno));
		return 1;
	}
	/* This session's own side files only; images are never removed here
	 * (a failed read leaves NAME.img.partial and the older NAME.img stays). */
	remove_stale(a->dir, "meta/dump-manifest.txt");
	remove_stale(a->dir, "dump-manifest.txt");
	remove_stale(a->dir, "meta/misc-slotinfo.img");
	remove_stale(a->dir, "misc-slotinfo.img");

	/* 1. the live table, saved where menu.sh and `plan` read it. (Its XML and
	 * sprdpart.bin follow --part-xml / SPDHOST_PART_XML_DIR, as for `parts`:
	 * the table is first read at the FDL2 stage. menu.sh points it at
	 * DIR/meta; the APK passes --part-xml DIR/meta.) */
	if (spd_list_parts(io, raw))
		return 1;
	if (!io->dry)
		spd_state_save_table(io);
	/* 2. the slot, once */
	slot = spd_dump_prepare(io, a->dir);
	if (slot < 0)
		return 1;

	/* 3. plan from the live table: the rows spd_dump will read */
	nt = dump_targets(a, t, (int)(sizeof(t) / sizeof(t[0])));
	for (k = 0; k < nt; k++) {
		uint64_t b;
		int f;
		if (spd_dump_plan(io, t[k], slot, &b, &f)) {
			nmiss++;
			continue;
		}
		need += b;
		files += f;
	}
	if (statvfs(a->dir, &vf) == 0) {
		avail = (uint64_t)vf.f_bavail * (uint64_t)(vf.f_frsize ? vf.f_frsize : vf.f_bsize);
		have_avail = 1;
	}
	fprintf(stderr, "ops dump: plan %d file(s), %llu bytes (+%lu MiB headroom), slot %s, table %s; free %s%llu bytes\n",
		files, (unsigned long long)need, a->headroom_mib, slot == 1 ? "a" : slot == 2 ? "b" : "none",
		spd_ptab_sizes_verified(io) ? "verified" : "UNVERIFIED (device sizes each row)",
		have_avail ? "" : "unknown ", (unsigned long long)avail);
	SPD_EV("preflight", "\"op\":\"dump\",\"files\":%d,\"need\":%llu,\"headroom\":%llu,\"avail\":%lld,"
		"\"slot\":\"%s\",\"table_verified\":%s,\"ok\":%s",
		files, (unsigned long long)need, (unsigned long long)headroom,
		have_avail ? (long long)avail : -1LL, slot == 1 ? "a" : slot == 2 ? "b" : "none",
		spd_ptab_sizes_verified(io) ? "true" : "false",
		!have_avail || avail >= need + headroom ? "true" : "false");
	if (have_avail && avail < need + headroom) {
		fprintf(stderr, "ops dump: REFUSED: not enough free space in %s\n"
			"  need about %llu bytes (%llu planned + %lu MiB headroom), have %llu free. Nothing was read.\n",
			a->dir, (unsigned long long)(need + headroom), (unsigned long long)need,
			a->headroom_mib, (unsigned long long)avail);
		m = fopen(mp, "w");
		if (m) {
			fprintf(m, "slot %s\nplan %d %llu\nrefused space %llu %llu\n",
				slot == 1 ? "a" : slot == 2 ? "b" : "none", files, (unsigned long long)need,
				(unsigned long long)(need + headroom), (unsigned long long)avail);
			fclose(m);
		}
		spd_dump_unprepare();
		SPD_EV("op", "\"op\":\"dump\",\"state\":\"refused\",\"why\":\"space\"");
		return 1;
	}
	if (!have_avail)
		fprintf(stderr, "note: could not read free space for %s (%s); continuing without a preflight.\n",
			a->dir, strerror(errno));

	/* 4. the dumps: one spd_dump per target, all appending to one manifest */
	for (k = 0; k < nt; k++) {
		if (spd_interrupted)
			break;
		if (spd_dump(io, t[k], a->dir, yes))
			nfail++;
	}
	spd_dump_unprepare();
	m = fopen(mp, "a");
	if (m) {
		fprintf(m, "plan %d %llu\n", files, (unsigned long long)need);
		fclose(m);
	}

	/* 5. size + sha256 of every file, into meta/SHA256SUMS */
	if (check_manifest(a->dir, &nfiles, &nbad))
		nbad++;
	if (spd_interrupted && k < nt) {
		fprintf(stderr, "ops dump: interrupted before %s\n", t[k]);
		nbad++;
	}
	if (nbad || nfail) {
		fprintf(stderr, "ops dump: FAILED (%d of %d)\n", nbad ? nbad : nfail, nfiles + nmiss);
		SPD_EV("op", "\"op\":\"dump\",\"state\":\"failed\",\"files\":%d,\"failed\":%d", nfiles, nbad ? nbad : nfail);
		return 1;
	}
	fprintf(stderr, "ops dump: all %d file(s) complete\n", nfiles);
	SPD_EV("op", "\"op\":\"dump\",\"state\":\"ok\",\"files\":%d,\"failed\":0", nfiles);
	return 0;
}

/* ---- images list ---- */
struct img {
	char file[256], name[OPS_NAME_MAX];
	uint64_t bytes;
	char sha[65], got[65];
	int verified; /* -1 not checked, 0 mismatch / no line, 1 match */
};

static int img_cmp(const void *x, const void *y)
{
	return strcmp(((const struct img *)x)->file, ((const struct img *)y)->file);
}

/* Look KEY up in SUMS (path), hex into OUT. 1 found. */
static int sums_lookup(const char *sums, const char *key, char out[65])
{
	char *line = NULL;
	size_t lcap = 0;
	ssize_t got;
	int found = 0;
	FILE *f = fopen(sums, "r");
	if (!f)
		return 0;
	while ((got = getline(&line, &lcap, f)) > 0) {
		const char *k;
		if (line[got - 1] == '\n')
			line[--got] = 0;
		k = sums_key(line);
		if (k && !strcmp(k, key) && k - line == 66) {
			memcpy(out, line, 64);
			out[64] = 0;
			found = 1; /* last line wins, like a re-dump appends */
		}
	}
	free(line);
	fclose(f);
	return found;
}

int spd_images_main(int argc, char **argv)
{
	const char *dir = NULL, *layout;
	int json = 0, verify = 0, i, n = 0, cap = 0;
	char sums[1100], legacy[1100], metad[1100];
	struct img *v = NULL;
	struct stat st;
	DIR *dp;
	struct dirent *de;
	if (argc < 2 || strcmp(argv[1], "list")) {
		fprintf(stderr, "images list DIR [--json] [--verify]\n");
		return 2;
	}
	for (i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--json"))
			json = 1;
		else if (!strcmp(argv[i], "--verify"))
			verify = 1;
		else if (argv[i][0] == '-' || dir) {
			fprintf(stderr, "images list DIR [--json] [--verify]\n");
			return 2;
		} else
			dir = argv[i];
	}
	if (!dir) {
		fprintf(stderr, "images list DIR [--json] [--verify]\n");
		return 2;
	}
	if (path_join(sums, sizeof(sums), dir, "meta/SHA256SUMS") ||
		path_join(legacy, sizeof(legacy), dir, "SHA256SUMS") || path_join(metad, sizeof(metad), dir, "meta")) {
		fprintf(stderr, "images list: path too long\n");
		return 1;
	}
	/* A5: meta/ is the layout; an old flat dump keeps SHA256SUMS at the root. */
	if (stat(metad, &st) == 0 && S_ISDIR(st.st_mode))
		layout = "meta";
	else if (stat(legacy, &st) == 0)
		layout = "flat";
	else
		layout = "none";
	if (stat(sums, &st) != 0)
		snprintf(sums, sizeof(sums), "%s", legacy);
	dp = opendir(dir);
	if (!dp) {
		fprintf(stderr, "images list: cannot read %s: %s\n", dir, strerror(errno));
		return 1;
	}
	while ((de = readdir(dp)) != NULL) {
		char path[1400];
		const char *dot;
		size_t nl;
		/* Root only (meta/ and every other folder is skipped by S_ISREG), and
		 * exactly the files write-parts would pick: the shared junk rule. */
		if (!spd_write_candidate(de->d_name) || strlen(de->d_name) >= sizeof(v->file))
			continue;
		if (path_join(path, sizeof(path), dir, de->d_name) || stat(path, &st) || !S_ISREG(st.st_mode))
			continue;
		if (n >= cap) {
			struct img *g;
			cap = cap ? cap * 2 : 32;
			g = realloc(v, (size_t)cap * sizeof(*v));
			if (!g) {
				closedir(dp);
				free(v);
				return 1;
			}
			v = g;
		}
		memset(&v[n], 0, sizeof(v[n]));
		snprintf(v[n].file, sizeof(v[n].file), "%s", de->d_name);
		dot = strrchr(de->d_name, '.');
		nl = dot ? (size_t)(dot - de->d_name) : strlen(de->d_name);
		if (nl >= OPS_NAME_MAX)
			continue;
		memcpy(v[n].name, de->d_name, nl);
		v[n].name[nl] = 0;
		v[n].bytes = (uint64_t)st.st_size;
		v[n].verified = -1;
		if (!sums_lookup(sums, v[n].file, v[n].sha))
			v[n].sha[0] = 0;
		if (verify) {
			uint64_t b;
			v[n].verified = v[n].sha[0] && hash_file(path, v[n].got, &b) == 0 &&
				b == v[n].bytes && !strcmp(v[n].got, v[n].sha);
		}
		n++;
	}
	closedir(dp);
	if (n > 1)
		qsort(v, (size_t)n, sizeof(*v), img_cmp);
	if (json) {
		char q[2200];
		printf("{\"v\":1,\"dir\":%s,\"layout\":\"%s\",\"images\":[", spd_ev_q(dir, q, sizeof(q)), layout);
		for (i = 0; i < n; i++) {
			size_t nl = strlen(v[i].name);
			const char *slot = nl > 2 && v[i].name[nl - 2] == '_' &&
				(v[i].name[nl - 1] == 'a' || v[i].name[nl - 1] == 'b') ? v[i].name + nl - 1 : NULL;
			printf("%s{\"name\":%s", i ? "," : "", spd_ev_q(v[i].name, q, sizeof(q)));
			printf(",\"file\":%s,\"bytes\":%llu", spd_ev_q(v[i].file, q, sizeof(q)),
				(unsigned long long)v[i].bytes);
			printf(",\"slot\":%s%s%s", slot ? "\"" : "", slot ? slot : "null", slot ? "\"" : "");
			if (v[i].sha[0])
				printf(",\"sha256\":\"%s\"", v[i].sha);
			else
				printf(",\"sha256\":null");
			if (v[i].verified >= 0)
				printf(",\"verified\":%s", v[i].verified ? "true" : "false");
			printf("}");
		}
		printf("]}\n");
	} else {
		for (i = 0; i < n; i++) {
			printf("%s\t%s\t%llu\t%s", v[i].name, v[i].file, (unsigned long long)v[i].bytes,
				v[i].sha[0] ? v[i].sha : "-");
			if (v[i].verified >= 0)
				printf("\t%s", v[i].verified ? "verified" : "MISMATCH");
			printf("\n");
		}
	}
	free(v);
	return fflush(stdout) == 0 && !ferror(stdout) ? 0 : 1;
}

/* ---- P0-8: misc ops (argument side; the session side is in main.c) ---- */

int spd_ops_is_misc(int argc, char **argv, int i)
{
	return i + 1 < argc && (!strcmp(argv[i + 1], "misc-reboot") || !strcmp(argv[i + 1], "set-active"));
}

static int hex64(const char *s)
{
	return strlen(s) == 64 && strspn(s, "0123456789abcdef") == 64;
}

int spd_ops_misc_args(int argc, char **argv, int i, struct spd_ops_misc_args *a)
{
	const char *op;
	memset(a, 0, sizeof(*a));
	a->bcb = -1;
	a->dir_at = a->expect_at = -1;
	if (!spd_ops_is_misc(argc, argv, i)) {
		fprintf(stderr, "ops: not a misc op\n");
		return -1;
	}
	op = argv[i + 1];
	a->set_active = !strcmp(op, "set-active");
	if (i + 2 >= argc) {
		fprintf(stderr, "ops %s: missing %s\n", op, a->set_active ? "a|b" : "recovery|fastboot");
		return -1;
	}
	if (a->set_active) {
		if ((argv[i + 2][0] != 'a' && argv[i + 2][0] != 'b') || argv[i + 2][1]) {
			fprintf(stderr, "ops set-active: want a or b, not '%s'\n", argv[i + 2]);
			return -1;
		}
		a->which = argv[i + 2][0];
	} else {
		if (strcmp(argv[i + 2], "recovery") && strcmp(argv[i + 2], "fastboot")) {
			fprintf(stderr, "ops misc-reboot: want recovery or fastboot, not '%s'\n", argv[i + 2]);
			return -1;
		}
		a->bcb = !strcmp(argv[i + 2], "fastboot");
	}
	if (i + 3 >= argc || !argv[i + 3][0] || argv[i + 3][0] == '-') {
		fprintf(stderr, "ops %s: missing DIR (the misc backup goes to DIR/meta/)\n", op);
		return -1;
	}
	a->dir = argv[i + 3];
	a->dir_at = i + 3;
	i += 4;
	while (i < argc && !strncmp(argv[i], "--", 2)) {
		if (!strcmp(argv[i], "--expect")) {
			if (i + 1 >= argc || !hex64(argv[i + 1])) {
				fprintf(stderr, "ops %s: --expect wants a 64-digit lowercase sha256\n", op);
				return -1;
			}
			a->expect = argv[i + 1];
			a->expect_at = i + 1;
			i += 2;
		} else if (!strcmp(argv[i], "--ending") && a->set_active) {
			if (i + 1 >= argc || (strcmp(argv[i + 1], "reset") && strcmp(argv[i + 1], "power-off"))) {
				fprintf(stderr, "ops set-active: --ending wants reset or power-off\n");
				return -1;
			}
			a->ending = !strcmp(argv[i + 1], "reset") ? 0x05 : 0x17;
			i += 2;
		} else if (!strcmp(argv[i], "--bcb") && a->set_active) {
			if (i + 1 >= argc || (strcmp(argv[i + 1], "recovery") && strcmp(argv[i + 1], "fastboot"))) {
				fprintf(stderr, "ops set-active: --bcb wants recovery or fastboot\n");
				return -1;
			}
			a->bcb = !strcmp(argv[i + 1], "fastboot");
			i += 2;
		} else {
			fprintf(stderr, "ops %s: unknown option %s\n", op, argv[i]);
			return -1;
		}
	}
	if (a->bcb >= 0) {
		/* a BCB is only read on the way up: the ending is a reset */
		if (a->ending == 0x17) {
			fprintf(stderr, "ops %s: a %s BCB needs a reset, not --ending power-off\n", op,
				a->bcb ? "fastboot" : "recovery");
			return -1;
		}
		a->ending = 0x05;
	}
	return i;
}

int spd_ops_backup_path(const char *dir, char *abs, size_t acap, char *rel, size_t rcap)
{
	char meta[1100], ts[32];
	struct stat st;
	time_t now = time(NULL);
	struct tm tmv;
	int k;
	if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
		fprintf(stderr, "ops: mkdir %s: %s\n", dir, strerror(errno));
		return -1;
	}
	if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
		fprintf(stderr, "ops: %s is not a folder\n", dir);
		return -1;
	}
	if (path_join(meta, sizeof(meta), dir, "meta")) {
		fprintf(stderr, "ops: path too long\n");
		return -1;
	}
	if (mkdir(meta, 0755) != 0 && errno != EEXIST) {
		fprintf(stderr, "ops: mkdir %s: %s\n", meta, strerror(errno));
		return -1;
	}
	if (!localtime_r(&now, &tmv) || !strftime(ts, sizeof(ts), "%Y%m%d-%H%M%S", &tmv))
		snprintf(ts, sizeof(ts), "%lld", (long long)now);
	/* Never reuse a name: an older backup is never overwritten. */
	for (k = 0; k < 100; k++) {
		int n = k ? snprintf(rel, rcap, "meta/misc-before-%s-%d.img", ts, k)
			  : snprintf(rel, rcap, "meta/misc-before-%s.img", ts);
		if (n <= 0 || (size_t)n >= rcap || path_join(abs, acap, dir, rel)) {
			fprintf(stderr, "ops: path too long\n");
			return -1;
		}
		if (lstat(abs, &st) != 0 && errno == ENOENT)
			return 0;
	}
	fprintf(stderr, "ops: no free misc-before-%s name in %s\n", ts, meta);
	return -1;
}

int spd_ops_sums_record(const char *dir, const char *rel, char hex[65], uint64_t *bytes)
{
	char path[1200];
	if (path_join(path, sizeof(path), dir, rel) || hash_file(path, hex, bytes))
		return -1;
	return sums_set(dir, rel, hex);
}
