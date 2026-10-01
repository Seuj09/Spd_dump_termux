#define _POSIX_C_SOURCE 200809L
#include "../src/usb_list.h"

#include <stdio.h>
#include <string.h>

static int fail;

static void expect(const char *what, int cond)
{
	if (cond) {
		printf("PASS: %s\n", what);
		return;
	}
	printf("FAIL: %s\n", what);
	fail++;
}

int main(void)
{
	char p[8][SPD_USB_PATH_CAP];
	int n;

	memset(p, 0, sizeof(p));
	n = spd_usb_collect_bus_paths(
		"[\"/dev/bus/usb/001/002\",\"/dev/bus/usb/001/003\"]", p, 8, 0);
	expect("one JSON line is two devices", n == 2);
	expect("first path", strcmp(p[0], "/dev/bus/usb/001/002") == 0);
	expect("second path", strcmp(p[1], "/dev/bus/usb/001/003") == 0);

	memset(p, 0, sizeof(p));
	n = spd_usb_collect_bus_paths("[\n  \"/dev/bus/usb/001/004\"\n]\n", p, 8, 0);
	expect("pretty-printed one device", n == 1 && strcmp(p[0], "/dev/bus/usb/001/004") == 0);

	memset(p, 0, sizeof(p));
	n = spd_usb_collect_bus_paths("[]", p, 8, 0);
	expect("empty list", n == 0);

	memset(p, 0, sizeof(p));
	n = spd_usb_collect_bus_paths("/dev/bus/usb/not/a/path /dev/bus/usb/2/9", p, 8, 0);
	expect("skip a non-numeric node", n == 1 && strcmp(p[0], "/dev/bus/usb/2/9") == 0);

	return fail ? 1 : 0;
}
