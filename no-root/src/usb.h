#ifndef SPDHOST_USB_H
#define SPDHOST_USB_H

#include <stdint.h>

struct spd_usb {
	void *ctx;
	void *handle;
	int ep_in;
	int ep_out;
	int out_mps;
	int timeout_ms;
};

/* fd >= 0 adopts a termux-usb / libusb_wrap_sys_device descriptor.
 * fd < 0 enumerates vid:pid (desktop, needs permission on the device node). */
int spd_usb_open(struct spd_usb *u, int fd, unsigned vid, unsigned pid, int timeout_ms);
void spd_usb_close(struct spd_usb *u);

/* SET_CONTROL_LINE_STATE. Smartphone BootROM ignores the first bulk
 * transfer until this control request has been sent. */
int spd_usb_line_state(struct spd_usb *u);

int spd_usb_bulk_send(struct spd_usb *u, const uint8_t *buf, int len);
/* Returns byte count, 0 on timeout, -1 on a dead device, < -1 on other errors. */
int spd_usb_bulk_recv(struct spd_usb *u, uint8_t *buf, int cap, int timeout_ms);

#endif
