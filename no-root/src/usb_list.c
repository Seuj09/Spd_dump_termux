#define _POSIX_C_SOURCE 200809L

#include "usb_list.h"

#include <ctype.h>
#include <string.h>

/* Every /dev/bus/usb/BUS/DEV in text, including several on one JSON line.
 * termux-usb -l prints a JSON array; deleting commas glues two paths into
 * one, and a single strstr stops after the first. count includes paths
 * past cap so a caller can still tell "more than one". */
int spd_usb_collect_bus_paths(const char *text, char paths[][SPD_USB_PATH_CAP],
	int cap, int count)
{
	const char *p, *path, *s, *e;
	size_t n;

	if (!text)
		return count;
	p = text;
	while ((path = strstr(p, "/dev/bus/usb/")) != NULL) {
		s = path + 13;
		if (!isdigit((unsigned char)*s)) {
			p = path + 1;
			continue;
		}
		while (isdigit((unsigned char)*s))
			s++;
		if (*s != '/') {
			p = path + 1;
			continue;
		}
		s++;
		if (!isdigit((unsigned char)*s)) {
			p = path + 1;
			continue;
		}
		while (isdigit((unsigned char)*s))
			s++;
		e = s;
		if (count < cap && paths) {
			n = (size_t)(e - path);
			if (n >= SPD_USB_PATH_CAP)
				n = SPD_USB_PATH_CAP - 1;
			memcpy(paths[count], path, n);
			paths[count][n] = 0;
		}
		count++;
		p = e;
	}
	return count;
}
