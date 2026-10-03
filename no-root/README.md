# spdhost

A small Unisoc/Spreadtrum download-mode client: one process, one USB device
per run, no GUI. It talks to a phone in BootROM or FDL over libusb bulk
transfers. On a phone (Termux, no root) the `spdhost-usb` wrapper takes the
descriptor from `termux-usb`; on a PC it opens the device node itself.

Prebuilt static binaries, libusb included, are on the
[spdhost-source](https://github.com/Seuj09/Spd_dump_termux/releases/tag/spdhost-source)
release:

- `spdhost-arm32` for `uname -m` of `armv7l` or `armv8l`
- `spdhost-arm64` for `aarch64`

Copy the one that matches the host phone. An arm64 binary will not start on
a 32-bit phone. The release zip's `spd_dump` is arm64 only; this tree
replaces it for a 32-bit host.

That release is the curated one. Builds made from each commit land as
pre-releases (`spdhost-exp-…`) on the [Releases
page](https://github.com/Seuj09/Spd_dump_termux/releases); see
[Cross-compiling](#cross-compiling-for-a-phone-optional).

```sh
uname -m
curl -L -o spdhost https://github.com/Seuj09/Spd_dump_termux/releases/download/spdhost-source/spdhost-arm64
chmod +x spdhost
./spdhost --self-test
cp spdhost "$PREFIX/bin/"
```

`spdhost-source-arm32-arm64.zip` on the same release has the source tree
(the C sources, `scripts/menu.sh`, the ums9230 Infinix loaders) for building
on the phone. The full TomKing `spd_dump` client is vendored separately
under [`spd_dump/`](spd_dump/) ([TERMUX.md](spd_dump/TERMUX.md)).

## Build

Build inside `no-root/`. This is not the rooted chroot: do not run these
commands in Ubuntu, and do not follow `root/setup.sh` for this binary.

One source tree builds for arm32 and arm64. `make` compiles for the phone
you are typing on and prints `spdhost: compiling for`. A binary built on a
64-bit phone, or on a PC, will not start on a 32-bit phone.

### Termux, no root

Install [Termux](https://f-droid.org/packages/com.termux/) and
[Termux:API](https://f-droid.org/packages/com.termux.api/) from F-Droid. The
Play Store Termux is an old build and will not work. Termux:API must be
**both** the app and the `termux-api` package, and the two must be signed by
the same key, which they are when both come from F-Droid. Without the app,
`termux-usb` cannot show the USB permission dialog or open the phone.

In Termux, not in a chroot:

```sh
pkg update
pkg install git clang make pkg-config libusb termux-api
termux-setup-storage
git clone https://github.com/Seuj09/Spd_dump_termux.git
cd Spd_dump_termux/no-root
make
./spdhost --self-test
cp spdhost scripts/spdhost-usb "$PREFIX/bin/"
```

`termux-setup-storage` asks for Android's storage permission. Allow it: that
is what lets the menu read images you put on `/sdcard` and write dumps there
(see the folders paragraph under [The menu](#the-menu)). Skip it and the menu
still works, out of `input/` and `backup/` in this directory.

`$PREFIX` is already set by Termux (`/data/data/com.termux/files/usr`).
`command -v spdhost` and `command -v spdhost-usb` must both print a path
under `$PREFIX/bin/`. `clang` is the compiler, `libusb` is how the build
finds the USB library; in Termux `apt` and `pkg` are the same tool.
`./spdhost --self-test` prints `self-test ok` when the compile and the
framing check worked. It opens no USB and needs no phone.

### Linux PC

Debian/Ubuntu: `sudo apt install git build-essential pkg-config libusb-1.0-0-dev`
Fedora/RHEL: `sudo dnf install git gcc make pkgconf-pkg-config libusb1-devel`

Then `git clone`, `cd Spd_dump_termux/no-root`, `make`, `./spdhost --self-test`.
Leave the binary in that directory and run `./spdhost`; there is no
`spdhost-usb` step on a PC. The PC must be allowed to open the device node
(root, or a udev rule for vendor `1782`).

### Cross-compiling for a phone (optional)

```sh
pip install ziglang            # C compiler with bundled musl, no Android NDK
sudo apt install git make autoconf automake libtool qemu-user
make cross-arm32               # armv7l / armv8l Termux
make cross-arm64               # aarch64 Termux
make cross                     # both, plus one zip with both trees
```

Each writes static `spdhost` and `spd_dump` (no libc or libusb needed on the
phone) plus a zip under `dist/`. The script builds libusb 1.0.27 statically
with `-D__ANDROID__`; that define is required, otherwise `libusb_init`
cannot find usbfs on a phone and fails with `LIBUSB_ERROR_OTHER`. The build
machine only runs the emulated `--self-test` and argument error paths when
`qemu-arm`/`qemu-aarch64` is installed. **Test the result on the phone
before publishing it.**

CI does the same on every push to `main` or
`experiment/brom-hello-diagnostics` that touches `no-root/`, and on demand from
the Actions tab: `.github/workflows/build.yml` runs the test suite, then
`make cross`, then publishes both single-architecture zips and the combined one
as a pre-release tagged `spdhost-exp-<slug>-<short sha>`, with the commit and
the UTC build date in the description. It proves the binaries build and that
the emulated checks pass; it never runs them on a phone.

### Tests

`tests/*.sh`, one per area (`write-seq`, `menu-dump`, `dhtb-tools`,
`pac-tools`, …). Each builds its own binary and needs no device. Run
`bash tests/<name>.sh` from `no-root/`.

## Safety

**Loaders and addresses must match the exact chip.** A wrong `fdl1-dl.bin`,
`fdl2-dl.bin` or load address can brick the phone. The pair shipped under
`fdl/ums9230/infinix/` is one example; treat it as untrusted until it
matches your device's PAC or known-good package.

Three levels of gate, in increasing order:

| Gate | Covers | Notes |
|---|---|---|
| typed `yes` (or `--yes`) | `write-part`, `write-files`, `write-parts*`, `repartition`, `set-active`, `reboot-*`, `reset`, `power-off` | `--yes` is for CLI automation |
| the word `dangerous` (or `--dangerous`) | `verity`, `frp-reset`, `danger-erase` | `--yes` is **not** enough; without a terminal they send nothing unless `--dangerous` is passed |
| `--confirm-token SHA256` | every misc write | authorizes one misc write whose exact bytes hash to that value |

`erase-part` refuses `persist`, `persist_a`, `persist_b`, `all`, `splloader`
and `splloader_bak` outright, even with `--yes` or `--dangerous`.
`danger-erase` is the only way to erase the persist/splloader names, and it
takes them one at a time.

`scripts/menu.sh` never passes `--yes` or `--dangerous`. It takes its own
typed confirm, shows the sha256 of the bytes it is about to write, and
passes `--confirm-token`; spdhost then writes misc only if the bytes it is
about to send hash to exactly that value, once per session.

## Run

One line is one session. Every command on that line shares the USB
connection and they run left to right; when the line exits the connection is
gone. A later `read-part` does not remember an earlier `fdl`. Put the
loaders and the partition command on the same line, and run from the
directory that holds the loader files (or pass full paths).

The phone running Termux is the USB host, so use an OTG adapter that forces
host mode — a plain USB-C cable often leaves this phone as the device and
nothing appears. Power the target off, type the command, press Enter, then
hold the target's download-mode keys and plug it in. Allow the USB
permission dialog on this phone: the first one usually spends the few
seconds the BootROM stays up, so unplug, run the same command again, and
plug in as soon as you have pressed Enter. After the first allow later runs
usually skip the dialog. Cold-unplug the target ≥5 s between sessions.

```sh
spdhost-usb fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR parts
```

That line is three steps: send FDL1 to BootROM and execute it, send FDL2 to
FDL1 and execute it, then print the partition list. On a PC drop
`spdhost-usb` and call `./spdhost` directly.

### Commands

Handshake and loaders:

- `ping [--fdl]` — BootROM hello, or an FDL hello with `--fdl`.
- `fdl FILE ADDR` — send one loader and execute it. The first `fdl` talks to
  BootROM (CRC-16 framing), the second to FDL1 (additive checksum).
- `exec_addr ADDR [FILE]` — BootROM stage only, before the first `fdl`: send
  FDL1, then FILE at ADDR as a no-verify stub that starts FDL1 (spd_dump's
  `exec_addr`). `ADDR 0` disables it.

Partition table and reads:

- `parts [FILE]` — print `index name units`. The unit is whatever that
  loader reports (often sectors). On eMMC (ums9230) the units are KiB;
  convert with `bytes = units << (20 - divisor)`, where `divisor` starts at
  10 and drops while any non-zero entry is smaller than `1 << divisor`. The
  menu does this and writes `backup/partition_bytes.txt`.
- `check-part NAME` — print the byte size from the live table (0 when the
  name is absent). Needs `parts`.
- `read-part NAME OFF SIZE OUT` — `SIZE` may be `-` or `full` for the whole
  partition. `K`/`M`/`G` suffixes and `0x` hex work; a bare number is bytes.
  Needs `parts`.
- `dump all|all_lite|NAME DIR` — after `parts`, same session. `all` and
  `all_lite` take names and sizes from the table, add `splloader` (256 KiB),
  and skip blackbox/cache/userdata; `all_lite` also skips the inactive slot.
  Writes `DIR/NAME.img` (or `NAME.img.partial` on failure) and
  `DIR/dump-manifest.txt`.
- `dump preset_modem DIR` — every `l_*` and `nr_*` row, plus `misc` when the
  device is A/B.
- `dump preset_resign DIR` — `vbmeta`, `splloader`, `uboot`, `sml`,
  `trustos`, `teecfg`, `boot`, `recovery`, in spd_dump's index order.

Writes:

- `write-part NAME FILE` — one partition, one file. `misc` accepts a
  2048-byte BCB or a file the size of the whole partition. A name containing
  `fixnv1` uses spd_dump's NV framing (checksum in the start packet);
  `calinv` is skipped; `runtimenv` is written where spd_dump erases it. On a
  non-A/B phone a same-size `NAME_bak` is written too. vbmeta flags are left
  as they are in the file. There is no `w_force`.
- `write-parts DIR` — restore path: write `DIR/<name>.img` after `parts`,
  skip the inactive slot, then set the active slot when the device is A/B.
  `super.img` without `metadata.img` erases `metadata` when that row exists.
  `write-parts-a` / `write-parts-b` force that slot.
- `write-files DIR` — flash path (menu `[6]`): write every named image,
  including an inactive `_a`/`_b` file. Does not erase metadata and does not
  change the slot. A name that is not on the phone, or a broken `fixnv1`,
  is skipped and the rest still go. An empty file, or one larger than its
  partition, stops the plan before anything is sent. A sparse image (starts
  with `0xED26FF3A`) is sent as that container and each chunk may wait up to
  100 seconds. Junk names (`*.txt`, `SHA256SUMS`, `misc-slotinfo`,
  `misc-before-*`, `*_bak`) are skipped.
- `repartition FILE.xml` — `<Partition id="name" size="N"/>` rows, `N` in
  MiB or `0xffffffff` for the last row. Asks for `yes`. Run `parts` again
  afterwards; the cached table is stale.

Slots and misc:

- `set-active a|b` — rewrite the 32-byte slot block at misc `0x800` and
  write the whole misc image back (backup and read-back, below).
- `misc-backup FILE` — read all of misc to FILE and read it back. Any
  failure stops the session before a write, even with `--keep-going`.
- `reboot-recovery` / `reboot-fastboot` — synthesize the 2048-byte Android
  BCB, write exactly those bytes to `misc`, then `reset`. See
  [misc BCB images](#misc-bcb-images-phone-data-not-host-isa).
- `reset`, `power-off` (also `poweroff`).
- `chip-uid` — read-only.

Anything that writes misc reads the whole partition first, unless the same
session already ran `misc-backup`. The automatic copy is
`misc-before-YYYYMMDD-HHMMSS.img` in the current directory. After the write
spdhost reads misc back: the new bytes must match and the rest must be
unchanged, or it does not reset. Like spd_dump, the command list stops after
`reset`, `power-off` or `reboot-*` succeeds.

Dangerous:

- `verity 0|1` — write byte `0x7B` of `vbmeta`. `0` writes `0x01` (dm-verity
  off); `1` writes `0x00` on every `vbmeta*` name that exists. This is the
  byte spd_dump writes; it is **not** the AVB flag at `0x78`. The whole
  partition is read and written back, and a row that does not cover `0x7B`
  or is over 64MB is not written. Needs `parts`.
- `frp-reset OUT` — read all of `persist` (or `persist_a`/`persist_b` for
  the active slot) to OUT, check the size, then erase it. A failed or short
  read does not erase. Over 512MB is refused. Needs `parts`.
- `danger-erase NAME` — erase only `persist`, `persist_a`, `persist_b`,
  `splloader` or `splloader_bak`. A persist name that is not in the live
  table is not erased; `splloader` is still sent when the table has no such
  row, which is what the release unlock does.
- `erase-part NAME` — erase any other partition. Refuses `persist`,
  `persist_a`, `persist_b`, `all`, `splloader` and `splloader_bak` even with
  `--yes` or `--dangerous`; `danger-erase` is the way to those.

### Offline image tools

These open no USB and ignore the device options. Unlike the release tools
they never overwrite their input file:

```
spdhost gen-spl-unlock        IN OUT    patch a dumped splloader into an unlock image
spdhost gen-spl-unlock-legacy IN OUT    the same for an older SoC generation
spdhost gen-fdl1-dl           IN OUT    patch an fdl1 for download mode
spdhost chsize                IN OUT    cut a DHTB image to its real size
spdhost pack-slot a|b IN OUT            patch a misc image at 0x800 for that slot
spdhost unpac [-d DIR] {list|check|extract} FILE.pac [names]
```

The release's `gen_spl-unlock` writes a temp file, removes the input and
renames over it, so running it on `splloader.bin` destroys the dump it is
patching. The output bytes here are the same. The two unlockers NOP the
CVE-2022-38694 check sites in an AArch64 loader and print the size and how
many sites they patched; `gen-spl-unlock-legacy` is for a loader where the
first reports 0 sites. A file that is not a DHTB image, one whose header
offset is zero, and one the header declares shorter than the file are each
refused with the reason and nothing is written.

`unpac` reads a PAC: `list` prints one line per entry (index, id, name,
size, offset, flags), `check` verifies both CRC-16 headers and names the
wrong one (it still exits 0, like the vendor tool), and `extract` writes the
payloads to `DIR` (the current directory when `-d` is absent). Names are
`*` and `?` wildcards matched against the file name or the partition id; no
names means everything. An entry with an empty name, a zero offset or a
zero size is skipped, and an output name containing `/`, `\` or `:` is
refused rather than written. `spdhost unpac -d DIR extract FILE.pac '*'`
extracts everything.

### Options

Options go before the commands, and never in front of the device path.

```
--usb-fd N        adopt an already-open usbfs descriptor
--vid/--pid       desktop enumeration (default 1782:4d00)
--timeout MS      bulk timeout (default 1000)
--step N          partition chunk size, decimal or 0x hex
--no-line-state   skip the smartphone line-state control transfer
--keep-going      a failed read-part is logged and the next command runs
--yes             skip the typed yes for write/erase/repartition/reboot-*
--dangerous       authorize verity/frp-reset/danger-erase without a typed word
--confirm-token SHA256   authorize one misc write whose bytes hash to it
--verbose
--dry-run         no USB: fake replies, print each packet for sequence tests
--self-test       framing check, no device
```

`--step` defaults to 4096, or 0xf800 once an `fdl` goes to `0x5500` or
`0x65000800` (spd_dump's highspeed `blk_size`). Loader downloads are always
sent in 528-byte chunks; `--step` is for partition reads and writes only.
`--keep-going` lists the failures at the end and exits 1; USB timeouts and a
device reset still stop the run. The menu's `all`/`all_lite` use it, check
each file's size, rename short ones to `NAME.img.partial`, and add the good
ones to `backup/SHA256SUMS`.

If more than one USB device is plugged in, `spdhost-usb` stops and lists
them; copy a path from `termux-usb -l` and put it first, before the `--`:

```sh
spdhost-usb /dev/bus/usb/001/002 -- \
  fdl fdl1.bin FDL1_ADDR fdl fdl2.bin FDL2_ADDR parts
```

`TERMUX_USB_FD` (or `SPD_USB_FD`) is the same as `--usb-fd` when neither is
given.

## misc BCB images (phone data, not host ISA)

`no-root/misc/` ships opaque 2048-byte Android bootloader control block
images for partition `misc` at offset 0. They are **target phone BCB**, not
host-architecture binaries and not chip loaders; the same files work on
arm32 and arm64 Termux hosts.

| File | Contents | sha256 |
|------|----------|--------|
| `misc/misc-recovery.bin` | `boot-recovery` @0 | `7b3d5382b8a753269520c60f01124f5dcea1a3c2e2e8c304623a46df79d046aa` |
| `misc/misc-fastbootd.bin` | + `recovery\n--fastboot\n` @0x40 | `d5e5251516f466735c7bdd54b470902260bfc70c3d1aa7fe7b0092d76413ac26` |
| `misc/misc-wipe.bin` | + `recovery\n--wipe_data\n` @0x40 | `bd6b67e852d6072e6fb87040f2ac40216d5b661b7fa661e7024569ecf8ddb3a7` |

Each file is exactly 2048 (`0x800`) bytes. Do not write more than that at
offset 0 — A/B `bootloader_control` lives at `0x800` — and do not
`erase-part misc` as a shortcut. A 2048-byte BCB is written as one MIDST
(`--step` is forced to `0x1000` for that write).

`reboot-recovery` and `reboot-fastboot` synthesize the same BCB TomKing
uses after two matching loaders, write it to `misc`, then reset. They ask
you to type `yes` unless you pass `--yes` (CLI automation only); the menu
uses `--confirm-token` instead, as described above.

The reboot submenu under `[2]` also has `[5]` wipe userdata (writes
`misc/misc-wipe.bin` then `reset`; recovery honors `--wipe_data` and erases
userdata on the next boot) and `[6]` restore misc from one of the
`backup/misc-before-*.img` copies. The wipe item does **not** erase
`persist` or `userdata` itself — the separate FRP command does that, and it
is labeled dangerous. Use only on a sacrificial device.

## The menu

`scripts/menu.sh` is a front end over the same commands. Copy it into
`$PREFIX/bin/`, or run `bash scripts/menu.sh` from the package root (or from
`scripts/`) with a built or release-prebuilt `spdhost` in the package root.

```
[1] Dump partitions (one name, several names, all, all_lite, or imei)
[2] Reboot into a mode
[3] Change loader files (shipped models, or your own paths)
[4] List partitions only
[5] Smoke test (safe checks, no writes)
[6] Flash images from the flash folder (Download/, or input/ in the package)
[7] Restore a backup folder
[8] Repartition from XML
[9] Copy dumped images into the flash folder
[10] Extra (slot, hex mode, DANGEROUS unlock / verity / FRP)
[0] Quit
```

**On the first run the menu asks which loaders the phone uses**, before it
prints anything else:

```
Phone setup. Which loaders does this phone use?
[1] universal (generic ums9230; try this if you do not know the model)
[2] pick a shipped model by chip and brand
[3] type my own loader paths and addresses
[0] skip for now (menu [3] sets this later)
```

`[1]` is the answer when the model is unknown: `fdl/ums9230/universal/` holds
the generic ums9230 pair (`fdl1-dl.bin` @ `0x65000800`, `fdl2-dl.bin` @
`0x9efffe00`, exec stub `0x65015f08`). It still asks for `yes` before saving,
because a wrong chip or address can brick the phone. The prompt is skipped
when a complete loader config is already saved, when stdin is not a terminal
(so a script or a piped run is never blocked), and when
`SPDHOST_ALLOW_DEFAULT_FDL=1` applies the shipped ums9230 Infinix pair without
asking.

`[3]` selects a chip and sets its FDL and exec addresses. The shipped pairs
cover ums9230 (Infinix, Itel, Realme, Tecno, **universal** and the alternatif
models), ums512 (Infinix, Realme) and sc9863a (Itel, Realme), each with its
primary exec stub and hex-mode alternate. The addresses are a function of the chip,
so the saved config is checked against itself on every launch: a config
whose loaders are one chip's and whose addresses are another's is refused
with both names. Stale addresses are repaired from the chip, and an empty
`SOC` beside a loader path is filled in from the path rather than used as a
way around the check.

The dump folder is what `[1]` writes into and `[7]` restores from; the flash
folder is what `[6]` reads. `SHA256SUMS`, `dump-manifest.txt` and
`partition_list.txt` land in the dump folder too. `[9]` copies images from the
dump folder into the flash folder when the two are different folders.

**By default they are the same folder, and it is the phone's own Download
folder.** On Termux, after `termux-setup-storage` has been run and allowed:

```
/sdcard/Download    dumps land here (menu [1]); flashes read here (menu [6])
```

A dump is therefore immediately visible to a file manager or a browser
download, and the image you downloaded is already in the folder `[6]` flashes
from — there is nothing to move. Because one folder serves both directions,
`[9]` says so and does nothing rather than reporting an empty copy, `[6]`
never renames anything it finds there (a `boot.bin` is flashed as `boot`, the
file itself is untouched), and `[7]` will list any partition image you dropped
there to flash, which is expected.

The tool creates the folder on first run. Without storage permission it falls
back to `input/` and `backup/` inside the folder it was unzipped into — two
separate folders, where `[9]` still does the copying — and says which layout it
is using in the header. Extra `[15]` shows the folders in use and switches
between the two layouts. These settings control it, in order of precedence:

| Setting | Effect |
| --- | --- |
| `SPDHOST_INPUT_DIR` / `SPDHOST_DUMP_DIR` | names one folder outright; the layout below is ignored |
| `SPDHOST_STORAGE=auto\|shared\|package` | this run only; beats the saved config |
| `STORAGE=` in `~/.spdhost-menu.conf` | what `[15]` saves; `auto` means shared storage when it is visible, the package folders when it is not |
| `SPDHOST_SHARED_DIR=/some/dir` | the only shared path searched, under which `Download/` is created (used by the tests, and by anyone who wants the images somewhere else) |

When the two folders differ (the `package` layout, or an explicit
`SPDHOST_INPUT_DIR` / `SPDHOST_DUMP_DIR`), `[9]` copies the partition images
from the dump folder into the flash folder. It only adds files: an image
already there at the same size is left alone, and one of a different size is
reported and skipped rather than replaced, because the flash folder also holds
the images you actually meant to flash.

Dump `[1]` fetches the live table into `partition_list.txt` in the dump folder,
prints it like the rooted menu's LIST PARTISI, then resolves what you type to
the closest name (`boot.img` or `boot` → `boot_a` when that slot exists) and
uses that row's size. Flash `[6]` reads the flash folder — `Download/`, or
`input/` beside `fdl/` in the package layout — and accepts `.img` or `.bin`;
name each file after the partition (`boot.img`, `vbmeta.img`). Restore `[7]`
offers to force the other slot (`write-parts-a` / `write-parts-b`). `[4]` only
refreshes the list.

After a flash, restore, repartition, slot change or dump, the menu runs the
ending the release menu does: system (`reset`), recovery, fastbootd, or
power off. That ending is a setting, not a per-run choice — Extra `[10]`
saves it to `~/.spdhost-menu.conf` alongside the loaders and `exec_addr`,
and it defaults to `reset`.

Extra:

```
[1] Factory reset (recovery wipe BCB; does not erase persist)
[2] Set active slot (a/b)
[3] Power off
[4] DANGEROUS: verity (vbmeta byte 0x7B)
[5] DANGEROUS: reset FRP (backup persist, then erase it)
[6] Reboot recovery          [7] Reboot fastbootd
[8] DANGEROUS: unlock bootloader (erases splloader until the last step)
[9] Hex mode (exec_addr)     [10] Boot mode after flash / restore
[11] Read the chip UID (read-only)
[12] Check one partition's live size (read-only)
[13] DANGEROUS: erase one partition
[14] Build a slot a/b misc image from a dump (offline, no phone)
[15] Storage folders: shared storage (/sdcard) or the package
```

`[13]` refuses `persist`, `splloader` and `all` outright. `[14]` runs
`pack-slot` with no phone attached and records the output in `SHA256SUMS`.

Unlock `[8]` sends nothing until it can see `fdl2-cboot.bin` and some way to
build `spl-unlock.bin`: the built-in `gen-spl-unlock`, or the release's
x86-64 binary as a fallback. It looks in the current directory, in
`ums9230/infinix/` (where the release keeps `fdl2-cboot.bin` next to
`fdl1-dl.bin`), and in the package root (beside the release's
`gen_spl-unlock`). `fdl2-cboot.bin` is a vendor blob and is not derivable
from anything else in the tree, so one copy ships for ums9230/Infinix and
other models have to supply their own. `spl-unlock.bin` is generated from
your own splloader dump. The unlock is several sessions: it reads splloader
as 256 KiB, erases only after that backup exists, and the last session loads
`parts` before writing splloader and the active uboot name back. A failed
erase skips the unlock loader and still writes that backup back.

Smoke test `[5]` is a safe, read-only check: `--self-test`, an environment
check, a summary of the current BootROM-hello settings, and — only if
`termux-usb -l` already lists a device — a short bounded `ping` probe plus a
second probe to confirm the interface was not left claimed. It never runs
`fdl`, a partition write, an erase or a reboot.

Menu sessions always pass `--timeout` (default 3000 ms, override with
`SPDHOST_TIMEOUT`) and `--verbose` when `SPDHOST_VERBOSE=1`. The CLI default
timeout stays 1000 ms. `SPDHOST_BIN=/abs/path/to/spdhost` makes the menu use
that binary for its own checks instead of resolving one the way
`scripts/spdhost-usb` does; it does not change which binary the wrapper
launches.

## BootROM hello and USB troubleshooting

The BootROM window is short and the first permission dialog usually outlasts
it. Cold-unplug the target ≥5 s between sessions; success once does not make
later tries stickier without a replug.

Nothing that talks to Termux:API *blocks* between "the device was found" and
`termux-usb` being spawned. That gap is the whole window, and every API call
is a broadcast round trip through the same app that has to raise the
permission dialog. Detection is a poll (`termux-usb -l`, then 0.3 s), so
"found" already lands up to a poll interval after the device appeared;
`usb: listed … @Xms` and `usb: child start fd=N @Zms` in the wrapper output
are the two timestamps to compare when a session dies right after detection.

The wake lock is taken *after* detection, not before the wait — that is the
known-good build's order, and the wrapper's job while waiting is to be ready
to spawn `termux-usb` the moment the device appears. The device-found toast
and buzz still fire there, but backgrounded (`&`), so they never sit on that
path; `SPD_USB_NOTIFY=0` turns both off.

Stay in the package root so `scripts/spdhost-usb` finds `./spdhost`. Set
`SPDHOST_BROM_TRACE=1` for claim→try breadcrumbs (`brom: open/claim`,
`brom: line-state done`, `brom: try N`), including device speed and endpoint
addresses. The wrapper always prints thin USB timing lines
(`usb: listed … @Xms`, `usb: child start fd=N @Zms`) with no env needed.
BootROM hello send/recv uses `SPDHOST_BROM_TIMEOUT` only, not
`max(--timeout, BROM_TIMEOUT)`, and each try's own timeout ramps from
`SPDHOST_BROM_TIMEOUT_MIN` up to that ceiling over
`SPDHOST_BROM_TIMEOUT_RAMP` tries, so more tries land inside the window.
Each BootROM start prints a line like
`brom: hello hello_to=250..3000(x6) wall=46000(auto) tries=15`.

The floor of that ramp is `SPDHOST_BROM_TIMEOUT_MIN`, default **250 ms** —
the value the known-good build (`spdhost-exp-write-a6cb72d`, the one a real
phone was detected and flashed with) ships, and what this menu's own smoke
test text has always said. It was raised to 1000 ms for a while, on the
theory that a 250 ms floor lets a BootROM that answers try 1 *while* try 2 is
being sent emit two VER frames, the second of which the next command reads as
`unexpected response 0x0081`. That theory did not survive contact with
hardware: every release with the 1000 ms floor detected the device and then
timed out. If you are chasing that frame race on your own host, raise it
yourself with `SPDHOST_BROM_TIMEOUT_MIN=1000`.

A mid-hello USB reacquire was removed: it hit `LIBUSB_ERROR_BUSY` and a
second Allow dialog. `SPDHOST_BROM_REACQ` therefore defaults to **0**, and
BootROM OUT `LIBUSB_ERROR_TIMEOUT` during check-baud is soft — the remaining
tries continue on the same handle. If claim returns `BUSY` (a leftover claim
after an unclean exit) stderr prints an unplug/replug hint; spdhost also
releases the interface before close and on `atexit` so the next run can
claim cleanly. Ctrl-C during a hello, read-part, write-part or erase-part
stops that operation at its next checkpoint and exits normally, so that
release runs; a second Ctrl-C restores the default action.

On a Linux PC that can open the device node, drop `spdhost-usb` and call the
binary directly; the command words after that are the same.

| Variable | Default | Effect |
|---|---|---|
| `SPDHOST_BROM_TRIES` | 15 | hello attempts |
| `SPDHOST_BROM_TIMEOUT` | 3000 | per-try ceiling (ms), hello only |
| `SPDHOST_BROM_TIMEOUT_MIN` | 250 | ramp floor (the known-good build's value) |
| `SPDHOST_BROM_TIMEOUT_RAMP` | 6 | tries spent reaching the ceiling |
| `SPDHOST_BROM_NO_RAMP` | 0 | `1` = every try uses the ceiling |
| `SPDHOST_BROM_WALL_MS` | auto | overall wall; explicit wins, capped at 120000 |
| `SPDHOST_BROM_PAUSE_MS` | 500 | pause between tries |
| `SPDHOST_BROM_SETTLE_MS` | 100 | pause after line-state, before hello |
| `SPDHOST_BROM_DRAIN` | 0 | `1` = short bulk-IN drain after settle |
| `SPDHOST_BROM_REACQ` | 0 | soft same-handle settle+retry after a miss (`1`/`2`) |
| `SPDHOST_NO_CLEAR_HALT` | 0 | `1` = omit `libusb_clear_halt` on the bulk endpoints before the hello |
| `SPDHOST_NO_SET_CONFIG` | 0 | `1` = omit `SET_CONFIGURATION(1)` when the device reads as config 0 |
| `SPDHOST_NO_SEND_ZLP` | 0 | `1` = omit the zero-length OUT packet after a 512-byte-multiple bulk write |
| `SPDHOST_BROM_TRACE` | 0 | `1` = breadcrumb timestamps without `--verbose` |
| `SPD_USB_ATTACHED_GRACE` | 0 | wrapper grace before it gives up on the device |
| `SPD_USB_SKIP_REQUEST` | 0 | `1` = omit `-r` on a warm, already-authorized run |

**Warn:** `SPD_USB_SKIP_REQUEST=1` fails open if the grant was never given
(permission denied / never started). Keep the default `-r` for a cold first
plug, and do not export it as a global default in menus.

The three `SPDHOST_NO_*` rows before `SPDHOST_BROM_TRACE` each turn **off**
one piece of traffic that is **on by default**:

- `CLEAR_FEATURE(ENDPOINT_HALT)` on both bulk endpoints, right after
  line-state and before the first `0x7e`;
- `SET_CONFIGURATION(1)` when the device reports configuration 0;
- a zero-length OUT packet after any bulk write that exactly fills a 512-byte
  high-speed packet.

That default is the known-good build's. The vendor reference
(`spd_dump/common.c`) sends none of them, and a release was cut that followed
the reference and turned all three off — after which every phone was detected
and then died, with `device exited immediately after being detected` and a
blanket `LIBUSB_ERROR_TIMEOUT`. Matching the build that worked is therefore
the rule, and the reference is not the last word. Keep all three on; use the
`SPDHOST_NO_*` switches only to A/B a specific host that dislikes one, not to
fix a general failure.

## Command order

`fdl` the first time speaks BootROM: line-state control transfer, CRC-16
check-baud, connect, download, execute, then check-baud again with the
additive checksum. The second `fdl` downloads the next loader and executes
it. `ping` is only a handshake; `ping --fdl` uses the FDL checksum and marks
the session as already in FDL1, so a following `fdl` sends the second loader
instead of talking to BootROM again. Partition commands assume you are
already talking to a loader that understands them.

If execute makes the phone drop off the bus, spdhost closes the dead handle
and reopens: on Termux by calling `termux-usb` again for a new descriptor
over a socket (`grab_termux` / `spd_usb_reacquire`), on the desktop by
scanning for vendor `1782` (any product id, which is logged; the vendor must
stay `1782`). A reset during `read-part` or `write-part` aborts that command
instead of resending the chunk. Reconnect is **not** attempted mid-BootROM
hello.

The Termux reopen speaks both descriptor forms. `termux-usb -E` exports the
descriptor as `TERMUX_USB_FD`; an older `termux-usb` without `-E` passes it as
the launcher's `argv[1]` instead. Both sides handle both: the wrapper probes
for `-E` once and its launcher reads `${TERMUX_USB_FD:-${1:-}}`, and the
reopen child probes the same way before choosing its `termux-usb` arguments
rather than hardcoding `-E`. Without that, a phone that resets after a loader
step on an older Termux:API could never be reopened — the handle stayed dead
and every following transfer timed out.

## What this is not

Not a replacement for the full `sfd_tool` GUI, PAC flashing, or raw-data
mode. `unpac` lists, checks and extracts a PAC; it does not flash one, and
the menu does not take a PAC as an input. Reopen covers a USB reset between
loader stages; it does not resume a partition read or write that was cut in
half.

spdhost does not implement a BootROM exploit. It builds the loader the
published one uses (`gen-spl-unlock`, `gen-spl-unlock-legacy`,
`gen-fdl1-dl`, `chsize`), so `spl-unlock.bin` can be made on the phone from
your own dump.

`spdhost` is original, MIT-licensed code (`LICENSE`). It is not a fork of
the other Termux clients. Two credits worth stating: the four image tools in
`src/dhtb.c` are transcriptions of TomKing062's published CVE-2022-38694
sources (said so in that file's header), and spdhost follows spd_dump's
on-wire behaviour throughout. The TomKing / ilyakurdyukov client vendored
under [`spd_dump/`](spd_dump/) is a separate work with its own `NOTICE` and
pin.
