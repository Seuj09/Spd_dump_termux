#define _GNU_SOURCE

#include "usb.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <libusb-1.0/libusb.h>

static void die_usb(const char *what, int err)
{
	fprintf(stderr, "%s: %s\n", what, libusb_error_name(err));
	exit(1);
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
		int in = -1, out = -1, mps = 0, num;

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
			if (err == LIBUSB_ERROR_BUSY)
				fprintf(stderr, "brom: reacq skipped: claim BUSY\n");
			libusb_free_config_descriptor(cfg);
			return -1;
		}
		u->ep_in = in;
		u->ep_out = out;
		u->out_mps = mps;
		found = 1;
	}
	libusb_free_config_descriptor(cfg);
	if (!found) {
		fprintf(stderr, "no bulk IN/OUT pair on the device\n");
		return -1;
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
	err = libusb_get_configuration(h, &cfg);
	if (err == 0 && cfg == 0) {
		err = libusb_set_configuration(h, 1);
		if (err < 0 && err != LIBUSB_ERROR_NOT_SUPPORTED && err != LIBUSB_ERROR_BUSY)
			fprintf(stderr, "warning: set_configuration: %s\n", libusb_error_name(err));
	}
	if (accept_vendor(u, strict_pid) || claim_bulk(u)) {
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
	u->fd_mode = fd >= 0;
	u->last_bus[0] = 0;
	{
		const char *bus = getenv("SPDHOST_USB_BUS");
		if (bus && bus[0] && strncmp(bus, "/dev/bus/usb/", 13) == 0)
			snprintf(u->last_bus, sizeof(u->last_bus), "%s", bus);
	}
	init_ctx(u, u->fd_mode);

	if (fd >= 0) {
		err = libusb_wrap_sys_device(u->ctx, (intptr_t)fd, &h);
		if (err < 0)
			die_usb("libusb_wrap_sys_device", err);
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
	 * 512-byte high-speed bulk pipe, and only when the transfer fills it. */
	if (u->out_mps == 512 && (len % 512) == 0) {
		int dummy = 0;
		libusb_bulk_transfer(u->handle, u->ep_out, NULL, 0, &dummy, u->timeout_ms);
	}
	return sent;
}

int spd_usb_bulk_recv(struct spd_usb *u, uint8_t *buf, int cap, int timeout_ms)
{
	int got = 0;
	int err = libusb_bulk_transfer(u->handle, u->ep_in, buf, cap, &got, timeout_ms);
	if (err == LIBUSB_ERROR_TIMEOUT)
		return 0;
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

int spd_usb_emit_fd(const char *sock_path)
{
	struct sockaddr_un addr;
	const char *env;
	char *end = NULL;
	long fd;
	int sock;

	env = getenv("TERMUX_USB_FD");
	if (!env || !env[0]) {
		fprintf(stderr, "SPDHOST_EMIT_SOCK set but TERMUX_USB_FD is missing\n");
		return 1;
	}
	errno = 0;
	fd = strtol(env, &end, 10);
	if (end == env || *end || fd < 0 || errno) {
		fprintf(stderr, "bad TERMUX_USB_FD: %s\n", env);
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

/* Fill out with a single usable bus path. Prefer prefer[] when several
 * devices are present (remembered path from a prior successful open).
 * Returns device count; out is set only when exactly one path is chosen. */
static int list_one_device(char *out, size_t cap, const char *prefer)
{
	FILE *p;
	char line[256];
	char paths[8][128];
	int count = 0, i;
	out[0] = 0;
	p = popen("termux-usb -l 2>/dev/null", "r");
	if (!p)
		return -1;
	while (fgets(line, sizeof(line), p)) {
		char *path = strstr(line, "/dev/bus/usb/");
		char *end;
		if (!path)
			continue;
		end = path;
		while (*end && *end != '"' && *end != ' ' && *end != '\n' && *end != '\r')
			end++;
		*end = 0;
		if (count < 8)
			snprintf(paths[count], sizeof(paths[count]), "%s", path);
		count++;
	}
	pclose(p);
	if (count == 1) {
		snprintf(out, cap, "%s", paths[0]);
		return 1;
	}
	if (count > 1 && prefer && prefer[0]) {
		for (i = 0; i < count && i < 8; i++) {
			if (strcmp(paths[i], prefer) == 0) {
				snprintf(out, cap, "%s", prefer);
				return 1;
			}
		}
	}
	return count;
}

static void print_bus_paths(void)
{
	FILE *p;
	char line[256];
	int n = 0;
	p = popen("termux-usb -l 2>/dev/null", "r");
	if (!p)
		return;
	while (fgets(line, sizeof(line), p)) {
		char *path = strstr(line, "/dev/bus/usb/");
		char *end;
		if (!path)
			continue;
		end = path;
		while (*end && *end != '"' && *end != ' ' && *end != '\n' && *end != '\r')
			end++;
		*end = 0;
		fprintf(stderr, "  %s\n", path);
		n++;
	}
	pclose(p);
	if (!n)
		fprintf(stderr, "  (none)\n");
}

static int grab_termux(struct spd_usb *u)
{
	char dir[192];
	char sock_path[224];
	char dev[128];
	struct sockaddr_un addr;
	int listen_fd = -1, conn = -1, got = -1, i;
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
		int n = list_one_device(dev, sizeof(dev), u->last_bus);
		pid_t pid;
		struct pollfd pfd;
		int status;

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
			setenv("SPDHOST_EMIT_SOCK", sock_path, 1);
			execlp("termux-usb", "termux-usb", "-r", "-E", "-e", u->self_path, dev, (char *)NULL);
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
				fprintf(stderr, "reopen wrap: %s\n", libusb_error_name(err));
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
 * Enumerate that vendor and adopt the first matching bulk device.
 * Updates u->pid when the product id differs from the initial open. */
static int grab_enum(struct spd_usb *u)
{
	int i;
	for (i = 0; i < 60; i++) {
		libusb_device **list = NULL;
		ssize_t n, k;
		if (i == 0)
			fprintf(stderr, "waiting for vendor %04x to reappear (any product)\n", u->vid);
		n = libusb_get_device_list(u->ctx, &list);
		if (n < 0) {
			usleep(250000);
			continue;
		}
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
