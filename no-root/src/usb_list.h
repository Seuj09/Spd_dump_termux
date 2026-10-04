#ifndef SPDHOST_USB_LIST_H
#define SPDHOST_USB_LIST_H

#include <stddef.h>

#define SPD_USB_PATH_CAP 128

/* Append bus paths found in text. Returns the new total, which may be
 * larger than cap (only the first cap entries are stored). */
int spd_usb_collect_bus_paths(const char *text, char paths[][SPD_USB_PATH_CAP],
	int cap, int count);

/* One node from a termux-usb -l listing. vid/pid are set only when the
 * text names them next to the path (newer listings). A string array of
 * paths leaves has_vid at 0. Duplicate paths are stored once. */
struct spd_usb_dev {
	char path[SPD_USB_PATH_CAP];
	unsigned vid;
	unsigned pid;
	int has_vid;
	int has_pid;
};

int spd_usb_collect_devs(const char *text, struct spd_usb_dev *devs, int cap,
	int count);

/* Pick one device. prefer wins when that path is still listed.
 * Otherwise the single vendor 1782 wins over other nodes.
 * A lone path with no vendor is chosen. A lone known non-1782 is not.
 * Returns 1 and writes out when one path is chosen, else 0. */
int spd_usb_choose(const struct spd_usb_dev *devs, int n, const char *prefer,
	char *out, size_t cap);

/* stored is how many entries devs holds. total may be larger when the
 * listing did not fit. A truncated list is not guessed: only an exact
 * prefer match is returned. Otherwise this is spd_usb_choose. */
int spd_usb_choose_bounded(const struct spd_usb_dev *devs, int stored,
	int total, const char *prefer, char *out, size_t cap);

/* When the listing named no vendor_id, fill it from sysfs
 * busnum/devnum/idVendor. SPD_USB_NO_SYSFS=1 skips. USB_SYSFS_ROOT
 * overrides /sys/bus/usb/devices. Unreadable sysfs leaves devs unchanged. */
void spd_usb_fill_sysfs(struct spd_usb_dev *devs, int n);

#endif
