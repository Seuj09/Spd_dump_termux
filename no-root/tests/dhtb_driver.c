/* Minimal CLI over src/dhtb.c so tests/dhtb-tools.sh can golden-test the
 * offline image tools without linking the USB client. The real dispatch is the
 * offline-tools block in src/main.c; keep the two in step. */
#include "dhtb.h"

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "usage: %s TOOL IN OUT\n", argv[0]);
		return 2;
	}
	if (!strcmp(argv[1], "gen-spl-unlock"))
		return spd_gen_spl_unlock(argv[2], argv[3]) ? 1 : 0;
	if (!strcmp(argv[1], "gen-spl-unlock-legacy"))
		return spd_gen_spl_unlock_legacy(argv[2], argv[3]) ? 1 : 0;
	if (!strcmp(argv[1], "gen-fdl1-dl"))
		return spd_gen_fdl1_dl(argv[2], argv[3]) ? 1 : 0;
	if (!strcmp(argv[1], "chsize"))
		return spd_dhtb_chsize(argv[2], argv[3]) ? 1 : 0;
	fprintf(stderr, "unknown tool: %s\n", argv[1]);
	return 2;
}
