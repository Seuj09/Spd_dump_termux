#ifndef SPDHOST_OPS_H
#define SPDHOST_OPS_H
#include "proto.h"
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
#endif
