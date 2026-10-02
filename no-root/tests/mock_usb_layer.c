/* Mock libusb + driver for tests/usb-extra.sh.
 *
 * src/usb.c is compiled against this instead of the real library, so the two
 * questions that matter can be asked without a phone: does the tool send the
 * vendor's byte stream on the BootROM path, and does an SPDHOST_* opt-in
 * actually turn the extra traffic back on. Every call the test cares about is
 * appended to $USB_LOG as one line; the driver in main() is the shortest run
 * that reaches all of them (open, clear-halt hook, line-state, one OUT that
 * fills the 512-byte packet and one that does not).
 *
 * Only the symbols src/usb.c references are implemented. Anything missing
 * fails to link, which is the point: this file is the list. */
#include <libusb-1.0/libusb.h>

#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "usb.h"

volatile sig_atomic_t spd_interrupted = 0;

static FILE *lg;

static void rec(const char *fmt, ...)
{
	va_list ap;

	if (!lg) {
		const char *p = getenv("USB_LOG");
		lg = fopen(p && p[0] ? p : "/dev/stderr", "a");
		if (!lg)
			lg = stderr;
	}
	va_start(ap, fmt);
	vfprintf(lg, fmt, ap);
	va_end(ap);
	fputc('\n', lg);
	fflush(lg);
}

/* ---------------------------------------------------------------- descriptors */
static struct libusb_device_descriptor dd = {
	.bLength = sizeof(struct libusb_device_descriptor),
	.bDescriptorType = LIBUSB_DT_DEVICE,
	.bcdUSB = 0x0200,
	.bMaxPacketSize0 = 64,
	.idVendor = 0x1782,
	.idProduct = 0x4d00,
	.bcdDevice = 0x0100,
};
static struct libusb_endpoint_descriptor eps[2];
static struct libusb_interface_descriptor ifd;
static struct libusb_interface itf;
static struct libusb_config_descriptor cd;
static int dummy_dev, dummy_handle;

static int mock_cfg;

static void build_descriptors(void)
{
	memset(eps, 0, sizeof(eps));
	/* 512-byte high-speed bulk pair: the mps the ZLP rule keys off. */
	eps[0].bEndpointAddress = 0x81;
	eps[0].bmAttributes = LIBUSB_TRANSFER_TYPE_BULK;
	eps[0].wMaxPacketSize = 512;
	eps[1].bEndpointAddress = 0x01;
	eps[1].bmAttributes = LIBUSB_TRANSFER_TYPE_BULK;
	eps[1].wMaxPacketSize = 512;
	memset(&ifd, 0, sizeof(ifd));
	ifd.bInterfaceNumber = 0;
	ifd.bNumEndpoints = 2;
	ifd.endpoint = eps;
	memset(&itf, 0, sizeof(itf));
	itf.num_altsetting = 1;
	itf.altsetting = &ifd;
	memset(&cd, 0, sizeof(cd));
	cd.bNumInterfaces = 1;
	cd.interface = &itf;
}

/* --------------------------------------------------------------------- libusb */
int libusb_init(libusb_context **c) { if (c) *c = NULL; return 0; }
void libusb_exit(libusb_context *c) { (void)c; }
int libusb_set_option(libusb_context *c, enum libusb_option o, ...)
{
	(void)c;
	rec("set_option %d", (int)o);
	return 0;
}
int libusb_has_capability(uint32_t c) { (void)c; return 1; }
const char *libusb_error_name(int e)
{
	static char b[32];
	snprintf(b, sizeof b, "MOCK_ERR_%d", e);
	return b;
}
int libusb_wrap_sys_device(libusb_context *c, intptr_t fd, libusb_device_handle **h)
{
	(void)c;
	rec("wrap fd=%ld", (long)fd);
	*h = (libusb_device_handle *)&dummy_handle;
	return 0;
}
libusb_device *libusb_get_device(libusb_device_handle *h) { (void)h; return (libusb_device *)&dummy_dev; }
int libusb_get_device_descriptor(libusb_device *d, struct libusb_device_descriptor *out)
{
	(void)d; *out = dd; return 0;
}
int libusb_get_config_descriptor(libusb_device *d, uint8_t i, struct libusb_config_descriptor **c)
{
	(void)d; (void)i;
	*c = &cd;
	return 0;
}
void libusb_free_config_descriptor(struct libusb_config_descriptor *c) { (void)c; }
int libusb_kernel_driver_active(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_detach_kernel_driver(libusb_device_handle *h, int i)
{
	(void)h; (void)i;
	rec("detach iface=%d", i);
	return 0;
}
int libusb_claim_interface(libusb_device_handle *h, int i)
{
	(void)h;
	rec("claim iface=%d", i);
	return 0;
}
int libusb_release_interface(libusb_device_handle *h, int i)
{
	(void)h;
	rec("release iface=%d", i);
	return 0;
}
void libusb_close(libusb_device_handle *h) { (void)h; }
int libusb_open(libusb_device *d, libusb_device_handle **h)
{
	(void)d; *h = (libusb_device_handle *)&dummy_handle; return 0;
}
libusb_device_handle *libusb_open_device_with_vid_pid(libusb_context *c, uint16_t v, uint16_t p)
{
	(void)c; (void)v; (void)p;
	return (libusb_device_handle *)&dummy_handle;
}
ssize_t libusb_get_device_list(libusb_context *c, libusb_device ***l) { (void)c; *l = NULL; return 0; }
void libusb_free_device_list(libusb_device **l, int u) { (void)l; (void)u; }
int libusb_get_device_speed(libusb_device *d) { (void)d; return LIBUSB_SPEED_HIGH; }
int libusb_get_configuration(libusb_device_handle *h, int *cfg)
{
	(void)h;
	rec("get_config");
	*cfg = mock_cfg;
	return 0;
}
int libusb_set_configuration(libusb_device_handle *h, int cfg)
{
	(void)h;
	rec("set_config %d", cfg);
	return 0;
}
int libusb_clear_halt(libusb_device_handle *h, unsigned char ep)
{
	(void)h;
	rec("clear_halt ep=0x%02x", ep);
	return 0;
}
int libusb_control_transfer(libusb_device_handle *h, uint8_t rt, uint8_t r, uint16_t v,
	uint16_t i, unsigned char *d, uint16_t len, unsigned int t)
{
	(void)h; (void)d; (void)t;
	rec("control rt=0x%02x r=%u wv=0x%x wi=%u len=%u", rt, r, v, i, len);
	return len;
}
int libusb_bulk_transfer(libusb_device_handle *h, unsigned char ep, unsigned char *d, int len,
	int *got, unsigned int t)
{
	(void)h; (void)d; (void)t;
	/* Nonzero mps makes len 0 a ZLP, not a no-op, so it must be logged. */
	rec("bulk ep=0x%02x len=%d", ep, len);
	*got = len;
	return 0;
}

/* ---------------------------------------------------------------------- driver */
int main(void)
{
	struct spd_usb u;
	unsigned char buf[512];
	int fd;

	/* spd_usb_open() checks the descriptor is live before wrapping it. */
	fd = open("/dev/null", O_RDONLY);
	if (fd < 0) {
		perror("open /dev/null");
		return 2;
	}
	build_descriptors();
	if (spd_usb_open(&u, fd, 0x1782, 0x4d00, 1000)) {
		fprintf(stderr, "open failed\n");
		return 1;
	}
	rec("mps in=%d out=%d", u.in_mps, u.out_mps);
	spd_usb_clear_halts(&u);
	spd_usb_line_state(&u);
	memset(buf, 0x7e, sizeof(buf));
	spd_usb_bulk_send(&u, buf, 512);  /* fills the packet: ZLP rule fires here */
	spd_usb_bulk_send(&u, buf, 100);  /* partial packet: it must not */
	return 0;
}
