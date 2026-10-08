/* Mock libusb + driver for tests/usb-fd-close.sh (P0-1, wrapped-fd close).
 *
 * libusb_wrap_sys_device() does not take ownership of the fd it wraps and
 * libusb_close() leaves that fd open, so src/usb.c has to close it itself:
 * after libusb_close() on the handle that wraps it, exactly once. This mock
 * records every wrap, every libusb_close() and (through -Wl,--wrap=close)
 * every close() src/usb.c makes, and the driver below runs one lifecycle per
 * MOCK_CASE:
 *
 *   close           open by fd, spd_usb_close
 *   reacq           open by fd, reacquire (fake termux-usb hands a new fd), close
 *   reacq_wrapfail  ... the first reacquire wrap fails, the next one succeeds
 *   reacq_adoptfail ... the first reacquired fd wraps but adopt() (claim) fails
 *   scan            open by vid:pid (libusb owns that fd), reacquire, close
 *
 * fd numbers are reused by the kernel, so each wrapped fd is identified by
 * the inode of the file behind it (every descriptor the test hands over is a
 * separate temp file). A close() is matched to a record by fstat() just
 * before the real close, so a double close of a number that now belongs to a
 * newer descriptor is caught as closing a live one, not missed.
 *
 * Output (stdout, one line each): `ev ...` events in order, then one `rec`
 * line per wrapped fd and a `viol` line per broken rule. */
#include <libusb-1.0/libusb.h>

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "usb.h"

volatile sig_atomic_t spd_interrupted = 0;

static void out(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	fflush(stdout);
}

/* ------------------------------------------------------------- fd records */
#define MAXREC 32
struct rec {
	int fd;
	ino_t ino;
	dev_t dev;
	int wrapped;        /* wrap succeeded: a handle exists on it */
	int handle_live;    /* that handle has not been libusb_close()d */
	int libusb_closes;
	int fd_closes;
	int closed_under_live; /* close() while handle_live */
	int seq_libusb_close, seq_fd_close;
};
static struct rec recs[MAXREC];
static int nrec, seq, nviol;
static int handles[MAXREC]; /* handle k is &handles[k], k = record index */
static int scan_handles[8], nscan;

int __real_close(int fd);

static int rec_by_fd_identity(int fd)
{
	struct stat st;
	int k;
	if (fstat(fd, &st) < 0)
		return -2; /* not open */
	for (k = nrec - 1; k >= 0; k--)
		if (recs[k].ino == st.st_ino && recs[k].dev == st.st_dev)
			return k;
	return -1;
}

static void viol(const char *fmt, ...)
{
	va_list ap;
	printf("viol ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	fflush(stdout);
	nviol++;
}

int __wrap_close(int fd)
{
	int k = rec_by_fd_identity(fd);
	if (k == -2) {
		/* EBADF: a second close of a number nothing else reuses yet. */
		viol("close of a closed fd %d", fd);
	} else if (k >= 0) {
		struct rec *r = &recs[k];
		seq++;
		if (fcntl(fd, F_GETFD) == -1)
			viol("rec %d: fd %d not open at close", k, fd);
		if (r->handle_live) {
			r->closed_under_live = 1;
			viol("rec %d: fd %d closed while its libusb handle is live", k, fd);
		}
		if (r->fd_closes)
			viol("rec %d: fd closed twice", k);
		r->fd_closes++;
		r->seq_fd_close = seq;
		out("ev close rec=%d", k);
	}
	return __real_close(fd);
}

/* ------------------------------------------------------------ descriptors */
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
static int dummy_dev;
static libusb_device *dev_list[2] = { (libusb_device *)&dummy_dev, NULL };

static void build_descriptors(void)
{
	eps[0].bEndpointAddress = 0x81;
	eps[0].bmAttributes = LIBUSB_TRANSFER_TYPE_BULK;
	eps[0].wMaxPacketSize = 512;
	eps[1].bEndpointAddress = 0x01;
	eps[1].bmAttributes = LIBUSB_TRANSFER_TYPE_BULK;
	eps[1].wMaxPacketSize = 512;
	ifd.bNumEndpoints = 2;
	ifd.endpoint = eps;
	itf.num_altsetting = 1;
	itf.altsetting = &ifd;
	cd.bNumInterfaces = 1;
	cd.interface = &itf;
}

/* MOCK_WRAP_FAIL=N / MOCK_CLAIM_FAIL=N: the Nth call (1-based) fails. */
static int nth_fails(const char *var, int n)
{
	const char *e = getenv(var);
	return e && atoi(e) == n;
}

/* ----------------------------------------------------------------- libusb */
/* A non-NULL context, so spd_usb_close() reaches libusb_exit() and the
 * test can see the fd is closed before it. */
static int dummy_ctx;
int libusb_init(libusb_context **c) { if (c) *c = (libusb_context *)&dummy_ctx; return 0; }
#if defined(LIBUSB_API_VERSION) && LIBUSB_API_VERSION >= 0x0100010A
int libusb_init_context(libusb_context **c, const struct libusb_init_option *o, int n)
{
	(void)o; (void)n;
	if (c)
		*c = (libusb_context *)&dummy_ctx;
	return 0;
}
#endif
void libusb_exit(libusb_context *c) { (void)c; seq++; out("ev libusb_exit"); }
int libusb_set_option(libusb_context *c, enum libusb_option o, ...) { (void)c; (void)o; return 0; }
int libusb_has_capability(uint32_t c) { (void)c; return 1; }
const char *libusb_error_name(int e)
{
	static char b[32];
	snprintf(b, sizeof b, "MOCK_ERR_%d", e);
	return b;
}
int libusb_wrap_sys_device(libusb_context *c, intptr_t fd, libusb_device_handle **h)
{
	static int nwrap;
	struct stat st;
	struct rec *r;
	(void)c;
	nwrap++;
	if (nrec >= MAXREC || fstat((int)fd, &st) < 0) {
		viol("wrap of a bad fd %ld", (long)fd);
		return LIBUSB_ERROR_INVALID_PARAM;
	}
	r = &recs[nrec];
	memset(r, 0, sizeof(*r));
	r->fd = (int)fd;
	r->ino = st.st_ino;
	r->dev = st.st_dev;
	if (nth_fails("MOCK_WRAP_FAIL", nwrap)) {
		out("ev wrap rec=%d fd=%d FAIL", nrec, r->fd);
		nrec++;
		return LIBUSB_ERROR_IO;
	}
	r->wrapped = r->handle_live = 1;
	*h = (libusb_device_handle *)&handles[nrec];
	out("ev wrap rec=%d fd=%d", nrec, r->fd);
	nrec++;
	return 0;
}
void libusb_close(libusb_device_handle *h)
{
	int k;
	seq++;
	for (k = 0; k < nrec; k++) {
		if (h == (libusb_device_handle *)&handles[k]) {
			if (!recs[k].handle_live)
				viol("rec %d: libusb_close twice", k);
			recs[k].handle_live = 0;
			recs[k].libusb_closes++;
			recs[k].seq_libusb_close = seq;
			out("ev libusb_close rec=%d", k);
			return;
		}
	}
	for (k = 0; k < nscan; k++)
		if (h == (libusb_device_handle *)&scan_handles[k]) {
			out("ev libusb_close scan=%d", k);
			return;
		}
	viol("libusb_close of an unknown handle");
}
static libusb_device_handle *new_scan_handle(void)
{
	if (nscan >= 8)
		return NULL;
	out("ev open scan=%d", nscan);
	return (libusb_device_handle *)&scan_handles[nscan++];
}
int libusb_open(libusb_device *d, libusb_device_handle **h)
{
	(void)d;
	*h = new_scan_handle();
	return *h ? 0 : LIBUSB_ERROR_NO_MEM;
}
libusb_device_handle *libusb_open_device_with_vid_pid(libusb_context *c, uint16_t v, uint16_t p)
{
	(void)c; (void)v; (void)p;
	return new_scan_handle();
}
libusb_device *libusb_get_device(libusb_device_handle *h) { (void)h; return (libusb_device *)&dummy_dev; }
int libusb_get_device_descriptor(libusb_device *d, struct libusb_device_descriptor *o) { (void)d; *o = dd; return 0; }
int libusb_get_config_descriptor(libusb_device *d, uint8_t i, struct libusb_config_descriptor **c)
{
	(void)d; (void)i;
	*c = &cd;
	return 0;
}
void libusb_free_config_descriptor(struct libusb_config_descriptor *c) { (void)c; }
int libusb_kernel_driver_active(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_detach_kernel_driver(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int libusb_claim_interface(libusb_device_handle *h, int i)
{
	static int nclaim;
	(void)h; (void)i;
	nclaim++;
	if (nth_fails("MOCK_CLAIM_FAIL", nclaim)) {
		out("ev claim FAIL");
		return LIBUSB_ERROR_BUSY;
	}
	return 0;
}
int libusb_release_interface(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
ssize_t libusb_get_device_list(libusb_context *c, libusb_device ***l) { (void)c; *l = dev_list; return 1; }
void libusb_free_device_list(libusb_device **l, int u) { (void)l; (void)u; }
int libusb_get_device_speed(libusb_device *d) { (void)d; return LIBUSB_SPEED_HIGH; }
int libusb_get_configuration(libusb_device_handle *h, int *cfg) { (void)h; *cfg = 1; return 0; }
int libusb_set_configuration(libusb_device_handle *h, int cfg) { (void)h; (void)cfg; return 0; }
int libusb_clear_halt(libusb_device_handle *h, unsigned char ep) { (void)h; (void)ep; return 0; }
int libusb_control_transfer(libusb_device_handle *h, uint8_t rt, uint8_t r, uint16_t v,
	uint16_t i, unsigned char *d, uint16_t len, unsigned int t)
{
	(void)h; (void)rt; (void)r; (void)v; (void)i; (void)d; (void)t;
	return len;
}
int libusb_bulk_transfer(libusb_device_handle *h, unsigned char ep, unsigned char *d, int len,
	int *got, unsigned int t)
{
	(void)h; (void)ep; (void)d; (void)t;
	*got = len;
	return 0;
}

/* ----------------------------------------------------------------- driver */
/* Is the fd behind record k still open in this process (same file)? */
static int rec_open(int k)
{
	struct stat st;
	return fcntl(recs[k].fd, F_GETFD) != -1 && fstat(recs[k].fd, &st) == 0
		&& st.st_ino == recs[k].ino && st.st_dev == recs[k].dev;
}

int main(int argc, char **argv)
{
	struct spd_usb u;
	const char *mode = getenv("MOCK_CASE");
	const char *sock = getenv("SPDHOST_EMIT_SOCK");
	int k, rc, scan;

	/* Re-exec'd by the fake termux-usb during reacquire: hand the fd back,
	 * as spdhost's own SPDHOST_EMIT_SOCK path does. */
	if (sock && sock[0])
		return spd_usb_emit_fd(sock, argc > 1 ? argv[1] : NULL) ? 1 : 0;
	if (!mode) {
		fprintf(stderr, "set MOCK_CASE\n");
		return 2;
	}
	build_descriptors();
	scan = !strcmp(mode, "scan");
	if (scan) {
		spd_usb_open(&u, -1, 0x1782, 0x4d00, 1000);
	} else {
		const char *p = getenv("MOCK_FD0");
		int fd = p ? open(p, O_RDWR) : -1;
		if (fd < 0) {
			perror("MOCK_FD0");
			return 2;
		}
		spd_usb_open(&u, fd, 0x1782, 0x4d00, 1000);
		out("ev opened wrapped_fd=%s", u.wrapped_fd == fd ? "fd" : "WRONG");
	}
	if (strcmp(mode, "close")) {
		char self[512];
		ssize_t n = readlink("/proc/self/exe", self, sizeof(self) - 1);
		if (n < 0)
			return 2;
		self[n] = 0;
		spd_usb_enable_reacquire(&u, self);
		rc = spd_usb_reacquire(&u);
		out("ev reacquire rc=%d", rc);
		/* The new descriptor (if any) is the last wrapped record. */
		for (k = 0; k < nrec; k++)
			out("mid rec=%d open=%d current=%d", k, rec_open(k),
				recs[k].wrapped && u.wrapped_fd == recs[k].fd && rec_open(k)
				&& recs[k].handle_live);
	}
	out("ev wrapped_fd_before_close=%d", u.wrapped_fd >= 0);
	spd_usb_close(&u);
	out("ev closed wrapped_fd=%d", u.wrapped_fd);
	for (k = 0; k < nrec; k++) {
		struct rec *r = &recs[k];
		int order = r->wrapped ? (r->seq_libusb_close && r->seq_libusb_close < r->seq_fd_close)
				       : (r->libusb_closes == 0);
		out("rec %d wrapped=%d libusb_closes=%d fd_closes=%d order_ok=%d open=%d",
			k, r->wrapped, r->libusb_closes, r->fd_closes, order, rec_open(k));
	}
	out("summary recs=%d scan_handles=%d viol=%d", nrec, nscan, nviol);
	return 0;
}
