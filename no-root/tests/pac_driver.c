/* Minimal CLI over src/pac.c so tests/pac-tools.sh can golden-test the PAC
 * reader without linking the USB client.
 *
 * spd_pac_main() ignores argv[0] and takes the mode at argv[1], which is what
 * `spdhost unpac list fw.pac` gives it. So pass argv through unchanged:
 * `pac_driver list fw.pac` is exactly `spdhost unpac list fw.pac`, and
 * `pac_driver -d out extract fw.pac` is the -d form. */
#include "pac.h"

int main(int argc, char **argv)
{
	return spd_pac_main(argc, argv);
}
