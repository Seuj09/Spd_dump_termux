/* For tests/caps.sh: spdhost linked with -Wl,--wrap on every way into USB.
 * Each entry point (context init, fd wrap, vid:pid open) exits 99 with a
 * TRAP line, so a command that must not touch USB can be shown not to. */
#include <stdio.h>
#include <stdlib.h>

static void trap(const char *what)
{
	fprintf(stderr, "TRAP %s\n", what);
	exit(99);
}

int __wrap_libusb_init(void *c) { (void)c; trap("libusb_init"); return -1; }
int __wrap_libusb_init_context(void *c, const void *o, int n) { (void)c; (void)o; (void)n; trap("libusb_init_context"); return -1; }
int __wrap_libusb_wrap_sys_device(void *c, long fd, void *h) { (void)c; (void)fd; (void)h; trap("libusb_wrap_sys_device"); return -1; }
void *__wrap_libusb_open_device_with_vid_pid(void *c, unsigned v, unsigned p) { (void)c; (void)v; (void)p; trap("libusb_open_device_with_vid_pid"); return NULL; }
