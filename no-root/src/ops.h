#ifndef SPDHOST_OPS_H
#define SPDHOST_OPS_H
#include "proto.h"
#include <stddef.h>
#include <stdint.h>
/* P0-7: C ops that menu.sh and the APK share (one tested implementation).
 *
 * `ops dump DIR --preset P [--preset P ...] [--headroom MIB]` (session
 * command, needs FDL2): reads the live table into DIR/meta/partition_list.txt,
 * reads the active slot once (DIR/meta/misc-slotinfo.img), plans the bytes the
 * dump will read from that live table (the same rows spd_dump picks), refuses
 * before reading anything when statvfs(DIR) has less than plan + headroom free,
 * then dumps each preset into DIR (A5 layout: images at the root, side files in
 * meta/) and checks DIR/meta/dump-manifest.txt: every complete file of the
 * expected size gets its line in DIR/meta/SHA256SUMS (relative to DIR).
 * P: all, all_lite, preset_modem, preset_resign, imei (the release menu's NV
 * set), or a partition name (NAME or NAME without _a/_b: the live slot).
 * all / all_lite / preset_* / imei must be the only preset. */
#define SPD_OPS_MAX_PRESETS 16
struct spd_ops_dump_args {
	const char *dir;
	const char *preset[SPD_OPS_MAX_PRESETS];
	int npreset;
	unsigned long headroom_mib;
};
/* Parse argv[I] == "ops" onward. Returns the index after the command, or -1
 * (message on stderr) for a usage error.  */
int spd_ops_dump_args(int argc, char **argv, int i, struct spd_ops_dump_args *a);
/* Run it. 0 = every file complete and recorded; 1 = refused (space) or any
 * read failed / unverified / missing. */
int spd_ops_dump(struct spd *io, const struct spd_ops_dump_args *a, int yes);

/* `images list DIR [--json] [--verify]` (offline, no USB): the images a
 * restore of DIR would pick (the write-parts candidate rule), with sizes and the
 * sha256 recorded in meta/SHA256SUMS (root SHA256SUMS for an old flat dump).
 * argv[0] is "images". Exit code: 0 ok, 1 cannot read DIR, 2 usage. */
int spd_images_main(int argc, char **argv);

/* P0-8: the guarded misc ops (A4, audit6 C10), session commands after `parts`:
 *   ops misc-reboot recovery|fastboot DIR [--expect SHA256]
 *   ops set-active a|b DIR [--bcb recovery|fastboot] [--ending reset|power-off]
 *                          [--expect SHA256]
 * One session, one misc write: the whole misc is read into
 * DIR/meta/misc-before-<time>.img and read back from disk (else nothing is
 * written), its sha256 goes into DIR/meta/SHA256SUMS, then the BCB and/or the
 * slot block is spliced into that image, the whole misc is written and read
 * back. misc-reboot (and set-active --bcb) then resets; set-active --ending
 * resets or powers off; plain set-active leaves the ending to the caller's
 * argv. --expect: stop before the write
 * unless the misc just read hashes to SHA256. Keep rule: the core never
 * deletes a backup that was read back OK; only a backup file that failed its
 * own read-back (so nothing was written) is removed. */
struct spd_ops_misc_args {
	int set_active;  /* 0 = misc-reboot, 1 = set-active */
	char which;      /* set-active: 'a' or 'b' */
	int bcb;         /* -1 none, 0 recovery, 1 fastboot (misc-reboot: always >= 0) */
	unsigned ending; /* 0 = caller's argv, 0x05 reset, 0x17 power-off */
	const char *dir;
	const char *expect;
	int dir_at, expect_at; /* argv indexes (-1 when absent) */
};
/* argv[I] == "ops": 1 when argv[I+1] is a misc op (misc-reboot / set-active). */
int spd_ops_is_misc(int argc, char **argv, int i);
/* Parse argv[I] == "ops" onward. Returns the index after it, or -1 (message
 * on stderr). */
int spd_ops_misc_args(int argc, char **argv, int i, struct spd_ops_misc_args *a);
/* mkdir DIR and DIR/meta; pick a fresh DIR/meta/misc-before-<time>[-N].img.
 * ABS gets DIR/REL, REL the name relative to DIR. 0 ok, -1 (message). */
int spd_ops_backup_path(const char *dir, char *abs, size_t acap, char *rel, size_t rcap);
/* Hash DIR/REL into DIR/meta/SHA256SUMS (relative name). HEX gets it. */
int spd_ops_sums_record(const char *dir, const char *rel, char hex[65], uint64_t *bytes);
#endif
