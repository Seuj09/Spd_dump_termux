#define _POSIX_C_SOURCE 200809L
#include "../src/usb_list.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

static void write_file(const char *path, const char *text)
{
	FILE *f = fopen(path, "w");
	if (!f) {
		perror(path);
		exit(1);
	}
	fputs(text, f);
	fclose(f);
}

int main(void)
{
	char p[8][SPD_USB_PATH_CAP];
	struct spd_usb_dev d[8];
	char chosen[SPD_USB_PATH_CAP];
	char tmpl[] = "/tmp/spd-usblist-XXXXXX";
	char dir[512], hub[512], phone[512];
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

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[\"/dev/bus/usb/001/002\",\"/dev/bus/usb/001/003\"]", d, 8, 0);
	expect("old array is still two paths", n == 2);
	expect("old array has no vendor", !d[0].has_vid && !d[1].has_vid);
	expect("two paths and no vendor are not guessed",
		!spd_usb_choose(d, n, NULL, chosen, sizeof(chosen)));

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[{\"device_name\":\"/dev/bus/usb/001/003\",\"vendor_id\":6018,"
		"\"product_id\":19712},"
		"{\"device_name\":\"/dev/bus/usb/001/004\",\"vendor_id\":1133}]",
		d, 8, 0);
	expect("object listing is two devices", n == 2);
	expect("decimal 6018 is vendor 1782", d[0].has_vid && d[0].vid == 0x1782u);
	expect("product id is kept and is not the vendor",
		d[0].has_pid && d[0].pid == 19712u && d[0].vid == 0x1782u);
	expect("the other object is not 1782", d[1].has_vid && d[1].vid != 0x1782u);
	expect("the single 1782 is chosen",
		spd_usb_choose(d, n, NULL, chosen, sizeof(chosen)) &&
		strcmp(chosen, "/dev/bus/usb/001/003") == 0);

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[{\"device_name\":\"/dev/bus/usb/001/003\",\"vendor_id\":\"0x1782\"},"
		"{\"device_name\":\"/dev/bus/usb/001/004\",\"vendor_id\":\"0x1782\"}]",
		d, 8, 0);
	expect("hex 0x1782 parses", n == 2 && d[0].vid == 0x1782u && d[1].vid == 0x1782u);
	expect("two 1782 are not auto-picked",
		!spd_usb_choose(d, n, NULL, chosen, sizeof(chosen)) && chosen[0] == 0);

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[{\"vendor_id\":6018,\"device_name\":\"/dev/bus/usb/001/003\"},"
		"{\"vendor_id\":1133,\"device_name\":\"/dev/bus/usb/001/004\"}]",
		d, 8, 0);
	expect("vendor before the path is not stolen from the next object",
		n == 2 && !d[0].has_vid && !d[1].has_vid);
	expect("two unknown paths are not guessed",
		!spd_usb_choose(d, n, NULL, chosen, sizeof(chosen)));

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[\"/dev/bus/usb/001/003\",\"/dev/bus/usb/001/003\"]", d, 8, 0);
	expect("duplicate path counts once", n == 1 && strcmp(d[0].path, "/dev/bus/usb/001/003") == 0);
	expect("a lone path with no vendor is chosen",
		spd_usb_choose(d, n, NULL, chosen, sizeof(chosen)) &&
		strcmp(chosen, "/dev/bus/usb/001/003") == 0);

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[{\"device_name\":\"/dev/bus/usb/001/005\",\"vendor_id\":1133}]", d, 8, 0);
	expect("a lone known non-1782 is not chosen",
		n == 1 && d[0].has_vid &&
		!spd_usb_choose(d, n, NULL, chosen, sizeof(chosen)));

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[{\"device_name\":\"/dev/bus/usb/001/003\",\"vendor_id\":6018},"
		"{\"device_name\":\"/dev/bus/usb/001/004\",\"vendor_id\":1133}]",
		d, 8, 0);
	expect("remembered path wins over the 1782",
		spd_usb_choose(d, n, "/dev/bus/usb/001/004", chosen, sizeof(chosen)) &&
		strcmp(chosen, "/dev/bus/usb/001/004") == 0);

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[{\"device_name\":\"/dev/bus/usb/001/003\",\"product_id\":6018,"
		"\"vendor_id\":1133}]",
		d, 8, 0);
	expect("product_id 6018 is not treated as the vendor",
		n == 1 && d[0].has_vid && d[0].vid == 1133u &&
		!spd_usb_choose(d, n, NULL, chosen, sizeof(chosen)));

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[\"/dev/bus/usb/001/002\",\"/dev/bus/usb/001/003\"]", d, 1, 0);
	expect("count past the cap is reported", n == 2 && strcmp(d[0].path, "/dev/bus/usb/001/002") == 0);
	expect("a truncated list is not guessed",
		!spd_usb_choose_bounded(d, 1, n, NULL, chosen, sizeof(chosen)));
	expect("a truncated list still honours the remembered path",
		spd_usb_choose_bounded(d, 1, n, "/dev/bus/usb/001/002", chosen, sizeof(chosen)) &&
		strcmp(chosen, "/dev/bus/usb/001/002") == 0);
	expect("a remembered path past the prefix is not invented",
		!spd_usb_choose_bounded(d, 1, n, "/dev/bus/usb/001/099", chosen, sizeof(chosen)));

	if (!mkdtemp(tmpl)) {
		perror("mkdtemp");
		return 1;
	}
	snprintf(dir, sizeof(dir), "%s", tmpl);
	snprintf(hub, sizeof(hub), "%s/hub", dir);
	snprintf(phone, sizeof(phone), "%s/phone", dir);
	if (mkdir(hub, 0755) || mkdir(phone, 0755)) {
		perror("mkdir");
		return 1;
	}
	{
		char f[640];
		snprintf(f, sizeof(f), "%s/busnum", hub);
		write_file(f, "1\n");
		snprintf(f, sizeof(f), "%s/devnum", hub);
		write_file(f, "2\n");
		snprintf(f, sizeof(f), "%s/idVendor", hub);
		write_file(f, "1d6b\n");
		snprintf(f, sizeof(f), "%s/busnum", phone);
		write_file(f, "1\n");
		snprintf(f, sizeof(f), "%s/devnum", phone);
		write_file(f, "3\n");
		snprintf(f, sizeof(f), "%s/idVendor", phone);
		write_file(f, "1782\n");
	}
	unsetenv("SPD_USB_NO_SYSFS");
	setenv("USB_SYSFS_ROOT", dir, 1);
	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[\"/dev/bus/usb/001/002\",\"/dev/bus/usb/001/003\"]", d, 8, 0);
	spd_usb_fill_sysfs(d, n);
	expect("sysfs idVendor 1782 is hex, not decimal",
		d[1].has_vid && d[1].vid == 0x1782u);
	expect("sysfs hub is not 1782", d[0].has_vid && d[0].vid == 0x1d6bu);
	expect("sysfs picks the phone among a hub",
		spd_usb_choose(d, n, NULL, chosen, sizeof(chosen)) &&
		strcmp(chosen, "/dev/bus/usb/001/003") == 0);

	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(
		"[\"/dev/bus/usb/001/002\",\"/dev/bus/usb/001/003\"]", d, 8, 0);
	setenv("SPD_USB_NO_SYSFS", "1", 1);
	spd_usb_fill_sysfs(d, n);
	expect("SPD_USB_NO_SYSFS leaves vendors empty", !d[0].has_vid && !d[1].has_vid);
	unsetenv("SPD_USB_NO_SYSFS");
	unsetenv("USB_SYSFS_ROOT");

	{
		char cmd[320];
		snprintf(cmd, sizeof(cmd), "rm -rf '%s'", dir);
		if (system(cmd) != 0)
			perror("rm sysfs fixture");
	}

	return fail ? 1 : 0;
}
