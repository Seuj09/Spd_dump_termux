# spdhost

A small Unisoc download-mode client. One process, one USB device, no GUI.
It talks to a phone in BootROM or FDL over libusb bulk transfers.

This tree is original. It is not a fork of either repository below, and it
does not carry their code. Read them when you want to see how someone else
solved a piece. Do not paste them in here: `sfd_tool` is GPL-3.0-or-later.

## What the references are for

[C-Hidery/sfd_tool](https://github.com/C-Hidery/sfd_tool) is the one that
actually works. The part worth copying as an idea, not as source:

- On Android, do not open `/dev/bus/usb`. `termux-usb` already opened it.
- On current libusb, pass `LIBUSB_OPTION_NO_DEVICE_DISCOVERY` to
  `libusb_init_context`, then `libusb_wrap_sys_device` on that descriptor.
  `libusb_set_option` plus `libusb_init` is unspecified for this flag.
- After the first loader is executed, send check-baud again. Phones answer
  one `0x7e`. Older loaders answer four. If the phone leaves the bus,
  the old descriptor is dead: ask `termux-usb` for a new one instead of
  scanning `/dev/bus/usb`.

[itz-termux-dev/SPDClient-NoRoot-Termux](https://github.com/itz-termux-dev/SPDClient-NoRoot-Termux)
is the negative reference. The README describes FDL1, FDL2, HDLC, and a
BootROM exploit. The code does none of that: it `write()`s a usbfs descriptor
(that node is ioctl-based, not a byte stream), the frame has no length or
checksum, and the exploit function sends 256 zero bytes. Do not start from it.

spdhost also does not implement bootloader exploits, AVB or verity changes,
or FRP-specific commands. `write-part` and `erase-part` are ordinary partition
I/O. They ask you to type `yes` unless you pass `--yes`.

## Build

Build inside `no-root/`. This is not the rooted chroot: do not run these
commands in Ubuntu, and do not follow `root/setup.sh` for this binary.
`make` produces `./spdhost` for the machine you are on. A binary built on a
PC will not run on the phone, and the other way around.

`./spdhost --self-test` prints `self-test ok` when the compile and the
framing check worked. That check does not open USB and does not need a phone.

### Termux, no root

Install [Termux](https://f-droid.org/packages/com.termux/) and
[Termux:API](https://f-droid.org/packages/com.termux.api/) from F-Droid.
The Play Store Termux package is an old build and will not work.
Termux:API has to be the app as well as the `termux-api` package, and the
two apps must be signed together, which they are when both come from F-Droid.

In Termux, not in a chroot:

```sh
pkg update
pkg install git clang make pkg-config libusb termux-api
git clone https://github.com/Seuj09/Spd_dump_termux.git
cd Spd_dump_termux/no-root
make
./spdhost --self-test
cp spdhost "$PREFIX/bin/"
cp scripts/spdhost-usb "$PREFIX/bin/"
```

`$PREFIX` is already set by Termux. It is
`/data/data/com.termux/files/usr`. The `cp` lines are what puts `spdhost`
and `spdhost-usb` on `PATH`. Without them, `spdhost-usb` in the next section
will not be found.

`clang` is the compiler. `make` runs the Makefile. `pkg-config` and `libusb`
are how the build finds the USB library. `termux-api` is the command-line
bridge to the Termux:API app. None of these are `apt` packages. Termux's
`apt` is `pkg`.

### Linux PC

Debian, Ubuntu, and derivatives:

```sh
sudo apt update
sudo apt install git build-essential pkg-config libusb-1.0-0-dev
git clone https://github.com/Seuj09/Spd_dump_termux.git
cd Spd_dump_termux/no-root
make
./spdhost --self-test
```

Fedora and RHEL:

```sh
sudo dnf install git gcc make pkgconf-pkg-config libusb1-devel
git clone https://github.com/Seuj09/Spd_dump_termux.git
cd Spd_dump_termux/no-root
make
./spdhost --self-test
```

Leave the binary in this directory and run it as `./spdhost`. There is no
`spdhost-usb` step on a PC. The PC must be allowed to open the device node
itself (root, or a udev rule for vendor `1782`). See the desktop commands
below.

## Run

On a Linux PC that can open the device node (root, or a udev rule for
`1782:4d00`):

```sh
./spdhost fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR parts
./spdhost read-part boot 0 64M boot.img
```

`FDL1_ADDR` and `FDL2_ADDR` are the load addresses for that chip. They are
not universal. Take them from the same per-device FDL pair the rooted menu
uses. This tool does not ship loaders. A wrong address is how phones get
bricked. The loader download itself is sent in 528-byte chunks. `--step`
changes partition reads and writes only.

On the phone, after the Termux build and the `cp` into `$PREFIX/bin`:

```sh
spdhost-usb fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR parts
```

`spdhost-usb` lists devices with `termux-usb -l` and asks for permission
with `-r`. It does not put the spdhost arguments in the `termux-usb -e`
string. Termux runs that string by word-splitting, not as a shell command,
so a filename with a space would be split and shell quoting would not be
honored. The wrapper writes a small script and passes that script's path.
`-E` puts the descriptor in `TERMUX_USB_FD`. If more than one device is
plugged in, pass the path:

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
additive checksum. `fdl` the second time downloads the next loader and
executes it.

`ping` is only a handshake. `ping --fdl` uses the FDL checksum and marks
the session as already in FDL1, so a following `fdl` sends the second
loader instead of talking to BootROM again. Partition commands assume you
are already talking to a loader that understands them.

If execute makes the phone drop off the bus, spdhost closes the dead
handle and reopens. On Termux that means calling `termux-usb` again and
receiving the new descriptor over a socket. On the desktop it scans for
the same vendor and product. The vendor must stay `1782`. The product id
may change after a loader starts; a Termux reopen accepts that, a desktop
reopen still wants the original `--pid`. A reset during `read-part` or
`write-part` aborts that command instead of resending the chunk.

`parts` prints `index name units`. The unit is whatever that loader reports
(often a sector count, not a byte size).

## What this is not

Not a replacement for the full `sfd_tool` GUI, PAC flashing, or raw-data
mode. Reopen covers a USB reset between loader stages. It does not resume
a partition read or write that was cut in half.
