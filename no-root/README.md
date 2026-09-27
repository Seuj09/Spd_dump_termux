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
and `spdhost-usb` on `PATH`. `cp` prints nothing when it works. Check:

```sh
command -v spdhost
command -v spdhost-usb
```

Both must print a path under `/data/data/com.termux/files/usr/bin/`. If
either prints nothing, run the two `cp` lines again from `no-root/`.

`clang` is the compiler. `make` runs the Makefile. `pkg-config` and `libusb`
are how the build finds the USB library. None of these are Debian `apt`
packages. In Termux, `apt` and `pkg` are the same tool.

`pkg install termux-api` does not install the Termux:API app. That package
is only the `termux-usb` command. The app is a separate F-Droid install,
and without it `termux-usb` cannot show the USB permission dialog or open
the phone. Install both before the run section:

- [Termux](https://f-droid.org/packages/com.termux/)
- [Termux:API](https://f-droid.org/packages/com.termux.api/)

They have to come from F-Droid, not the Play Store. The Play Store Termux
build is old, and the app and the package must be signed by the same key.

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

One line is one session. Every command on that line shares the USB
connection, and the commands run from left to right. When the line exits,
the connection is gone. A later `read-part` does not remember an earlier
`fdl`. Put the loaders and the partition command on the same line.

This repo does not ship loaders. You need the FDL1 file, the FDL2 file, and
the load address for each, for that exact chip. Use the same pair the rooted
menu uses for that model. `FDL1_ADDR` and `FDL2_ADDR` below are not real
addresses. Replace them with the hex address from that package, including
the `0x`. A wrong address can brick the phone.

Run the command from the directory that contains the loader files, or pass
full paths. Names like `fdl1.bin` only work when those files are in the
current directory.

The phone running Termux is the USB host. Use an OTG adapter that forces
host mode. A plain USB-C cable often leaves this phone as the device, and
then nothing appears. Power the target off. Type the command and press
Enter, then hold the target's download-mode keys and plug it in. This phone
shows a USB permission dialog. Allow it. The first dialog usually spends
the few seconds the BootROM stays up. Unplug, run the same command again,
and plug in as soon as you have pressed Enter. After the first allow, later
runs usually skip the dialog.

On Termux:

```sh
spdhost-usb fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR parts
```

Read that line as five steps:

1. `fdl fdl1.bin FDL1_ADDR` sends the first loader to BootROM and executes it.
2. `fdl fdl2.bin FDL2_ADDR` sends the second loader to the first and executes it.
3. `parts` prints the partition list from the second loader.

`parts` prints one line per partition: `index name units`. `units` is
whatever that loader reports. It is often a sector count, not a size in
bytes.

To dump a partition, add `read-part` on that same line. `NAME` is the name
from `parts`. `OFFSET` is where to start inside the partition (`0` is the
start). `SIZE` is how much to read. `OUT` is the file written on this phone.

```sh
spdhost-usb fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR \
  read-part boot 0 64M boot.img
```

`64M` is 64 mebibytes. `K` and `G` work the same way. A bare number or a
`0x` hex number is a byte count.

`write-part NAME FILE` writes a file onto a partition. `erase-part NAME`
erases one. Both stop and ask you to type `yes`. `--yes` skips that prompt.
Do not put `--yes` in front of the device path. Options go before the
commands:

```sh
spdhost-usb --yes fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR \
  write-part boot new-boot.img
```

The loader download is sent in 528-byte chunks. `--step` changes partition
reads and writes only, not the loader chunks. It is also an option, so it
goes before `fdl`:

```sh
spdhost-usb --step 1024 fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR \
  read-part boot 0 64M boot.img
```

If more than one USB device is plugged in, `spdhost-usb` stops and lists
them. Copy one path from `termux-usb -l` and put it first. The `--` is
required so the path is not read as an option:

```sh
termux-usb -l
spdhost-usb /dev/bus/usb/001/002 -- \
  fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR parts
```

On a Linux PC that can open the device node (root, or a udev rule for
vendor `1782`, product `4d00`), drop `spdhost-usb` and call the binary
directly. The command words after that are the same:

```sh
./spdhost fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR parts
./spdhost fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR \
  read-part boot 0 64M boot.img
```

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
