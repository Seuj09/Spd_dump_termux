# No-root method (`spdhost`)

A small Unisoc download-mode client. One process, one USB device, no GUI.
It talks to a phone in BootROM or FDL over libusb bulk transfers.
No chroot and no root. The rooted chroot method is
[documented separately](../root/README.md).

This tree is original. It is not a fork of either repository below, and it
does not carry their code. Read them when you want to see how someone else
solved a piece. Do not paste them in here: `sfd_tool` is GPL-3.0-or-later.

## What the references are for

[C-Hidery/sfd_tool](https://github.com/C-Hidery/sfd_tool) is the one that
actually works. The part worth copying as an idea, not as source:

- On Android, do not open `/dev/bus/usb`. `termux-usb` already opened it.
- Call `libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY)` before
  `libusb_init`, then `libusb_wrap_sys_device` on that descriptor.
- After the first loader is executed, stay on the same handle and send
  check-baud again. Do not scan for a new device. Scanning is what Android
  will not let you do.

The cost of that design is the same here. If the phone resets USB and comes
back as a new device, the descriptor is dead and this process cannot get
another one. A later version can add a helper that calls `termux-usb` again
and passes the new descriptor over a socket. That is not in this build.

[itz-termux-dev/SPDClient-NoRoot-Termux](https://github.com/itz-termux-dev/SPDClient-NoRoot-Termux)
is the negative reference. The README describes FDL1, FDL2, HDLC, and a
BootROM exploit. The code does none of that: it `write()`s a usbfs descriptor
(that node is ioctl-based, not a byte stream), the frame has no length or
checksum, and the exploit function sends 256 zero bytes. Do not start from it.

spdhost also does not implement bootloader exploits, AVB or verity changes,
or FRP-specific commands. `write-part` and `erase-part` are ordinary partition
I/O. They ask you to type `yes` unless you pass `--yes`.

## Build

Desktop or Termux:

```sh
pkg install clang pkg-config libusb   # Termux
# or: apt install build-essential pkg-config libusb-1.0-0-dev
make
./spdhost --self-test
```

Termux does not need a chroot. The binary links Termux's libusb and runs as
the Termux user.

## Run

On a Linux PC that can open the device node (root, or a udev rule for
`1782:4d00`):

```sh
./spdhost fdl fdl1.bin 0x5500 fdl fdl2.bin 0x9efffe00 parts
./spdhost read-part boot 0 64M boot.img
```

Addresses above are examples. Use the load addresses for the FDL pair you
have. The tool does not ship loaders.

On a non-root Android host, with Termux and Termux:API installed from
F-Droid (the Play Store Termux build is too old):

```sh
pkg install termux-api
cp spdhost "$PREFIX/bin/"
cp scripts/spdhost-usb "$PREFIX/bin/"
spdhost-usb fdl fdl1.bin 0x5500 fdl fdl2.bin 0x9efffe00 parts
```

`spdhost-usb` lists devices with `termux-usb -l`, asks for permission with
`-r`, and passes the descriptor in `TERMUX_USB_FD` (`termux-usb -E`). If more
than one device is plugged in, pass the path:

```sh
spdhost-usb /dev/bus/usb/001/002 -- read-part boot 0 64M boot.img
```

Grant the permission dialog once, unplug, then run the command and plug the
target in while holding its download-mode keys. The BootROM window is a few
seconds, and the first dialog usually consumes it.

The host phone must be the USB host (OTG). An adaptor that forces host mode
is more reliable than a plain USB-C cable.

## Command order

`fdl` the first time speaks BootROM: line-state control transfer, CRC-16
check-baud, connect, download, execute, then check-baud again with the
additive checksum. `fdl` the second time downloads the next loader on that
same connection and executes it.

`ping` is only a handshake. `ping --fdl` uses the FDL checksum instead of
CRC-16, for a device that is already in a loader. Partition commands assume
you are already talking to a loader that understands them.

`parts` prints `index name units`. The unit is whatever that loader reports
(often a sector count, not a byte size).

## What this is not

Not a replacement for the full `sfd_tool` GUI, PAC flashing, or raw-data
mode. Not a program that survives a USB reset. If a loader you use
re-enumerates between FDL1 and FDL2, stop after the first `fdl` and say so;
the missing piece is a reconnect helper, not a chroot.
