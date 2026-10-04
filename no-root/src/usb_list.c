#define _POSIX_C_SOURCE 200809L

#include "usb_list.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
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

static int parse_id(const char *s, const char *end, unsigned *out)
{
	int hex = 0;
	unsigned v = 0;
	int digits = 0;

	while (s < end && (*s == '"' || *s == ':' || *s == ' ' || *s == '\t' ||
			*s == '\n' || *s == '\r' || *s == '='))
		s++;
	if (s + 1 < end && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		s += 2;
		hex = 1;
	}
	while (s < end && digits < 8) {
		unsigned char c = (unsigned char)*s;
		unsigned d;
		if (c >= '0' && c <= '9')
			d = (unsigned)(c - '0');
		else if (hex && c >= 'a' && c <= 'f')
			d = (unsigned)(c - 'a' + 10);
		else if (hex && c >= 'A' && c <= 'F')
			d = (unsigned)(c - 'A' + 10);
		else
			break;
		v = hex ? (v << 4) | d : v * 10u + d;
		s++;
		digits++;
	}
	if (!digits)
		return 0;
	*out = v;
	return 1;
}

static int find_id(const char *start, const char *end, const char *key, unsigned *out)
{
	size_t klen = strlen(key);
	const char *p;

	if (!start || start >= end)
		return 0;
	for (p = start; p + klen <= end; p++) {
		if (p != start && isalnum((unsigned char)p[-1]))
			continue;
		if (memcmp(p, key, klen) == 0 && parse_id(p + klen, end, out))
			return 1;
	}
	return 0;
}

int spd_usb_collect_devs(const char *text, struct spd_usb_dev *devs, int cap,
	int count)
{
	const char *p, *path, *s;
	size_t nlen;
	int i;

	if (!text)
		return count;
	p = text;
	while ((path = strstr(p, "/dev/bus/usb/")) != NULL) {
		const char *next, *win_end;
		struct spd_usb_dev one;
		int dup_at = -1;

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
		nlen = (size_t)(s - path);
		memset(&one, 0, sizeof(one));
		if (nlen >= SPD_USB_PATH_CAP)
			nlen = SPD_USB_PATH_CAP - 1;
		memcpy(one.path, path, nlen);
		one.path[nlen] = 0;
		for (i = 0; i < count && i < cap; i++) {
			if (devs && strcmp(devs[i].path, one.path) == 0) {
				dup_at = i;
				break;
			}
		}
		next = strstr(s, "/dev/bus/usb/");
		win_end = next ? next : s + strlen(s);
		{
			/* vendor_id after this '}' belongs to the next object.
			 * A vendor printed before the path is left unknown rather
			 * than borrowed from that neighbour. */
			const char *brace = memchr(s, '}', (size_t)(win_end - s));
			if (brace)
				win_end = brace;
		}
		if (find_id(s, win_end, "vendor_id", &one.vid))
			one.has_vid = 1;
		if (find_id(s, win_end, "product_id", &one.pid))
			one.has_pid = 1;
		if (dup_at >= 0) {
			if (devs && !devs[dup_at].has_vid && one.has_vid) {
				devs[dup_at].has_vid = 1;
				devs[dup_at].vid = one.vid;
			}
			if (devs && !devs[dup_at].has_pid && one.has_pid) {
				devs[dup_at].has_pid = 1;
				devs[dup_at].pid = one.pid;
			}
			p = s;
			continue;
		}
		if (count < cap && devs)
			devs[count] = one;
		count++;
		p = s;
	}
	return count;
}

int spd_usb_choose(const struct spd_usb_dev *devs, int n, const char *prefer,
	char *out, size_t cap)
{
	int i, unisoc = -1, nunisoc = 0;

	if (out && cap)
		out[0] = 0;
	if (!devs || n <= 0 || !out || cap == 0)
		return 0;
	if (prefer && prefer[0]) {
		for (i = 0; i < n; i++) {
			if (strcmp(devs[i].path, prefer) == 0) {
				snprintf(out, cap, "%s", prefer);
				return 1;
			}
		}
	}
	for (i = 0; i < n; i++) {
		if (devs[i].has_vid && devs[i].vid == 0x1782u) {
			nunisoc++;
			unisoc = i;
		}
	}
	if (nunisoc == 1) {
		snprintf(out, cap, "%s", devs[unisoc].path);
		return 1;
	}
	if (nunisoc > 1)
		return 0;
	if (n == 1 && !devs[0].has_vid) {
		snprintf(out, cap, "%s", devs[0].path);
		return 1;
	}
	return 0;
}

int spd_usb_choose_bounded(const struct spd_usb_dev *devs, int stored,
	int total, const char *prefer, char *out, size_t cap)
{
	int i;

	if (out && cap)
		out[0] = 0;
	if (total < 0)
		total = 0;
	if (stored < 0)
		stored = 0;
	if (stored > total)
		stored = total;
	/* The second Unisoc may sit past the stored prefix. Guessing from
	 * the prefix would open the wrong node. The path we already used
	 * is still safe. */
	if (total > stored) {
		if (prefer && prefer[0] && devs && out && cap) {
			for (i = 0; i < stored; i++) {
				if (strcmp(devs[i].path, prefer) == 0) {
					snprintf(out, cap, "%s", prefer);
					return 1;
				}
			}
		}
		return 0;
	}
	return spd_usb_choose(devs, stored, prefer, out, cap);
}

static int read_sysfs_line(const char *path, char *buf, size_t cap)
{
	FILE *f;
	size_t n;

	if (!buf || cap == 0)
		return 0;
	f = fopen(path, "r");
	if (!f)
		return 0;
	if (!fgets(buf, (int)cap, f)) {
		fclose(f);
		return 0;
	}
	fclose(f);
	n = strlen(buf);
	while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' ||
			buf[n - 1] == ' ' || buf[n - 1] == '\t'))
		buf[--n] = 0;
	return n > 0;
}

static int parse_u10(const char *s, unsigned *out)
{
	char *end = NULL;
	unsigned long v;

	if (!s || !s[0])
		return 0;
	errno = 0;
	v = strtoul(s, &end, 10);
	if (errno || end == s || *end || v > 0xfffffffful)
		return 0;
	*out = (unsigned)v;
	return 1;
}

static int parse_hex_token(const char *s, unsigned *out)
{
	char tmp[24];
	int nw;

	if (!s || !s[0] || strlen(s) > 8)
		return 0;
	nw = snprintf(tmp, sizeof(tmp), "0x%s", s);
	if (nw < 0 || nw >= (int)sizeof(tmp))
		return 0;
	return parse_id(tmp, tmp + nw, out);
}

static int path_bus_dev(const char *path, unsigned *bus, unsigned *dev)
{
	return sscanf(path, "/dev/bus/usb/%u/%u", bus, dev) == 2;
}

void spd_usb_fill_sysfs(struct spd_usb_dev *devs, int n)
{
	const char *dis, *root;
	DIR *dir;
	struct dirent *de;
	struct { unsigned bus, dev, vid; } rows[64];
	int nrows = 0;
	int i, need = 0;

	if (!devs || n <= 0)
		return;
	dis = getenv("SPD_USB_NO_SYSFS");
	if (dis && dis[0] == '1' && dis[1] == 0)
		return;
	for (i = 0; i < n; i++) {
		if (!devs[i].has_vid)
			need = 1;
	}
	if (!need)
		return;
	root = getenv("USB_SYSFS_ROOT");
	if (!root || !root[0])
		root = "/sys/bus/usb/devices";
	dir = opendir(root);
	if (!dir)
		return;
	while ((de = readdir(dir)) != NULL && nrows < 64) {
		char path[1024];
		char b[32], dv[32], v[32];
		unsigned bus, devn, vid;
		int nw;

		if (de->d_name[0] == '.')
			continue;
		nw = snprintf(path, sizeof(path), "%s/%s/idVendor", root, de->d_name);
		if (nw < 0 || nw >= (int)sizeof(path) || !read_sysfs_line(path, v, sizeof(v)))
			continue;
		nw = snprintf(path, sizeof(path), "%s/%s/busnum", root, de->d_name);
		if (nw < 0 || nw >= (int)sizeof(path) || !read_sysfs_line(path, b, sizeof(b)))
			continue;
		nw = snprintf(path, sizeof(path), "%s/%s/devnum", root, de->d_name);
		if (nw < 0 || nw >= (int)sizeof(path) || !read_sysfs_line(path, dv, sizeof(dv)))
			continue;
		if (!parse_u10(b, &bus) || !parse_u10(dv, &devn) || !parse_hex_token(v, &vid))
			continue;
		rows[nrows].bus = bus;
		rows[nrows].dev = devn;
		rows[nrows].vid = vid;
		nrows++;
	}
	closedir(dir);
	for (i = 0; i < n; i++) {
		unsigned bus, devn;
		int r;

		if (devs[i].has_vid)
			continue;
		if (!path_bus_dev(devs[i].path, &bus, &devn))
			continue;
		for (r = 0; r < nrows; r++) {
			if (rows[r].bus == bus && rows[r].dev == devn) {
				devs[i].vid = rows[r].vid;
				devs[i].has_vid = 1;
				break;
			}
		}
	}
}
