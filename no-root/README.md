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

**FDL must match the exact chip.** A wrong loader or address can brick the
phone. The shipped `fdl/ums9230/infinix/` pair is one example only.

### Menu wipe (BCB only)

Menu reboot option `[5]` writes `misc/misc-wipe.bin` then `reset`. Recovery
honors `--wipe_data` and erases userdata on the next boot. spdhost does
**not** erase the `persist` or `userdata` partitions itself (unlike some
rooted wipe flows). Use only on a sacrificial device.

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
erases one. `reboot-recovery` and `reboot-fastboot` write a 2048-byte BCB
to `misc` then reset (see misc section). All of these stop and ask you to
type `yes`. `--yes` skips that prompt. Do not put `--yes` in front of the
device path. Options go before the commands:

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

`scripts/menu.sh` is a small test menu over the same commands. It will
not silently pick the shipped ums9230 Infinix loaders
(`fdl/ums9230/infinix/`, `fdl1-dl.bin` @ `0x65000800`, `fdl2-dl.bin` @
`0x9efffe00`). You must type `yes` to confirm that chip/model, or set
`SPDHOST_ALLOW_DEFAULT_FDL=1`, or use option 3 / a saved
`~/.spdhost-menu.conf`. Those files match the release menu's UMS9230 /
Infinix choice.

Dump (option 1) fetches the live `parts` table into
`./backup/partition_list.txt` (name + size), prints it like the rooted
menu's LIST PARTISI, then resolves what you type to the closest name
(`boot.img` or `boot` → `boot_a` when that slot exists) and uses that
row's size for `read-part`. `all` / `all_lite` match the rooted menu
bulk dump (skip userdata/cache/blackbox; `all_lite` also skips `_b`
when `_a` exists). Option 4 only refreshes the list. Reboot choices are
system (`reset`), recovery (`reboot-recovery`), fastbootd
(`reboot-fastboot`), power off, and optional wipe userdata via
`misc/misc-wipe.bin` (BCB + reset only). Misc/reboot/wipe paths always use
a typed confirm and never pass `--yes`. It does not unlock or flash a
partition you did not name.

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
the try budget under the wall. Every BootROM start prints one always-on line
like `brom: hello hello_to=3000 wall=20000 tries=15`. With defaults
(`hello_to=3000`, pause 500, wall **20000**) expect ~5–6 full tries before
the wall; for ≥8 tries set `SPDHOST_BROM_WALL_MS=30000` (or similar). There
is no auto-scaling of the wall.

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
`SPDHOST_BROM_PAUSE_MS` (500), `SPDHOST_BROM_TIMEOUT` (3000; BootROM hello
only — not max'd with `--timeout`), `SPDHOST_BROM_WALL_MS` (**20000**; for
≥8 tries use ≈30000), `SPDHOST_BROM_TRACE` (1 = breadcrumb timestamps even
without `--verbose`; open/claim, line-state done, try N of M, wall, settle,
reacq), `SPDHOST_BROM_REACQ` (default **0** = off — Termux-safe; no mid-ping
USB close/reopen / second Allow dialog. Soft OUT TIMEOUT retries + wall stay
on the **same FD**. Set to `1`/`2` for soft same-handle settle+retry after
try/wall miss — still no termux-usb reopen; max `2`),
`SPDHOST_BROM_SETTLE_MS` (default **100** ms pause after line-state),
`SPDHOST_BROM_DRAIN` (default **0**; `1` = short bulk-IN drain after settle).
Cold-unplug ≥5 s between sessions; success once ≠ stickier later without a
replug. BootROM OUT `LIBUSB_ERROR_TIMEOUT` during check-baud is soft (same as
recv timeout): remaining tries continue on the same handle; it does not abort
the session. A forced USB reacquire mid-hello was removed: it hit
`LIBUSB_ERROR_BUSY` and a second termux-usb Allow. If claim returns BUSY
(leftover claim after a prior unclean exit — Termux:API keeps the FD), stderr
prints an unplug/replug hint; spdhost also `libusb_release_interface` before
close and on atexit so the next run can claim cleanly.

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
