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
	int gone;          /* last transfer saw a disconnect */
	int fd_mode;       /* opened from an existing descriptor, not by scanning */
	int reacquire;     /* try to grab the device again after a reset */
	int reac_left;
	int claimed_iface; /* bulk iface claimed; -1 if none (Termux release) */
	unsigned vid;
	unsigned pid;
	char self_path[512];
	char last_bus[128]; /* last successful Termux /dev/bus/usb path */
};

/* fd >= 0 adopts a termux-usb descriptor.
 * fd < 0 enumerates vid:pid (desktop; the node must be readable). */
int spd_usb_open(struct spd_usb *u, int fd, unsigned vid, unsigned pid, int timeout_ms);
void spd_usb_close(struct spd_usb *u);
void spd_usb_enable_reacquire(struct spd_usb *u, const char *self_path);

/* Called by the process termux-usb starts. Sends TERMUX_USB_FD to sock_path. */
int spd_usb_emit_fd(const char *sock_path);

/* Close the dead handle and open the device again.
 * Desktop: scan vid:pid. Termux: ask termux-usb for a new descriptor.
 * Returns 0 on success. */
int spd_usb_reacquire(struct spd_usb *u);

/* SET_CONTROL_LINE_STATE. Smartphone BootROM ignores the first bulk
 * transfer until this control request has been sent. wIndex is 0, which
 * is the CDC control interface, not necessarily the bulk interface. */
int spd_usb_line_state(struct spd_usb *u);

int spd_usb_bulk_send(struct spd_usb *u, const uint8_t *buf, int len);
/* >0 byte count, 0 timeout, -1 disconnect (u->gone set), -2 other error. */
int spd_usb_bulk_recv(struct spd_usb *u, uint8_t *buf, int cap, int timeout_ms);

#endif
