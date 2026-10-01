#ifndef SPDHOST_USB_LIST_H
#define SPDHOST_USB_LIST_H

#define SPD_USB_PATH_CAP 128

/* Append bus paths found in text. Returns the new total, which may be
 * larger than cap (only the first cap entries are stored). */
int spd_usb_collect_bus_paths(const char *text, char paths[][SPD_USB_PATH_CAP],
	int cap, int count);

#endif
