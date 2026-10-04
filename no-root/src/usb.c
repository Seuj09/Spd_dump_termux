#define _GNU_SOURCE

#include "usb.h"
#include "usb_list.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <time.h>

#include <libusb-1.0/libusb.h>

static void die_usb(const char *what, int err)
{
	fprintf(stderr, "%s: %s\n", what, libusb_error_name(err));
	exit(1);
}

/* Termux:API keeps the wrapped usbfs FD open across process exit, so an
 * unreleased claim can survive and make the next claim return BUSY. Track the
 * live handle for atexit and for close/reacq. */
static struct spd_usb *g_live_usb;

static void release_claimed(struct spd_usb *u)
{
	if (!u || !u->handle || u->claimed_iface < 0)
		return;
	libusb_release_interface(u->handle, u->claimed_iface);
	u->claimed_iface = -1;
}

static void atexit_release(void)
{
	if (g_live_usb)
		release_claimed(g_live_usb);
}

static long long mono_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

/* A3/B1 soft breadcrumbs: SPDHOST_BROM_TRACE=1 (Allow→hello timing). */
static int brom_trace_on(void)
{
	const char *e = getenv("SPDHOST_BROM_TRACE");
	return e && e[0] && e[0] != '0';
}

/* Kill switch for the three pieces of extra control/bulk traffic below.
 *
 * All three are ON by default. That is deliberate: it is the configuration of
 * spdhost-exp-write-a6cb72d, the build a real phone was detected and flashed
 * with. An earlier change turned them off on the theory that the vendor
 * reference (spd_dump/common.c) never sends them, and every release after that
 * detected the device and then timed out — so the reference is not the last
 * word here, and matching the known-good build is.
 *
 * SPDHOST_NO_CLEAR_HALT=1, SPDHOST_NO_SET_CONFIG=1 and SPDHOST_NO_SEND_ZLP=1
 * each turn one back off for A/B testing on a host that dislikes it. Nothing
 * turns them off by accident: only a var set to a non-empty, non-"0" value
 * counts, exactly as SPDHOST_NO_CLEAR_HALT always has. */
static int extra_off(const char *no_name)
{
	const char *e = getenv(no_name);
	return e && e[0] && e[0] != '0';
}


/* EXPERIMENT (item 3): one-line device summary for BootROM debugging.
 * Only printed with SPDHOST_BROM_TRACE=1 or --verbose-style trace. */
static const char *speed_name(int sp)
{
	switch (sp) {
	case LIBUSB_SPEED_LOW: return "low";
	case LIBUSB_SPEED_FULL: return "full";
	case LIBUSB_SPEED_HIGH: return "high";
	case LIBUSB_SPEED_SUPER: return "super";
	case LIBUSB_SPEED_SUPER_PLUS: return "super+";
	default: return "unknown";
	}
}

static void trace_device(struct spd_usb *u)
{
	libusb_device *dev = libusb_get_device(u->handle);
	struct libusb_device_descriptor d;
	int cfg = -1;

	if (libusb_get_device_descriptor(dev, &d) < 0)
		return;
	(void)libusb_get_configuration(u->handle, &cfg);
	fprintf(stderr,
		"brom: dev speed=%s bcdUSB=%x.%02x class=%02x cfg=%d iface=%d "
		"ep_out=0x%02x(mps %d) ep_in=0x%02x(mps %d) ep0_mps=%d\n",
		speed_name(libusb_get_device_speed(dev)),
		(unsigned)(d.bcdUSB >> 8), (unsigned)(d.bcdUSB & 0xff),
		d.bDeviceClass, cfg, u->claimed_iface,
		u->ep_out, u->out_mps, u->ep_in, u->in_mps, d.bMaxPacketSize0);
}

/* CLEAR_FEATURE(ENDPOINT_HALT) on both bulk endpoints, called only from
 * spd_brom_after_line_state() — i.e. only on the BootROM-hello path, after
 * line-state, never from every open/reacquire.
 *
 * Also resets the data toggle on both sides, which rules out a toggle mismatch
 * after an earlier cancelled transfer. Errors are not fatal (some BootROMs
 * stall the request) but are always printed, trace or not.
 * Disable for A/B testing with SPDHOST_NO_CLEAR_HALT=1. */
void spd_usb_clear_halts(struct spd_usb *u)
{
	const char *off = getenv("SPDHOST_NO_CLEAR_HALT");
	int ei, eo;

	if (!u || !u->handle)
		return;
	if (off && off[0] && off[0] != '0') {
		if (brom_trace_on())
			fprintf(stderr, "brom: clear_halt skipped (SPDHOST_NO_CLEAR_HALT)\n");
		return;
	}
	ei = libusb_clear_halt(u->handle, (unsigned char)u->ep_in);
	eo = libusb_clear_halt(u->handle, (unsigned char)u->ep_out);
	if (brom_trace_on())
		fprintf(stderr, "brom: clear_halt in=%s out=%s @%lldms\n",
			libusb_error_name(ei), libusb_error_name(eo), mono_ms());
	else if (ei < 0 || eo < 0)
		fprintf(stderr, "brom: clear_halt in=%s out=%s\n",
			libusb_error_name(ei), libusb_error_name(eo));
}

static int claim_bulk(struct spd_usb *u)
{
	libusb_device_handle *h = u->handle;
	struct libusb_config_descriptor *cfg = NULL;
	int i, k, err, found = 0;

	err = libusb_get_config_descriptor(libusb_get_device(h), 0, &cfg);
	if (err < 0) {
		fprintf(stderr, "config descriptor: %s\n", libusb_error_name(err));
		return -1;
	}

	for (k = 0; k < cfg->bNumInterfaces && !found; k++) {
		const struct libusb_interface *iface = cfg->interface + k;
		const struct libusb_interface_descriptor *alt;
		int in = -1, out = -1, mps = 0, inmps = 0, num;

		if (iface->num_altsetting < 1)
			continue;
		alt = iface->altsetting;
		for (i = 0; i < alt->bNumEndpoints; i++) {
			const struct libusb_endpoint_descriptor *ep = alt->endpoint + i;
			int pkt;
			if ((ep->bmAttributes & 0x3) != LIBUSB_TRANSFER_TYPE_BULK)
				continue;
			/* Bits 11-12 are transactions per microframe, not size. */
			pkt = ep->wMaxPacketSize & 0x7ff;
			if (ep->bEndpointAddress & 0x80) {
				if (in >= 0) {
					fprintf(stderr, "more than one bulk IN\n");
					libusb_free_config_descriptor(cfg);
					return -1;
				}
				in = ep->bEndpointAddress;
				inmps = pkt;
			} else {
				if (out >= 0) {
					fprintf(stderr, "more than one bulk OUT\n");
					libusb_free_config_descriptor(cfg);
					return -1;
				}
				out = ep->bEndpointAddress;
				mps = pkt;
			}
		}
		if (in < 0 || out < 0)
			continue;

		num = alt->bInterfaceNumber;
		err = libusb_kernel_driver_active(h, num);
		if (err > 0) {
			err = libusb_detach_kernel_driver(h, num);
			if (err < 0 && err != LIBUSB_ERROR_NOT_SUPPORTED) {
				fprintf(stderr, "detach: %s\n", libusb_error_name(err));
				libusb_free_config_descriptor(cfg);
				return -1;
			}
		}
		err = libusb_claim_interface(h, num);
		if (err < 0) {
			fprintf(stderr, "claim interface %d: %s\n", num, libusb_error_name(err));
			if (err == LIBUSB_ERROR_BUSY) {
				fprintf(stderr,
					"interface %d is busy: a previous run or another app still holds it.\n"
					"Unplug the device, replug it into download mode and retry.\n",
					num);
			}
			libusb_free_config_descriptor(cfg);
			return -1;
		}
		u->ep_in = in;
		u->ep_out = out;
		u->out_mps = mps;
		u->in_mps = inmps;
		u->claimed_iface = num;
		found = 1;
	}
	libusb_free_config_descriptor(cfg);
	if (!found) {
		fprintf(stderr, "no bulk IN/OUT pair on the device\n");
		return -1;
	}
	if (brom_trace_on()) {
		trace_device(u);
		fprintf(stderr, "brom: open/claim done @%lldms\n", mono_ms());
	}
	return 0;
}

static int accept_vendor(struct spd_usb *u, int strict_pid)
{
	struct libusb_device_descriptor d;
	int err = libusb_get_device_descriptor(libusb_get_device(u->handle), &d);
	if (err < 0) {
		fprintf(stderr, "device descriptor: %s\n", libusb_error_name(err));
		return -1;
	}
	fprintf(stderr, "usb %04x:%04x\n", d.idVendor, d.idProduct);
	if (d.idVendor != u->vid) {
		fprintf(stderr, "refusing device: vendor is not %04x\n", u->vid);
		return -1;
	}
	if (strict_pid && u->pid && d.idProduct != u->pid) {
		fprintf(stderr, "refusing device: product is %04x, wanted %04x\n",
			d.idProduct, u->pid);
		return -1;
	}
	if (u->pid && d.idProduct != u->pid)
		fprintf(stderr, "note: product %04x (opened as %04x)\n", d.idProduct, u->pid);
	return 0;
}

static int adopt(struct spd_usb *u, libusb_device_handle *h, int strict_pid)
{
	int err, cfg = 0;
	u->handle = h;
	u->gone = 0;
	/* A device that arrives unconfigured cannot be claimed; this is what
	 * fixes it. On by default since a6cb72d. SPDHOST_NO_SET_CONFIG=1 skips it
	 * for a host that dislikes the re-enumeration. */
	if (!extra_off("SPDHOST_NO_SET_CONFIG")) {
		err = libusb_get_configuration(h, &cfg);
		if (err == 0 && cfg == 0) {
			err = libusb_set_configuration(h, 1);
			if (err < 0 && err != LIBUSB_ERROR_NOT_SUPPORTED && err != LIBUSB_ERROR_BUSY)
				fprintf(stderr, "warning: set_configuration: %s\n", libusb_error_name(err));
		}
	}
	if (accept_vendor(u, strict_pid) || claim_bulk(u)) {
		/* claim failed: nothing to release. accept_vendor fail: no claim yet. */
		u->claimed_iface = -1;
		libusb_close(h);
		u->handle = NULL;
		return -1;
	}
	return 0;
}

static int init_ctx(struct spd_usb *u, int no_scan)
{
	libusb_context *ctx = NULL;
	int err;

	if (no_scan) {
#if defined(LIBUSB_API_VERSION) && LIBUSB_API_VERSION >= 0x0100010A
		struct libusb_init_option opt;
		/* Current libusb ignores this flag unless it is passed to
		 * libusb_init_context. set_option()+libusb_init() is unspecified. */
		opt.option = LIBUSB_OPTION_NO_DEVICE_DISCOVERY;
		opt.value.ival = 1;
		err = libusb_init_context(&ctx, &opt, 1);
#else
		libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY);
		err = libusb_init(&ctx);
#endif
	} else {
		err = libusb_init(&ctx);
	}
	if (err < 0)
		die_usb("libusb_init", err);
	u->ctx = ctx;
	return 0;
}

int spd_usb_open(struct spd_usb *u, int fd, unsigned vid, unsigned pid, int timeout_ms)
{
	libusb_device_handle *h = NULL;
	int err;

	memset(u, 0, sizeof(*u));
	u->timeout_ms = timeout_ms;
	u->vid = vid;
	u->pid = pid;
	u->reac_left = 4;
	u->claimed_iface = -1;
	u->fd_mode = fd >= 0;
	u->last_bus[0] = 0;
	{
		const char *bus = getenv("SPDHOST_USB_BUS");
		if (bus && bus[0] && strncmp(bus, "/dev/bus/usb/", 13) == 0)
			snprintf(u->last_bus, sizeof(u->last_bus), "%s", bus);
	}
	init_ctx(u, u->fd_mode);

	if (fd >= 0) {
		if (fcntl(fd, F_GETFD) == -1) {
			fprintf(stderr, "USB FD %d is not open: %s\n", fd, strerror(errno));
			exit(1);
		}
		err = libusb_wrap_sys_device(u->ctx, (intptr_t)fd, &h);
		if (err < 0) {
			fprintf(stderr,
				"libusb_wrap_sys_device(%d): %s\n"
				"The descriptor must be a live usbfs FD from termux-usb.\n",
				fd, libusb_error_name(err));
			exit(1);
		}
	} else {
		h = libusb_open_device_with_vid_pid(u->ctx, (uint16_t)vid, (uint16_t)pid);
		if (!h) {
			fprintf(stderr, "no USB device %04x:%04x (permission or cable)\n", vid, pid);
			exit(1);
		}
	}
	/* A descriptor the user already chose (termux-usb) may come back as a
	 * different product id after a loader stage. Scanning still requires
	 * the requested product id. */
	if (adopt(u, h, fd < 0))
		exit(1);
	g_live_usb = u;
	atexit(atexit_release);
	return 0;
}

void spd_usb_enable_reacquire(struct spd_usb *u, const char *self_path)
{
	if (!u)
		return;
	u->reacquire = 1;
	if (self_path)
		snprintf(u->self_path, sizeof(u->self_path), "%s", self_path);
}

void spd_usb_close(struct spd_usb *u)
{
	if (!u)
		return;
	release_claimed(u);
	if (g_live_usb == u)
		g_live_usb = NULL;
	if (u->handle)
		libusb_close(u->handle);
	if (u->ctx)
		libusb_exit(u->ctx);
	u->handle = NULL;
	u->ctx = NULL;
}

int spd_usb_line_state(struct spd_usb *u)
{
	int err = libusb_control_transfer(u->handle, 0x21, 34, 0x601, 0, NULL, 0, u->timeout_ms);
	if (err < 0) {
		fprintf(stderr, "line-state control transfer failed: %s\n", libusb_error_name(err));
		fprintf(stderr, "retry with --no-line-state if this device is not a phone BootROM\n");
		return -1;
	}
	if (brom_trace_on())
		fprintf(stderr, "brom: line-state done @%lldms\n", mono_ms());
	return 0;
}

int spd_usb_bulk_send(struct spd_usb *u, const uint8_t *buf, int len)
{
	int sent = 0;
	int err = libusb_bulk_transfer(u->handle, u->ep_out,
		(unsigned char *)buf, len, &sent, u->timeout_ms);
	if (err < 0) {
		fprintf(stderr, "usb send: %s\n", libusb_error_name(err));
		/* NO_DEVICE/PIPE/IO after EXEC usually means the device left the bus.
		 * Mark gone so reopen_if_gone can reacquire; return -1 for all three. */
		if (err == LIBUSB_ERROR_NO_DEVICE || err == LIBUSB_ERROR_IO || err == LIBUSB_ERROR_PIPE) {
			u->gone = 1;
			return -1;
		}
		/* TIMEOUT (and other non-disconnect errors): -2, gone unset.
		 * BootROM hello may soft-retry TIMEOUT; other callers treat <0 as fail. */
		return -2;
	}
	if (sent != len) {
		fprintf(stderr, "usb send short: %d/%d\n", sent, len);
		return -2;
	}
	/* Match the known-good clients: a zero-length packet only for a
	 * 512-byte high-speed bulk pipe, and only when the transfer fills it.
	 * On by default since a6cb72d; SPDHOST_NO_SEND_ZLP=1 turns it off. */
	if (!extra_off("SPDHOST_NO_SEND_ZLP") && u->out_mps == 512 && (len % 512) == 0) {
		int dummy = 0;
		libusb_bulk_transfer(u->handle, u->ep_out, NULL, 0, &dummy, u->timeout_ms);
	}
	return sent;
}

int spd_usb_bulk_recv(struct spd_usb *u, uint8_t *buf, int cap, int timeout_ms)
{
	int got = 0;
	int err = libusb_bulk_transfer(u->handle, u->ep_in, buf, cap, &got, timeout_ms);
	if (err == LIBUSB_ERROR_TIMEOUT) {
		/* EXPERIMENT (item 2): libusb may report TIMEOUT together with bytes
		 * that arrived before the cancel. Keep them instead of dropping. */
		if (got > 0) {
			if (brom_trace_on())
				fprintf(stderr, "brom: recv TIMEOUT but %d bytes arrived; keeping\n", got);
			return got;
		}
		return 0;
	}
	if (err == LIBUSB_ERROR_NO_DEVICE || err == LIBUSB_ERROR_IO || err == LIBUSB_ERROR_PIPE) {
		u->gone = 1;
		fprintf(stderr, "usb recv: %s (device left the bus)\n", libusb_error_name(err));
		return -1;
	}
	if (err < 0) {
		fprintf(stderr, "usb recv: %s\n", libusb_error_name(err));
		return -2;
	}
	return got;
}

static int send_fd(int sock, int fd)
{
	struct msghdr msg;
	struct iovec iov;
	char buf[1] = { 'F' };
	char cbuf[CMSG_SPACE(sizeof(int))];
	struct cmsghdr *cmsg;

	memset(&msg, 0, sizeof(msg));
	memset(cbuf, 0, sizeof(cbuf));
	iov.iov_base = buf;
	iov.iov_len = 1;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = cbuf;
	msg.msg_controllen = sizeof(cbuf);
	cmsg = CMSG_FIRSTHDR(&msg);
	cmsg->cmsg_level = SOL_SOCKET;
	cmsg->cmsg_type = SCM_RIGHTS;
	cmsg->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(cmsg), &fd, sizeof(fd));
	if (sendmsg(sock, &msg, 0) < 0) {
		perror("sendmsg");
		return -1;
	}
	return 0;
}

static int recv_fd(int sock)
{
	struct msghdr msg;
	struct iovec iov;
	char buf[1];
	char cbuf[CMSG_SPACE(sizeof(int))];
	struct cmsghdr *cmsg;
	int fd = -1;

	memset(&msg, 0, sizeof(msg));
	iov.iov_base = buf;
	iov.iov_len = 1;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = cbuf;
	msg.msg_controllen = sizeof(cbuf);
	if (recvmsg(sock, &msg, 0) < 0) {
		perror("recvmsg");
		return -1;
	}
	for (cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
		if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
			memcpy(&fd, CMSG_DATA(cmsg), sizeof(fd));
			break;
		}
	}
	return fd;
}

int spd_usb_emit_fd(const char *sock_path, const char *argv_fd)
{
	struct sockaddr_un addr;
	const char *env;
	char *end = NULL;
	long fd;
	int sock;

	env = getenv("TERMUX_USB_FD");      /* SPD_USB_FD aliases TERMUX_USB_FD */
	if (!env || !env[0]) {
		env = getenv("SPD_USB_FD");
		if (env && !env[0])
			env = NULL;
	}
	/* termux-usb only sets TERMUX_USB_FD when it was given -E. Without it the
	 * descriptor is the launcher's argv[1] — the same two-form contract the
	 * wrapper's generated launcher already honours (${TERMUX_USB_FD:-${1:-}}).
	 * Reading only the env var here would make reopen fail outright on an
	 * older termux-api. */
	if ((!env || !env[0]) && argv_fd && argv_fd[0])
		env = argv_fd;
	if (!env || !env[0]) {
		fprintf(stderr, "SPDHOST_EMIT_SOCK set but no USB fd (TERMUX_USB_FD/SPD_USB_FD unset, no argv[1])\n");
		return 1;
	}
	errno = 0;
	fd = strtol(env, &end, 10);
	if (end == env || *end || errno || fd < 3 || fd > 0x7fffffff) {
		fprintf(stderr, "bad TERMUX_USB_FD/SPD_USB_FD: %s (need open FD >= 3)\n", env);
		return 1;
	}
	if (fcntl((int)fd, F_GETFD) == -1) {
		fprintf(stderr, "TERMUX_USB_FD/SPD_USB_FD %ld is not open: %s\n", fd, strerror(errno));
		return 1;
	}
	sock = socket(AF_UNIX, SOCK_STREAM, 0);
	if (sock < 0) {
		perror("socket");
		return 1;
	}
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sock_path);
	if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("connect fd socket");
		close(sock);
		return 1;
	}
	if (send_fd(sock, (int)fd)) {
		close(sock);
		return 1;
	}
	close(sock);
	return 0;
}

/* Whole stdout, capped at 64 KiB. A 256-byte fgets splits one JSON line
 * and glues or drops paths. Caller frees. NULL if popen or malloc fails. */
static char *read_cmd(const char *cmd)
{
	FILE *p;
	char *buf, *grown;
	size_t n = 0, bcap = 4096, got;

	p = popen(cmd, "r");
	if (!p)
		return NULL;
	buf = malloc(bcap);
	if (!buf) {
		pclose(p);
		return NULL;
	}
	while (n + 1 < bcap) {
		got = fread(buf + n, 1, bcap - n - 1, p);
		if (!got)
			break;
		n += got;
		if (n + 1 >= bcap && bcap < 65536) {
			grown = realloc(buf, bcap * 2);
			if (!grown)
				break;
			buf = grown;
			bcap *= 2;
		}
	}
	buf[n] = 0;
	pclose(p);
	return buf;
}

/* Fill out with one usable bus path. The remembered path wins when it is
 * still listed. Otherwise one vendor-1782 node wins over mice and hubs.
 * A lone path with no vendor id is still taken. A list longer than the
 * stored prefix is not guessed, except for that remembered path.
 * Returns -1 on a list failure, 1 when out is set, or the device count
 * when nothing is chosen. */
static int list_one_device(char *out, size_t cap, const char *prefer)
{
	char *buf;
	struct spd_usb_dev devs[16];
	int count, stored, t = 8;
	const char *e;
	char cmd[192];

	out[0] = 0;
	e = getenv("SPD_USB_LIST_TIMEOUT");
	if (e && e[0]) {
		t = atoi(e);
		if (t < 1)
			t = 8;
		if (t > 60)
			t = 60;
	}
	/* Same bound as the wrapper. Without `timeout`, fall back to a plain
	 * list so a host that has no coreutils still reacquires. */
	snprintf(cmd, sizeof(cmd),
		"if command -v timeout >/dev/null 2>&1; then "
		"timeout %d termux-usb -l 2>/dev/null; "
		"else termux-usb -l 2>/dev/null; fi", t);
	buf = read_cmd(cmd);
	if (!buf)
		return -1;
	count = spd_usb_collect_devs(buf, devs, 16, 0);
	free(buf);
	stored = count < 16 ? count : 16;
	if (count <= 16)
		spd_usb_fill_sysfs(devs, stored);
	if (spd_usb_choose_bounded(devs, stored, count, prefer, out, cap)) {
		if (count > 1)
			fprintf(stderr, "reacquire: using %s (%d USB devices listed)\n",
				out, count);
		return 1;
	}
	return count;
}

static void print_bus_paths(void)
{
	char *buf;
	struct spd_usb_dev devs[16];
	int count, shown, i;

	buf = read_cmd("termux-usb -l 2>/dev/null");
	if (!buf) {
		fprintf(stderr, "  (none)\n");
		return;
	}
	count = spd_usb_collect_devs(buf, devs, 16, 0);
	free(buf);
	if (count <= 0) {
		fprintf(stderr, "  (none)\n");
		return;
	}
	shown = count < 16 ? count : 16;
	for (i = 0; i < shown; i++)
		fprintf(stderr, "  %s\n", devs[i].path);
	if (count > 16)
		fprintf(stderr, "  ... and %d more\n", count - 16);
}

/* Does the installed termux-usb understand -E (export TERMUX_USB_FD)?
 * The wrapper probes the same way and keeps a legacy fallback, and the reopen
 * child below used to hardcode -E anyway — so on a termux-api that predates
 * the flag, every reopen attempt failed and the tool could never pick the
 * device up again after a loader reset: the handle stays dead and every
 * subsequent transfer times out. Probe, and drop -E when it is not there. */
static int termux_usb_has_e(void)
{
	FILE *p = popen("termux-usb -h 2>&1", "r");
	char buf[4096];
	size_t n = 0;
	int found = 0;

	if (!p)
		return 0;
	n = fread(buf, 1, sizeof(buf) - 1, p);
	buf[n] = 0;
	pclose(p);
	found = strstr(buf, " -E ") != NULL;
	return found;
}

/* P4 post-FDL reconnect SM (deferred — stub/docs only this release):
 * intended harden on gone/post-EXEC: close → wait unique 1782 (prefer 4d00)
 * → re-termux-usb → new wrap; refuse multi-device auto-pick; never mid-hello.
 * This helper is the existing Termux reopen path; do not rewrite mid-BootROM. */
static int grab_termux(struct spd_usb *u)
{
	char dir[192];
	char sock_path[224];
	char dev[128];
	struct sockaddr_un addr;
	int listen_fd = -1, conn = -1, got = -1, i;
	int has_e;
	const char *tmp;

	if (!u->self_path[0]) {
		fprintf(stderr, "cannot reacquire: missing path to this binary\n");
		return -1;
	}
	tmp = getenv("TMPDIR");
	if (!tmp || !tmp[0])
		tmp = "/tmp";
	if ((size_t)snprintf(dir, sizeof(dir), "%s/spdhost-XXXXXX", tmp) >= sizeof(dir)) {
		fprintf(stderr, "TMPDIR is too long for a socket path\n");
		return -1;
	}
	if (!mkdtemp(dir)) {
		perror("mkdtemp");
		return -1;
	}
	if ((size_t)snprintf(sock_path, sizeof(sock_path), "%s/fd.sock", dir) >= sizeof(sock_path)
		|| strlen(sock_path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
		fprintf(stderr, "socket path too long\n");
		rmdir(dir);
		return -1;
	}
	/* Once, before the retry loop: this spawns a helper, and the loop runs up
	 * to 60 times inside a window the BootROM measures in seconds. */
	has_e = termux_usb_has_e();
	listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (listen_fd < 0) {
		perror("socket");
		rmdir(dir);
		return -1;
	}
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sock_path);
	if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(listen_fd, 1) < 0) {
		perror("bind fd socket");
		close(listen_fd);
		rmdir(dir);
		return -1;
	}

	for (i = 0; i < 60 && got < 0; i++) {
		int n;
		pid_t pid;
		struct pollfd pfd;
		int status;

		if (spd_interrupted) {
			fprintf(stderr, "interrupted; giving up on reacquire\n");
			break;
		}
		n = list_one_device(dev, sizeof(dev), u->last_bus);
		if (n < 0) {
			fprintf(stderr, "termux-usb -l failed. Is Termux:API installed?\n");
			break;
		}
		if (n != 1 || !dev[0]) {
			if (n > 1) {
				/* Prefer last_bus when several nodes exist; otherwise keep
				 * waiting through the renumeration window, then explain. */
				if (u->last_bus[0] && i > 0 && i % 12 == 0) {
					fprintf(stderr, "reacquire: %d USB devices; remembered %s is gone\n",
						n, u->last_bus);
					fprintf(stderr, "pass an explicit /dev/bus/usb/... to spdhost-usb:\n");
					print_bus_paths();
				} else if (!u->last_bus[0] && (i == 0 || i % 12 == 0)) {
					fprintf(stderr, "reacquire: %d USB devices; waiting for a single node\n", n);
					print_bus_paths();
				}
			} else if (i == 0) {
				fprintf(stderr, "waiting for the phone to reappear on USB\n");
			}
			usleep(250000);
			continue;
		}
		pid = fork();
		if (pid < 0) {
			perror("fork");
			break;
		}
		if (pid == 0) {
			const char *av[8];
			int k = 0;
			setenv("SPDHOST_EMIT_SOCK", sock_path, 1);
			av[k++] = "termux-usb";
			av[k++] = "-r";
			if (has_e)
				av[k++] = "-E";
			av[k++] = "-e";
			av[k++] = u->self_path;
			av[k++] = dev;
			av[k] = NULL;
			execvp("termux-usb", (char *const *)av);
			perror("termux-usb");
			_exit(127);
		}
		pfd.fd = listen_fd;
		pfd.events = POLLIN;
		if (poll(&pfd, 1, 8000) > 0)
			conn = accept(listen_fd, NULL, NULL);
		if (conn >= 0)
			got = recv_fd(conn);
		if (conn >= 0)
			close(conn);
		conn = -1;
		waitpid(pid, &status, 0);
		if (got < 0) {
			usleep(250000);
			continue;
		}
		{
			libusb_device_handle *h = NULL;
			int err = libusb_wrap_sys_device(u->ctx, (intptr_t)got, &h);
			if (err < 0) {
				fprintf(stderr,
					"reopen wrap FD %d: %s (need a live usbfs FD from termux-usb)\n",
					got, libusb_error_name(err));
				close(got);
				got = -1;
				continue;
			}
			/* wrap_sys_device owns got. adopt() closes it on failure. */
			got = -1;
			/* After a loader reset the product id can change. Vendor stays 1782. */
			if (adopt(u, h, 0)) {
				usleep(250000);
				continue;
			}
			snprintf(u->last_bus, sizeof(u->last_bus), "%s", dev);
			fprintf(stderr, "reopened %s\n", dev);
			break;
		}
	}

	close(listen_fd);
	unlink(sock_path);
	rmdir(dir);
	return u->handle ? 0 : -1;
}

/* After a loader starts the product id may change; vendor stays 1782.
 * Enumerate that vendor. On a desktop several 1782 devices can be attached
 * at once (another phone, a hub full of unrelated gear that happens to
 * share the vendor ID). To avoid silently reattaching to the wrong one,
 * prefer a device whose product id still matches what we had before this
 * reset; only fall back to "first one that opens" when nothing matches,
 * and say so, since that fallback is a guess. */
static int grab_enum(struct spd_usb *u)
{
	int i;
	for (i = 0; i < 60; i++) {
		libusb_device **list = NULL;
		ssize_t n, k;
		unsigned vendor_matches = 0;
		if (spd_interrupted) {
			fprintf(stderr, "interrupted; giving up on reacquire\n");
			break;
		}
		if (i == 0)
			fprintf(stderr, "waiting for vendor %04x to reappear (any product)\n", u->vid);
		n = libusb_get_device_list(u->ctx, &list);
		if (n < 0) {
			usleep(250000);
			continue;
		}
		for (k = 0; k < n; k++) {
			struct libusb_device_descriptor d;
			if (libusb_get_device_descriptor(list[k], &d) == 0 && d.idVendor == u->vid)
				vendor_matches++;
		}
		/* Pass 1: exact match on the product id we had before the reset. */
		for (k = 0; k < n; k++) {
			struct libusb_device_descriptor d;
			libusb_device_handle *h = NULL;
			if (libusb_get_device_descriptor(list[k], &d) < 0)
				continue;
			if (d.idVendor != u->vid || d.idProduct != u->pid)
				continue;
			if (libusb_open(list[k], &h) < 0 || !h)
				continue;
			if (adopt(u, h, 1) == 0) { /* strict_pid=1: this pass only wants the exact match */
				fprintf(stderr, "reopened %04x:%04x\n", u->vid, u->pid);
				libusb_free_device_list(list, 1);
				return 0;
			}
		}
		if (vendor_matches > 1)
			fprintf(stderr, "reacquire: %u devices share vendor %04x and none matches"
				" the previous product id %04x; guessing the first one that opens\n",
				vendor_matches, u->vid, u->pid);
		/* Pass 2: any product under this vendor (loader legitimately changed it,
		 * or this is the first reacquire after adopting by fd, pid unknown yet). */
		for (k = 0; k < n; k++) {
			struct libusb_device_descriptor d;
			libusb_device_handle *h = NULL;
			int err;
			if (libusb_get_device_descriptor(list[k], &d) < 0)
				continue;
			if (d.idVendor != u->vid)
				continue;
			err = libusb_open(list[k], &h);
			if (err < 0 || !h)
				continue;
			/* strict_pid=0: accept any product under this vendor. */
			if (adopt(u, h, 0) == 0) {
				if (d.idProduct != u->pid) {
					fprintf(stderr, "reacquire: product id changed %04x -> %04x\n",
						u->pid, d.idProduct);
					u->pid = d.idProduct;
				}
				fprintf(stderr, "reopened %04x:%04x\n", u->vid, u->pid);
				libusb_free_device_list(list, 1);
				return 0;
			}
		}
		libusb_free_device_list(list, 1);
		usleep(250000);
	}
	return -1;
}

int spd_usb_reacquire(struct spd_usb *u)
{
	if (!u->reacquire || u->reac_left <= 0) {
		fprintf(stderr, "not reopening the device (no attempts left, or reacquire is off)\n");
		return -1;
	}
	u->reac_left--;
	if (u->handle) {
		release_claimed(u);
		libusb_close(u->handle);
		u->handle = NULL;
	}
	u->gone = 0;
	/* Give the host stack a moment to drop the old node. */
	usleep(300000);
	if (u->fd_mode)
		return grab_termux(u);
	return grab_enum(u);
}
