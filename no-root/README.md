# spdhost

> **Also available:** full TomKing `spd_dump` for Termux under
> [`spd_dump/`](spd_dump/) ([TERMUX.md](spd_dump/TERMUX.md)). Prebuilt arm32:
> release [`spd_dump-termux`](https://github.com/Seuj09/Spd_dump_termux/releases/tag/spd_dump-termux).


A small Unisoc download-mode client. One process, one USB device, no GUI.
It talks to a phone in BootROM or FDL over libusb bulk transfers.

Prebuilt static binaries, built on amd64 and checked under emulation, are
on the
[spdhost-source](https://github.com/Seuj09/Spd_dump_termux/releases/tag/spdhost-source)
release:

- `spdhost-arm32` for `uname -m` of `armv7l` or `armv8l`
- `spdhost-arm64` for `uname -m` of `aarch64`

They already contain libusb. You do not compile, and you do not install the
`libusb` package for these. Copy the one that matches the host phone:

```sh
uname -m
# arm32 host:
curl -L -o spdhost https://github.com/Seuj09/Spd_dump_termux/releases/download/spdhost-source/spdhost-arm32
chmod +x spdhost
./spdhost --self-test
cp spdhost "$PREFIX/bin/"
```

Use `spdhost-arm64` instead of `spdhost-arm32` when `uname -m` prints
`aarch64`. An arm64 file will not start on an arm32 phone.

After the reboot-recovery/fastboot change, both prebuilts must be
rebuilt from the same `no-root/src` (do not copy a binary across arches).
Cross-build recipe (musl + static libusb) is in the PR that lands those
commands; native `make` on each Termux host also works.

The same release also has `spdhost-source-arm32-arm64.zip`: the guide,
`scripts/menu.sh`, the C sources, and the ums9230 Infinix loaders. Use the
zip when you want to compile on the phone. The prebuilt is the file to run.

## misc BCB images (phone data, not host ISA)

`no-root/misc/` ships opaque 2048-byte Android bootloader control block
images for writing to partition `misc` at offset 0. They are **target phone
BCB**, not host-architecture binaries and not chip FDL loaders. The same
files work on arm32 and arm64 Termux hosts.

| File | Contents | sha256 |
|------|----------|--------|
| `misc/misc-recovery.bin` | `boot-recovery` @0 | `7b3d5382b8a753269520c60f01124f5dcea1a3c2e2e8c304623a46df79d046aa` |
| `misc/misc-fastbootd.bin` | + `recovery\n--fastboot\n` @0x40 | `d5e5251516f466735c7bdd54b470902260bfc70c3d1aa7fe7b0092d76413ac26` |
| `misc/misc-wipe.bin` | + `recovery\n--wipe_data\n` @0x40 | `bd6b67e852d6072e6fb87040f2ac40216d5b661b7fa661e7024569ecf8ddb3a7` |

Each file is exactly 2048 (`0x800`) bytes. Do not write more than that at
offset 0: A/B `bootloader_control` lives at misc offset `0x800`. Do not
`erase-part misc` as a shortcut.

### reboot-recovery / reboot-fastboot

After two matching `fdl` loaders (FDL2), these commands synthesize the same
2048-byte BCB TomKing uses, write exactly those bytes to partition `misc`,
then `reset`:

```sh
spdhost-usb fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR reboot-recovery
spdhost-usb fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR reboot-fastboot
```

They ask you to type `yes` unless you pass `--yes` (CLI automation only).
`scripts/menu.sh` never passes `--yes` for reboot or misc writes.
The menu's own typed `yes` (it shows the sha256 of the bytes) is the gate: it then
passes `--confirm-token <sha256>`, and spdhost writes misc only if the bytes it is
about to send hash to exactly that value (one misc write per session). Without a
token, spdhost prompts on `/dev/tty` and accepts `yes` with trailing CR/LF/spaces.
A 2048-byte BCB is one MIDST (`--step` is forced to 0x1000 for that write).
Like spd_dump, spdhost stops the command list after `reset`, `power-off` or
`reboot-*` succeeds.

`reboot-*` and `write-part misc` read the whole misc partition once before
writing, unless this same session already ran `misc-backup`. The automatic
copy is `misc-before-YYYYMMDD-HHMMSS.img` in the current directory. After the
write, spdhost reads misc back: the new bytes must match and the rest must be
unchanged, or it does not reset. `write-part misc` accepts only a 2048-byte
BCB or a file the size of the whole partition (run `parts` first so that size
is the live one).

Guard a misc write with `misc-backup FILE` on the same line, after `parts`,
when you want the copy at a chosen path:

```sh
spdhost-usb fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR \
  parts backup/partition_list.txt misc-backup backup/misc-before.img reboot-recovery
```

`misc-backup` reads the whole of misc, writes FILE, and reads FILE back. If
any of that fails, spdhost stops before writing, even with `--keep-going`.
After a misc write (from `reboot-*` or `write-part misc`), spdhost reads misc
back. The written bytes must match and the rest must be unchanged, or spdhost
stops without resetting. The menu always does this and names the backup
`backup/misc-before-<time>.img`. Menu reboot `[6]` restores one.

**FDL must match the exact chip.** A wrong loader or address can brick the
phone. The shipped `fdl/ums9230/infinix/` pair is one example only.

### Menu wipe (BCB only)

Menu reboot option `[5]` writes `misc/misc-wipe.bin` then `reset`. Recovery
honors `--wipe_data` and erases userdata on the next boot. That menu
item does **not** erase `persist` or `userdata` itself. The separate
FRP command does back up and erase `persist`, and it is labeled dangerous.
Use only on a sacrificial device.

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

spdhost does not implement bootloader exploits and does not ship
`fdl2-cboot.bin`, `spl-unlock.bin`, or `gen_spl-unlock`. `verity`,
`frp-reset`, and `danger-erase` are labeled dangerous: `--yes` does not
authorize them. You type the word `dangerous` on the terminal, or pass
`--dangerous` yourself. The menu never passes `--dangerous`. `write-part`
and `erase-part` still ask you to type `yes` unless you pass `--yes`.

## Build

Build inside `no-root/`. This is not the rooted chroot: do not run these
commands in Ubuntu, and do not follow `root/setup.sh` for this binary.

The same source runs on arm32 and arm64. `make` compiles for the phone you
are typing on. There is no separate arm32 binary to download.

```sh
uname -m
```

`aarch64` is 64-bit. `armv7l` or `armv8l` is 32-bit. Both use the commands
below. `make` prints `spdhost: compiling for` and that same name. A binary
built on a 64-bit phone, or on a PC, will not start on a 32-bit phone.
Build it again on the host phone. The release zip's `spd_dump` is arm64
only. This tree replaces that for a 32-bit host.

### Cross-compiling for a phone (optional)

To build static ARM binaries on a PC instead of on the phone:

```sh
pip install ziglang            # C compiler with bundled musl, no Android NDK
sudo apt install git make autoconf automake libtool qemu-user
make cross-arm32               # armv7l / armv8l Termux
make cross-arm64               # aarch64 Termux
make cross                     # both, plus one zip with both trees
```

`make cross-arm32` writes `dist/arm32/`: static `spdhost` and `spd_dump`
(ARMv7-A, Thumb-2, VFPv3-D16 with NEON, no libc or libusb needed on the
phone) and `spdhost-arm32-static-<sha>.zip`. `make cross-arm64` writes the
same layout under `dist/arm64/` as `spdhost-arm64-static-<sha>.zip`
(aarch64 musl). `make cross` also writes
`dist/spdhost-arm32-arm64-static-<sha>.zip`, with `spdhost-arm32/` and
`spdhost-arm64/` inside it. Unzip the tree that matches `uname -m`. An
arm64 file will not start on an arm32 phone.

The script builds libusb 1.0.27 statically with `-D__ANDROID__`; that
define is required, otherwise `libusb_init` cannot find usbfs on a phone
and fails with `LIBUSB_ERROR_OTHER`. The build machine only runs emulated
smoke tests (`--self-test`, argument and descriptor error paths) when
`qemu-arm` or `qemu-aarch64` is installed; nothing here opens a USB
device. Test the result on the phone before publishing it.

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

Loaders must match the exact chip. This tree ships one example pair under
`fdl/ums9230/infinix/` (`fdl1-dl.bin` / `fdl2-dl.bin` for Infinix UMS9230).
Treat that pair as untrusted until you match it to your device's PAC or
known-good package. For any other chip, use the FDL1/FDL2 files and load
addresses from that model's package. `FDL1_ADDR` and `FDL2_ADDR` below are
placeholders unless you substitute real hex addresses (including the `0x`).
A wrong address or loader can brick the phone.

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
runs usually skip the dialog. Cold-unplug the target ≥5 s between sessions;
a successful hello once does not make later tries stickier without a replug.

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
On eMMC (ums9230) the units are KiB. spd_dump converts them with
`bytes = units << (20 - divisor)`: divisor starts at 10 and drops while any
non-zero entry is smaller than `1 << divisor`. `scripts/menu.sh` does the same
conversion before it dumps anything (see `backup/partition_bytes.txt`).

To dump a partition, add `read-part` on that same line. `NAME` is the name
from `parts`. `OFFSET` is where to start inside the partition (`0` is the
start). `SIZE` is how much to read. `OUT` is the file written on this phone.

```sh
spdhost-usb fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR \
  read-part boot 0 64M boot.img
```

`64M` is 64 mebibytes. `K` and `G` work the same way. A bare number or a
`0x` hex number is a byte count.

`write-part NAME FILE` writes one file. `misc` is only a 2048-byte BCB or
the whole partition (backup and read-back, see above). A name containing
`fixnv1` is sent with spd_dump's NV framing (checksum in the start packet),
not as a raw copy. `calinv` is skipped. `runtimenv` is written; spd_dump
erases that name instead. On a phone that is not A/B, a same-size `NAME_bak`
is written with a normal transfer. vbmeta flags are left as they are in the
file. There is no `w_force` (that repartitions to rename a row, which can
brick the disk if it stops halfway).

`write-parts DIR` (and `write-parts-a` / `write-parts-b`) is the restore
path. It writes `DIR/<partition>.img` after `parts`, skips the inactive
slot, then sets the active slot when the device is A/B. `super.img`
without `metadata.img` erases `metadata` when that name is in the live
table. `write-files DIR` is the flash path (release menu option 2): every
named image is written, including an inactive `_a` or `_b` file. It does
not erase metadata and does not change the slot. A file whose name is not
on the phone is skipped, and so is a broken `fixnv1` image; the other
files are still written. An empty file, or one larger than its partition,
stops the plan before anything is sent. `splloader` is written up to the
live row size. With no splloader row the file is sent whole; a dump of
splloader is still 256 KiB. A sparse image (the file starts with
`0xED26FF3A`) is sent as that container, and each chunk may wait up to
100 seconds. The scan includes every regular file; spd_dump's directory
loop skips one entry. Junk names (`*.txt`, `SHA256SUMS`, `misc-slotinfo`,
`misc-before-*`, `*_bak`) are skipped.

`repartition FILE.xml` sends `<Partition id="name" size="N"/>` rows
(`N` is the XML integer, MiB, or `0xffffffff` for the last row). It asks
for `yes`. Run `parts` again afterwards; the cached table is stale.

`set-active a|b` rewrites the 32-byte slot block at misc offset `0x800` and
writes the whole misc image back, with the same backup and read-back.
`pack-slot a|b IN OUT` does that patch offline, with no phone attached.

`erase-part NAME` erases one partition. It still refuses `persist`,
`persist_a`, `persist_b`, `all`, `splloader`, and `splloader_bak`, even
with `--yes` or `--dangerous`.

`verity 0` writes `0x01` at offset `0x7B` of `vbmeta` (the active slot's
name when the unsuffixed row is absent). `verity 1` writes `0x00` at that
offset on `vbmeta`, `vbmeta_system`, `vbmeta_vendor`, `vbmeta_system_ext`,
`vbmeta_product`, and `vbmeta_odm`, and skips a name that is not on the
phone. This is the byte spd_dump writes. It is not the AVB flag at `0x78`.
The whole partition is read and written back. A row that does not cover
`0x7B`, or is over 64MB, is not written. Run `parts` first.

`frp-reset OUT` reads all of `persist` (or `persist_a` / `persist_b` for
the active slot) to OUT, checks the file size, then erases that partition.
A failed or short read does not erase. Over 512MB is refused. Run `parts`
first.

`danger-erase NAME` erases only `persist`, `persist_a`, `persist_b`,
`splloader`, or `splloader_bak`. A persist name that is not in the live
table is not erased. `splloader` is still sent when the table has no such
row, which is what the release unlock does.

Those three commands ignore `--yes`. Without a terminal they send nothing
unless you pass `--dangerous`.

`reboot-recovery` and `reboot-fastboot` write a 2048-byte BCB to `misc` then
reset (see misc section). Writes, erases, repartition, and reboot ask you to
type `yes`. `--yes` skips that prompt. Do not put `--yes` in front of the
device path. Options go before the commands:

The menu (`scripts/menu.sh`) flashes images from `input/` beside `fdl/`
in the unzipped package (or `$PWD/input` if the menu was copied somewhere
that has no `fdl/` next to it). The folder is created when the menu starts.
Name each file after the partition (`boot.img`, `vbmeta.img`). It can also restore a backup
folder, repartition, set the slot, and dump the imei set (`miscdata`,
`prodnv`, `l_fixnv1`, `l_fixnv2`, `l_runtimenv1`, `l_runtimenv2`). Extra menu items
for verity, FRP reset, and bootloader unlock are labeled DANGEROUS and ask
you to type the word `dangerous`. Yes does not start them. Unlock sends
nothing until it can see `fdl2-cboot.bin` and either `spl-unlock.bin` or
`gen_spl-unlock`. It looks in the current directory, in
`ums9230/infinix/` (where the release package keeps `fdl2-cboot.bin` next
to `fdl1-dl.bin`), and beside that package's `menu.sh` (where
`gen_spl-unlock` lives). Those unlock files are not in this tree. The
normal `fdl1-dl.bin` and `fdl2-dl.bin` pairs from the release menu are
shipped for ums9230 (Infinix, Itel, Realme, Tecno, plus the alternatif
models), ums512 (Infinix, Realme), and sc9863a (Itel, Realme). Menu option
3 selects one and sets that chip's FDL and exec addresses. Each chip's
primary exec stub and the hex-mode alternate are shipped with it, including
ums9230 `custom_exec_no_verify_65015f48.bin`.

```sh
spdhost-usb --yes fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR \
  write-part boot new-boot.img
```

The loader download is sent in 528-byte chunks. `--step` changes partition
reads and writes only, not the loader chunks. It takes decimal or `0x` hex.
Without `--step`, spdhost uses 4096, or 0xf800 (63488) once an `fdl` goes to
0x5500 or 0x65000800 (spd_dump's highspeed `blk_size`). It is an option, so it
goes before `fdl`:

```sh
spdhost-usb --step 1024 fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR \
  read-part boot 0 64M boot.img
```

`--keep-going` lets a batch of `read-part` commands carry on after one fails
(READ_START refused, or an error reply mid-read, like spd_dump's
`dump_partition`). The failures are listed at the end and the exit status is 1.
USB timeouts and a device reset still stop the run. The menu's `all` and
`all_lite` use it, check that every file has the expected byte size, rename
short files to `NAME.img.partial`, and add the good ones to `backup/SHA256SUMS`.

`dump all|all_lite|NAME DIR` (after `parts` on the same line) takes names and
sizes from the table it just read. It converts units to bytes the same way
spd_dump does, reads misc for the active slot, adds `splloader` (256 KiB) to
`all`/`all_lite`, and skips blackbox/cache/userdata. A plain NAME gets the
active slot suffix. It writes `DIR/NAME.img`, or `NAME.img.partial` if the
read fails, plus `DIR/dump-manifest.txt`. When you answer y to "Refresh from
device?" the menu runs the refresh and the dump in one session this way, so
FDL2 is not lost in between.

If more than one USB device is plugged in, `spdhost-usb` stops and lists
them. Copy one path from `termux-usb -l` and put it first. The `--` is
required so the path is not read as an option:

```sh
termux-usb -l
spdhost-usb /dev/bus/usb/001/002 -- \
  fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR parts
```

`scripts/menu.sh` is a small test menu over the same commands. It will
not silently pick the shipped ums9230 Infinix loaders
(`fdl/ums9230/infinix/`, `fdl1-dl.bin` @ `0x65000800`, `fdl2-dl.bin` @
`0x9efffe00`). You must type `yes` to confirm that chip/model, or set
`SPDHOST_ALLOW_DEFAULT_FDL=1`, or use option 3 / a saved
`~/.spdhost-menu.conf`. Those files match the release menu's UMS9230 /
Infinix choice.

After a flash, restore, repartition, slot change, or dump, the menu runs
the same ending the release menu does: system (`reset`), recovery
(`reboot-recovery`), fastbootd (`reboot-fastboot`), or power off. Recovery
and fastbootd write the 2048-byte BCB after the other commands. The slot
bytes at misc+0x800 are not inside that write. Verity and FRP end with
`reset` on their own, after you type `dangerous`. Unlock is several
sessions. It reads splloader as 256 KiB, erases only after that backup
exists, and the last session loads `parts` before writing splloader and
the active uboot name back. A failed erase skips the unlock loader and
still writes that backup back.

Dump (option 1) fetches the live `parts` table into
`./backup/partition_list.txt` (name + size), prints it like the rooted
menu's LIST PARTISI, then resolves what you type to the closest name
(`boot.img` or `boot` → `boot_a` when that slot exists) and uses that
row's size for `read-part`. `all` / `all_lite` match the rooted menu
bulk dump (splloader, then everything except userdata/cache/blackbox;
`all_lite` also skips the inactive slot read from misc). Option 4 only refreshes the list. Reboot choices are
system (`reset`), recovery (`reboot-recovery`), fastbootd
(`reboot-fastboot`), power off, and optional wipe userdata via
`misc/misc-wipe.bin` (BCB + reset only; that path still does not erase
persist). Misc/reboot/wipe paths always use a typed confirm and never pass
`--yes`. The dangerous extra items never pass `--yes` or `--dangerous`;
spdhost asks for the word `dangerous` on the terminal again.

Option 5, smoke test, is a safe, read-only check tuned for this release:
`--self-test`, an environment check (`termux-usb`, `termux-toast`/
`termux-vibrate`), a one-screen summary of the current BootROM-hello
defaults (ramp, auto-wall, `clear_halt` placement, Ctrl-C handling), and —
only if `termux-usb -l` already lists a device — an optional short,
bounded `ping` probe (4 tries, 6s wall, trace on) followed by a second
probe to confirm the USB interface wasn't left claimed. It never runs
`fdl`, a partition write, an erase, or a reboot. You can press Ctrl-C
during the probe to test the clean-stop behaviour described above; the
probe runs under `set -m` so the interrupt only reaches it, not the menu
script, and the follow-up busy-check still runs afterward either way.

```sh
cp scripts/menu.sh "$PREFIX/bin/"
menu.sh
```

Unzipped `no-root/` also works without copying into `$PREFIX/bin`: after
`make` (or with a Release prebuilt `spdhost` in the package root), run
`bash scripts/menu.sh` from the package root or from `scripts/`.

Menu sessions always pass `--timeout` (default 3000 ms; override with
`SPDHOST_TIMEOUT`) and `--verbose` when `SPDHOST_VERBOSE=1`. The CLI binary
default timeout stays 1000 ms.

```sh
SPDHOST_TIMEOUT=5000 SPDHOST_VERBOSE=1 bash scripts/menu.sh
spdhost-usb --timeout 5000 --verbose ping
```

### BootROM hello debug

Stay in the package root so `scripts/spdhost-usb` finds `./spdhost`. Set
`SPDHOST_BROM_TRACE=1` so claim→try breadcrumbs print (`brom: open/claim`,
`brom: line-state done`, `brom: try N`). The host wrapper also prints
always-on thin USB timing lines (no env needed): `usb: listed $dev @Xms`,
`usb: termux-usb -e start @Yms`, `usb: child start fd=N @Zms`.

A/B smoke menu: `./scripts/spdhost-ab-menu.sh` (or the release
`spdhost-ab-menu.sh`). Arm **2** (`SPDHOST_BROM_SETTLE_MS=0`) is a
reasonable first smoke when racing a short BootROM window; the default
settle remains **100** ms unless that env is set. Arms do not change
`SPDHOST_BROM_REACQ` (stays **0**); only arm **6** enables REACQ once.

Wrapper knobs that shrink Allow→spawn latency (hello framing unchanged):
`SPD_USB_ATTACHED_GRACE` (default **0**; was 3s), optional
`SPD_USB_SKIP_REQUEST=1` to omit `-r` on warm already-authorized runs
(default keeps `-r`). Correlate wrapper `usb:` millis with
`SPDHOST_BROM_TRACE=1` (`brom: open/claim` → `brom: try 1`) to measure
list→Allow→spawn→try1.

#### Warm Allow / pre-grant recipe

First session: normal grant (default keeps `-r`). After Android has
authorized this host↔device pairing at least once, cold-unplug ≥5 s, then
skip the redundant `-r` to shrink Allow→spawn:

```bash
cd ~/spdhost-arm32   # or spdhost-arm64 / unzipped package root that contains ./spdhost + scripts/

# First session: normal grant (default keeps -r)
SPDHOST_BROM_TRACE=1 ./scripts/spdhost-usb --timeout 5000 --verbose ping

# After Android has authorized this host↔device pairing at least once:
# cold-unplug ≥5s, then skip redundant -r to shrink Allow→spawn:
SPD_USB_SKIP_REQUEST=1 SPDHOST_BROM_TRACE=1 \
  ./scripts/spdhost-usb --timeout 5000 --verbose ping
```

**Warn:** if the grant was never given, `SPD_USB_SKIP_REQUEST=1` will fail
open (permission denied / never started). Keep the default `-r` for a cold
first plug. Do not export `SPD_USB_SKIP_REQUEST=1` as a global default in
menus; use it only on the warm path after a successful Allow.

Baseline cold ping (same as above first session, with explicit timeout env):

```bash
cd ~/spdhost-arm32   # or spdhost-arm64 / unzipped package root that contains ./spdhost + scripts/

SPDHOST_TIMEOUT=5000 SPDHOST_VERBOSE=1 SPDHOST_BROM_TRACE=1 \
  ./scripts/spdhost-usb --timeout 5000 --verbose ping
```

`--timeout 5000` still applies to CONNECT / bulk / loader paths. BootROM
hello send/recv uses `SPDHOST_BROM_TIMEOUT` only (default **3000**), not
`max(--timeout, BROM_TIMEOUT)`, so a larger global timeout no longer starves
the try budget under the wall.

Each try's own timeout now ramps from `SPDHOST_BROM_TIMEOUT_MIN` (default
**250** ms) up to `SPDHOST_BROM_TIMEOUT` over `SPDHOST_BROM_TIMEOUT_RAMP`
tries (default **6**), then holds at the ceiling. A try that times out at
250ms costs far less of the wall budget than one at 3000ms, so more tries
land inside a short BootROM listen window before giving up. Every BootROM
start prints one always-on line like
`brom: hello hello_to=250..3000(x6) wall=43750(auto) tries=15`.
`SPDHOST_BROM_NO_RAMP=1` disables the ramp (every try uses the ceiling,
matching pre-ramp behaviour) for phones where even the first try needs the
full timeout.

If `SPDHOST_BROM_WALL_MS` is **not** set, the wall is now computed from
`tries` and the ramp so all of them actually get attempted — previously the
fixed 20000ms default only fit ~5–6 of the documented 15 tries and the rest
were silently never sent. Set `SPDHOST_BROM_WALL_MS` explicitly to override
this (it always wins over the auto value; still capped at 120000).

Optional sfd-aligned settle=0 probe (`sfd_tool` has no post-line-state
settle; menu arm 2). Keeps hello_to at 3000 via `--timeout 3000` /
`SPDHOST_TIMEOUT`, raises the wall to 30s for denser tries, and skips the
100 ms settle. Default settle remains 100 unless env set. For even denser
tries add `SPDHOST_BROM_PAUSE_MS=0` (optional):

```bash
cd ~/spdhost-arm32
SPDHOST_BROM_SETTLE_MS=0 SPDHOST_BROM_WALL_MS=30000 \
  SPDHOST_TIMEOUT=3000 SPDHOST_VERBOSE=1 SPDHOST_BROM_TRACE=1 \
  ./scripts/spdhost-usb --timeout 3000 --verbose ping
```

Follow-up list-parts smoke (Infinix UMS9230 + shipped FDL only; after ping
success look for `version:SPRD3` or similar `version:` line):

```bash
cd ~/spdhost-arm32
SPDHOST_TIMEOUT=5000 SPDHOST_VERBOSE=1 SPDHOST_BROM_TRACE=1 \
  ./scripts/spdhost-usb --timeout 5000 --verbose \
  fdl ./fdl/ums9230/infinix/fdl1-dl.bin 0x65000800 \
  fdl ./fdl/ums9230/infinix/fdl2-dl.bin 0x9efffe00 \
  parts ./backup/partition_list.txt
```

BootROM hello (`check-baud` with raw `0x7e`) also reads optional env knobs
(defaults are patient; shrink them to bisect): `SPDHOST_BROM_TRIES` (15),
`SPDHOST_BROM_PAUSE_MS` (500), `SPDHOST_BROM_TIMEOUT` (3000; the ceiling a
try ramps up to — BootROM hello only, not max'd with `--timeout`),
`SPDHOST_BROM_TIMEOUT_MIN` (250; ramp floor), `SPDHOST_BROM_TIMEOUT_RAMP` (6;
tries to reach the ceiling over), `SPDHOST_BROM_NO_RAMP` (0; `1` = every try
uses the ceiling, old behaviour), `SPDHOST_BROM_WALL_MS` (auto-computed from
`tries` + the ramp unless set explicitly; explicit always wins, capped at
120000), `SPDHOST_BROM_TRACE` (1 = breadcrumb timestamps even
without `--verbose`; open/claim, device speed/endpoints, clear_halt,
line-state done, try N of M with its timeout, wall, settle, reacq),
`SPDHOST_BROM_REACQ` (default **0** = off — Termux-safe; no mid-ping
USB close/reopen / second Allow dialog. Soft OUT TIMEOUT retries + wall stay
on the **same FD**. Set to `1`/`2` for soft same-handle settle+retry after
try/wall miss — still no termux-usb reopen; max `2`),
`SPDHOST_BROM_SETTLE_MS` (default **100** ms pause after line-state),
`SPDHOST_BROM_DRAIN` (default **0**; `1` = short bulk-IN drain after settle),
`SPDHOST_NO_CLEAR_HALT` (default **0**; `1` = skip the `libusb_clear_halt` on
both bulk endpoints that now runs right after line-state, before settle, on
the BootROM-hello path only — not on every open/reacquire, including
post-FDL EXEC ones, which it has nothing to do with. Set this to check
whether a data-toggle reset changes anything for your phone).
Cold-unplug ≥5 s between sessions; success once ≠ stickier later without a
replug. BootROM OUT `LIBUSB_ERROR_TIMEOUT` during check-baud is soft (same as
recv timeout): remaining tries continue on the same handle; it does not abort
the session. A forced USB reacquire mid-hello was removed: it hit
`LIBUSB_ERROR_BUSY` and a second termux-usb Allow. If claim returns BUSY
(leftover claim after a prior unclean exit — Termux:API keeps the FD), stderr
prints an unplug/replug hint; spdhost also `libusb_release_interface` before
close and on atexit so the next run can claim cleanly. `spdhost` now also
traps SIGINT/SIGTERM: Ctrl-C during a hello, read-part, write-part or
erase-part stops that operation at its next checkpoint and exits normally
(so the interface-release above actually runs), instead of the process dying
outright and leaving the interface claimed for the next run. A second
Ctrl-C, if the first one is somehow not enough, restores the default action.

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
receiving the new descriptor over a socket (`grab_termux` /
`spd_usb_reacquire` in `src/usb.c`). On the desktop it scans for vendor
`1782` and accepts any product id, logging the new PID. The vendor must
stay `1782`. The product id may change after a loader starts. A reset
during `read-part` or `write-part` aborts that command instead of
resending the chunk.

#### Post-FDL reconnect SM (P4 — deferred this release)

**Not landed / not hardened in this tip.** Full post-bus-leave
re-`termux-usb` reconnect state machine is held until the BootROM→FDL1
gate is green (plan P4). Existing reopen helpers remain for loader-stage
drop-offs; they are **not** a mid-BootROM hello reopen (REACQ default
stays **0**; never close+reopen mid-`check-baud`).

Intended SM (docs-only stub; do not expect this release to implement it):

1. On `gone` / post-EXEC bus leave → close the dead handle.
2. Wait for a **unique** Spreadtrum node (`vendor 1782`, prefer product
   `4d00` when several appear during renumeration).
3. Re-run `termux-usb` (fresh Allow / FD) and wrap the new descriptor.
4. **Refuse** multi-device auto-pick — require an explicit
   `/dev/bus/usb/N/M` (or a single remaining node).
5. **Never** mid-hello: do not reopen while BootROM `check-baud` tries
   are in flight on the same session.

Until P4 ships, treat post-EXEC reconnect failures as expected on short
BootROM windows; re-prove hello with menu `1`/`2` (or warm
`SPD_USB_SKIP_REQUEST=1`) before retrying FDL smoke.

`parts` prints `index name units`. The unit is whatever that loader reports
(often a sector count, not a byte size).

## What this is not

Not a replacement for the full `sfd_tool` GUI, PAC flashing, or raw-data
mode. Reopen covers a USB reset between loader stages. It does not resume
a partition read or write that was cut in half.
