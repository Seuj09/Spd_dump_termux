#ifndef SPD_DHTB_H
#define SPD_DHTB_H

#include <stddef.h>
#include <stdint.h>

/* DHTB ("sprd trusted firmware") helpers.
 *
 * These are the tools the release zip ships as x86-64 binaries (gen_spl-unlock,
 * gen_spl-unlock-legacy, gen_fdl1-dl, chsize), ported to plain C so they run on
 * the phone. The originals come from TomKing062's CVE-2022-38694 unlock repo;
 * the patch offsets and loop bounds below are transcribed from that source, not
 * guessed, so the output stays byte-identical to the release binaries.
 *
 * One deliberate difference: every original writes a "temp" file, removes the
 * INPUT and renames over it, so running `gen_spl-unlock splloader.bin` destroys
 * the user's dump in place. These take an explicit OUT and never touch IN. */

/* Real image size from the DHTB header.
 *
 * Returns 0 and stores the size in *size. `short_image` is set when the header
 * says the image ends before the file does; upstream treats that as "not a full
 * image" and does nothing at all, which the callers here reproduce.
 * Returns -1 (with a message on stderr) when the file is not a DHTB image. */
int spd_dhtb_size(const uint8_t *buf, size_t len, size_t *size, int *short_image);

/* In-memory checks of the header math and of all three patch patterns, both
 * against a matching site and against decoys that must survive. Returns 0 on
 * success, 1 with a message on stderr at the first mismatch. */
int spd_dhtb_selftest(void);

/* IN -> OUT. Each prints the computed size on stdout, like the release tools. */
int spd_gen_spl_unlock(const char *in, const char *out);
int spd_gen_spl_unlock_legacy(const char *in, const char *out);
int spd_gen_fdl1_dl(const char *in, const char *out);
int spd_dhtb_chsize(const char *in, const char *out);

#endif /* SPD_DHTB_H */
