/* Minimal fake libusb for tests/exec-addr-seq.sh.
 *
 * Linked (instead of -lusb-1.0) with the vendored spd_dump.c + common.c built
 * -D__ANDROID__ -DUSE_LIBUSB=1, so spd_dump's real BootROM/FDL1 command logic
 * runs with no hardware. Every OUT bulk transfer is logged as one normalized
 * line in the same format as `spdhost --dry-run` (cmd, addr/len, FNV-1a of the
 * exact framed bytes). Every IN transfer returns what a BootROM would send:
 * VER for CHECK_BAUD, ACK otherwise, CRC16-framed. The process exits(0) right
 * after logging the second CHECK_BAUD (the check_baud_loader after FDL1), which
 * is the end of the sequence under test. */
#include <libusb-1.0/libusb.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t reply[64];
static int reply_len;
static int nbaud;

static unsigned crc16(const uint8_t *s, unsigned len)
{
	unsigned crc = 0;
	while (len--) {
		int i;
		crc ^= (unsigned)(*s++) << 8;
		for (i = 0; i < 8; i++)
			crc = (crc << 1) ^ ((0 - (crc >> 15)) & 0x11021);
	}
	return crc & 0xffff;
}

static uint32_t fnv1a(const uint8_t *p, int n)
{
	uint32_t h = 2166136261u;
	while (n-- > 0) { h ^= *p++; h *= 16777619u; }
	return h;
}

static unsigned be16(const uint8_t *p) { return (unsigned)p[0] << 8 | p[1]; }
static uint32_t be32(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static void make_reply(unsigned type, const char *data)
{
	uint8_t raw[32];
	int n = data ? (int)strlen(data) : 0, i, o = 0;
	unsigned c;
	raw[0] = type >> 8; raw[1] = type & 0xff;
	raw[2] = n >> 8; raw[3] = n & 0xff;
	memcpy(raw + 4, data, n);
	c = crc16(raw, 4 + n);
	raw[4 + n] = c >> 8; raw[5 + n] = c & 0xff;
	reply[o++] = 0x7e;
	for (i = 0; i < 6 + n; i++) {
		if (raw[i] == 0x7e || raw[i] == 0x7d) { reply[o++] = 0x7d; reply[o++] = raw[i] ^ 0x20; }
		else reply[o++] = raw[i];
	}
	reply[o++] = 0x7e;
	reply_len = o;
}

static void log_out(const uint8_t *buf, int len)
{
	static uint8_t raw[0x10000 + 16];
	int i, n = 0, allmark = 1;
	uint32_t h = fnv1a(buf, len);
	unsigned type;
	for (i = 0; i < len; i++) if (buf[i] != 0x7e) allmark = 0;
	if (allmark) {
		printf("DRY CHECK_BAUD nbytes=%d fnv=%08x\n", len, h);
		fflush(stdout);
		if (++nbaud >= 2) exit(0);
		make_reply(0x81, "SPRD3");
		return;
	}
	for (i = 1; i < len - 1; i++) {
		if (buf[i] == 0x7d) raw[n++] = buf[++i] ^ 0x20;
		else raw[n++] = buf[i];
	}
	type = be16(raw);
	switch (type) {
	case 0x00: printf("DRY CONNECT fnv=%08x\n", h); break;
	case 0x01: printf("DRY START addr=0x%08x len=%u fnv=%08x\n", be32(raw + 4), be32(raw + 8), h); break;
	case 0x02: printf("DRY MIDST len=%u fnv=%08x\n", be16(raw + 2), h); break;
	case 0x03: printf("DRY END fnv=%08x\n", h); break;
	case 0x04: printf("DRY EXEC fnv=%08x\n", h); break;
	default: printf("DRY CMD 0x%02x fnv=%08x\n", type, h); fflush(stdout); exit(0);
	}
	fflush(stdout);
	make_reply(0x80, NULL);
}

static struct libusb_endpoint_descriptor eps[2];
static struct libusb_interface_descriptor ifd;
static struct libusb_interface itf;
static struct libusb_config_descriptor cfg;
static int dummy_dev, dummy_handle;

int libusb_init(libusb_context **c) { if (c) *c = NULL; return 0; }
void libusb_exit(libusb_context *c) { (void)c; }
int libusb_set_option(libusb_context *c, enum libusb_option o, ...) { (void)c; (void)o; return 0; }
int libusb_has_capability(uint32_t c) { (void)c; return 1; }
const char *libusb_error_name(int e) { static char b[32]; snprintf(b, sizeof b, "MOCK_ERR_%d", e); return b; }
int libusb_wrap_sys_device(libusb_context *c, intptr_t fd, libusb_device_handle **h)
{ (void)c; (void)fd; *h = (libusb_device_handle *)&dummy_handle; return 0; }
libusb_device *libusb_get_device(libusb_device_handle *h) { (void)h; return (libusb_device *)&dummy_dev; }
libusb_device *libusb_ref_device(libusb_device *d) { return d; }
int libusb_get_device_descriptor(libusb_device *d, struct libusb_device_descriptor *desc)
{ (void)d; memset(desc, 0, sizeof *desc); desc->idVendor = 0x1782; desc->idProduct = 0x4d00; desc->bNumConfigurations = 1; return 0; }
int libusb_get_config_descriptor(libusb_device *d, uint8_t i, struct libusb_config_descriptor **c)
{
	(void)d; (void)i;
	eps[0].bEndpointAddress = 0x81; eps[0].bmAttributes = 2; eps[0].wMaxPacketSize = 512;
	eps[1].bEndpointAddress = 0x01; eps[1].bmAttributes = 2; eps[1].wMaxPacketSize = 512;
	ifd.bNumEndpoints = 2; ifd.endpoint = eps;
	itf.num_altsetting = 1; itf.altsetting = &ifd;
	cfg.bNumInterfaces = 1; cfg.interface = &itf;
	*c = &cfg; return 0;
}
void libusb_free_config_descriptor(struct libusb_config_descriptor *c) { (void)c; }
int libusb_kernel_driver_active(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_detach_kernel_driver(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_claim_interface(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_release_interface(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
void libusb_close(libusb_device_handle *h) { (void)h; }
int libusb_open(libusb_device *d, libusb_device_handle **h) { (void)d; *h = (libusb_device_handle *)&dummy_handle; return 0; }
ssize_t libusb_get_device_list(libusb_context *c, libusb_device ***l) { (void)c; *l = NULL; return 0; }
void libusb_free_device_list(libusb_device **l, int u) { (void)l; (void)u; }
int libusb_hotplug_register_callback(libusb_context *c, int e, int f, int v, int p, int cl,
	libusb_hotplug_callback_fn cb, void *u, libusb_hotplug_callback_handle *hh)
{ (void)c; (void)e; (void)f; (void)v; (void)p; (void)cl; (void)cb; (void)u; (void)hh; return 0; }
void libusb_hotplug_deregister_callback(libusb_context *c, libusb_hotplug_callback_handle h) { (void)c; (void)h; }
int libusb_handle_events(libusb_context *c) { (void)c; return 0; }
int libusb_control_transfer(libusb_device_handle *h, uint8_t rt, uint8_t r, uint16_t v, uint16_t i,
	unsigned char *d, uint16_t l, unsigned int t)
{ (void)h; (void)rt; (void)r; (void)v; (void)i; (void)d; (void)t; return l; }
int libusb_bulk_transfer(libusb_device_handle *h, unsigned char ep, unsigned char *d, int len, int *got, unsigned int t)
{
	(void)h; (void)t;
	if (!(ep & 0x80)) { log_out(d, len); *got = len; return 0; }
	if (!reply_len) { *got = 0; return LIBUSB_ERROR_TIMEOUT; }
	if (len > reply_len) len = reply_len;
	memcpy(d, reply, len); *got = len; reply_len = 0; return 0;
}
