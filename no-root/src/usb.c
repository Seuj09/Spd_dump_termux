#include "usb.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libusb-1.0/libusb.h>

static void die_usb(const char *what, int err)
{
	fprintf(stderr, "%s: %s\n", what, libusb_error_name(err));
	exit(1);
}

static void claim_bulk(struct spd_usb *u)
{
	libusb_device_handle *h = u->handle;
	struct libusb_config_descriptor *cfg = NULL;
	int i, k, err, found = 0;

	err = libusb_get_config_descriptor(libusb_get_device(h), 0, &cfg);
	if (err < 0)
		die_usb("libusb_get_config_descriptor", err);

	for (k = 0; k < cfg->bNumInterfaces && !found; k++) {
		const struct libusb_interface *iface = cfg->interface + k;
		const struct libusb_interface_descriptor *alt;
		int in = -1, out = -1, mps = 0, num;

		if (iface->num_altsetting < 1)
			continue;
		alt = iface->altsetting;
		for (i = 0; i < alt->bNumEndpoints; i++) {
			const struct libusb_endpoint_descriptor *ep = alt->endpoint + i;
			if ((ep->bmAttributes & 0x3) != LIBUSB_TRANSFER_TYPE_BULK)
				continue;
			if (ep->bEndpointAddress & 0x80) {
				if (in >= 0)
					die_usb("more than one bulk IN", LIBUSB_ERROR_OTHER);
				in = ep->bEndpointAddress;
			} else {
				if (out >= 0)
					die_usb("more than one bulk OUT", LIBUSB_ERROR_OTHER);
				out = ep->bEndpointAddress;
				mps = ep->wMaxPacketSize;
			}
		}
		if (in < 0 || out < 0)
			continue;

		num = alt->bInterfaceNumber;
		err = libusb_kernel_driver_active(h, num);
		if (err > 0) {
			err = libusb_detach_kernel_driver(h, num);
			if (err < 0 && err != LIBUSB_ERROR_NOT_SUPPORTED)
				die_usb("libusb_detach_kernel_driver", err);
		}
		err = libusb_claim_interface(h, num);
		if (err < 0)
			die_usb("libusb_claim_interface", err);

		u->ep_in = in;
		u->ep_out = out;
		u->out_mps = mps;
		found = 1;
	}
	libusb_free_config_descriptor(cfg);
	if (!found) {
		fprintf(stderr, "no bulk IN/OUT pair on the device\n");
		exit(1);
	}
}

int spd_usb_open(struct spd_usb *u, int fd, unsigned vid, unsigned pid, int timeout_ms)
{
	libusb_context *ctx = NULL;
	libusb_device_handle *h = NULL;
	int err, cfg = 0;

	memset(u, 0, sizeof(*u));
	u->timeout_ms = timeout_ms;

	if (fd >= 0) {
		/* Must be set on the default context before init, or libusb
		 * walks /dev/bus/usb and fails on Android. */
		libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY);
	}
	err = libusb_init(&ctx);
	if (err < 0)
		die_usb("libusb_init", err);
	u->ctx = ctx;

	if (fd >= 0) {
		err = libusb_wrap_sys_device(ctx, (intptr_t)fd, &h);
		if (err < 0)
			die_usb("libusb_wrap_sys_device", err);
	} else {
		h = libusb_open_device_with_vid_pid(ctx, (uint16_t)vid, (uint16_t)pid);
		if (!h) {
			fprintf(stderr, "no USB device %04x:%04x (permission or cable)\n", vid, pid);
			exit(1);
		}
	}
	u->handle = h;

	err = libusb_get_configuration(h, &cfg);
	if (err == 0 && cfg == 0) {
		err = libusb_set_configuration(h, 1);
		if (err < 0 && err != LIBUSB_ERROR_NOT_SUPPORTED)
			fprintf(stderr, "warning: set_configuration: %s\n", libusb_error_name(err));
	}
	claim_bulk(u);
	return 0;
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
		return err == LIBUSB_ERROR_NO_DEVICE ? -1 : -2;
	}
	if (sent != len) {
		fprintf(stderr, "usb send short: %d/%d\n", sent, len);
		return -2;
	}
	/* A full packet needs a zero-length packet so the device sees the end. */
	if (u->out_mps > 0 && (len % u->out_mps) == 0) {
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
	if (err == LIBUSB_ERROR_NO_DEVICE) {
		fprintf(stderr,
			"device disconnected. this build keeps a single termux-usb fd "
			"and cannot grab the device again after a USB reset\n");
		return -1;
	}
	if (err < 0) {
		fprintf(stderr, "usb recv: %s\n", libusb_error_name(err));
		return -2;
	}
	return got;
}
