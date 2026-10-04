# spdhost

A small Unisoc/Spreadtrum download-mode client: one process, one USB device
per run, no GUI. It talks to a phone in BootROM or FDL over libusb bulk
transfers. On a phone (Termux, no root) the `spdhost-usb` wrapper takes the
descriptor from `termux-usb`; on a PC it opens the device node itself.

New here? Start with the [setup tutorial](TUTORIAL.md) and the [FAQ](FAQ.md).

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

`tests/*.sh`, one per area (`write-seq`, `gpt-seq`, `menu-dump`,
`dhtb-tools`, `pac-tools`, …). Each builds its own binary and needs no device.
Run `bash tests/<name>.sh` from `no-root/`; the whole set runs in CI.

Most of them drive `tests/mock_fdl2.c` through the real protocol, and the
device it pretends to be is set with environment variables:

| Knob | Effect |
|---|---|
| `MOCK_PTABLE` | unset → the device **refuses** a partition table (a bare ACK to `READ_PARTITION`); empty or `1` → its built-in four-row table; a filename → `name KiB` lines |
| `MOCK_GPT` | `1` → `user_partition` holds a standard GPT (header at LBA 1, 128 entries at LBA 2: `misc` 1 MiB, `boot_a` 8 MiB, `boot_b` 10 MiB, `userdata` 20 MiB, then zeroed entries); unset → pattern bytes, so the SPRD `READ_PARTITION` fallback is taken |
| `MOCK_SLOT` | `a` / `b` — what `misc`'s bootloader_control reports |
| `MOCK_LOG` | the frame log the tests compare (`SEQ <type> len=…`) |

`MOCK_PTABLE` must list `user_partition` for the GPT read to be answered at all,
and every row must be at least 1024 KiB or spd_dump's divisor heuristic rescales
the whole table. `tests/gpt-seq.sh` is the worked example.

## Safety

**Loaders and addresses must match the exact chip.** A wrong `fdl1-dl.bin`,
`fdl2-dl.bin` or load address can brick the phone. The pair shipped under
`fdl/ums9230/infinix/` is one example; treat it as untrusted until it
matches your device's PAC or known-good package.

Three levels of gate, in increasing order:

| Gate | Covers | Notes |
|---|---|---|
| typed `yes` (or `--yes`) | `write-part`, `w-force`, `write-files`, `write-parts*`, `repartition`, `set-active`, `reboot-*` | `--yes` is for CLI automation. `reset` and `power-off` are sent with no second prompt, the same as spd_dump; the menu asks before it runs them |
| the word `dangerous` (or `--dangerous`) | `verity`, `frp-reset`, `danger-erase` | `--yes` is **not** enough; without a terminal they send nothing unless `--dangerous` is passed |
| `--confirm-token SHA256` | the misc write it is passed with | authorizes one misc write whose exact bytes hash to that value; a second misc write in the same session is refused |

`erase-part` refuses `persist`, `persist_a`, `persist_b`, `all`, `splloader`
and `splloader_bak` outright, even with `--yes` or `--dangerous`.
`danger-erase` is the only way to erase the persist/splloader names, and it
takes them one at a time.

`scripts/menu.sh` never passes `--yes` or `--dangerous`. It takes its own
typed confirm, shows the sha256 of the bytes it is about to write, and
passes `--confirm-token`; spdhost then writes misc only if the bytes it is
about to send hash to exactly that value, once per session.

Not every misc write goes through that token. A misc write that is part of a
larger confirmed batch — `misc.img` inside `write-files`/`write-parts`, or the
`reboot-recovery`/`reboot-fastboot` ending the release menu appends to a flash
or a dump — is covered by that batch's own typed `yes` instead, and spdhost asks
for it in the session, not through a token. Both gates are typed and per-session;
the token adds the exact-bytes check on top.

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

"Download-mode keys" depend on the model. Volume down is the most common,
but some phones use volume up, both volume keys, or a boot key. The FDL1
address and the exec stub are per chip. Menu option 3 sets them together when
you pick a chip and brand, and spdhost refuses a stub whose chip doesn't
match the FDL1 address (`6501xxxx` goes with `0x65000800`, `3ee8`/`3f48`
with `0x5500`, `4ee8`/`4f48` with `0x5000`). Without a chosen chip the menu
sends no exec stub at all. The stub is only looked up in `fdl/<chip>/`.

```sh
# ums9230 (Infinix)
spdhost-usb exec_addr 0x65015f08 fdl/ums9230/custom_exec_no_verify_65015f08.bin fdl fdl/ums9230/infinix/fdl1-dl.bin 0x65000800 fdl fdl/ums9230/infinix/fdl2-dl.bin 0x9efffe00 parts
# ums512 (Infinix)
spdhost-usb exec_addr 0x3ee8 fdl/ums512/custom_exec_no_verify_3ee8.bin fdl fdl/ums512/infinix/fdl1-dl.bin 0x5500 fdl fdl/ums512/infinix/fdl2-dl.bin 0x9efffe00 parts
# sc9863a (realme)
spdhost-usb exec_addr 0x4ee8 fdl/sc9863a/custom_exec_no_verify_4ee8.bin fdl fdl/sc9863a/realme/fdl1-dl.bin 0x5000 fdl fdl/sc9863a/realme/fdl2-dl.bin 0x9efffe00 parts
```

The partition table's size unit is spd_dump's guess. On eMMC it's KiB
(divisor 10). When any row is under 1 MiB, or on UFS, the divisor drops and
spdhost warns, then checks one row of 2 MiB or more with spd_dump's
`check_partition` probe. Read-only menu sessions (table fetch, misc read,
chip UID, partition size) end with the configured ending, or power-off when
that ending would write misc, so the phone isn't left sitting in FDL2.

### Commands

Handshake and loaders:

- `ping [--fdl]` — BootROM hello, or an FDL hello with `--fdl`.
- `fdl FILE ADDR` — send one loader and execute it. The first `fdl` talks to
  BootROM (CRC-16 framing), the second to FDL1 (additive checksum).
- `exec_addr ADDR [FILE]` — BootROM stage only, before the first `fdl`: send
  FDL1, then FILE at ADDR as a no-verify stub that starts FDL1 (spd_dump's
  `exec_addr`). `ADDR 0` disables it.
- `exec_addr2 ADDR [FILE]` — the same stub, but for a BootROM that accepts only
  one download: FDL1's download is left open (no END), zero filler fills the gap
  up to ADDR, and the stub rides in that same stream. spd_dump's `exec_addr2`,
  CLI only; the menu always uses `exec_addr`.
- `loadfdl FILE` — `fdl FILE`, with the address read out of FILE's own name,
  which must carry `_0x<hex>` (spd_dump's `loadfdl`). A vendor pair named
  `fdl1-dl_0x65000800.bin` / `fdl2-dl_0x9efffe00.bin` can then be sent without
  being told the addresses. A name with no `0x` in it is refused.
- `loadexec FILE` — the BootROM-stage `exec_addr`, with the address read out of
  FILE's name (`custom_exec_no_verify_<hex>.bin`). A file that is not there
  prints `does not exist` and leaves the address at 0, as spd_dump does; after
  the first `fdl` the verb is ignored, also as spd_dump ignores it.
- `loadexec2 FILE` — `loadexec`, in `exec_addr2`'s one-download form.
- `keep_charge 0|1` — keep the phone powered between stages instead of letting
  it drop (spd_dump's `keep_charge`). It takes effect on the next `fdl`, which
  is where the loader is told. With no argument it prints the setting.
- `path DIR` — where a command that builds its own output file puts it
  (`wof`/`wov`, `firstmode`). A command given an explicit output path uses that
  path as written.

Partition table and reads:

- `parts [FILE]` — print `index name units`. `index` is the number
  `read-part` / `write-part` / `erase-part` accept: **0 is `splloader`** (256
  KiB, it has no table row) and the first table row is `1`, as in spd_dump.
  The unit is whatever that
  loader reports (often sectors). On eMMC (ums9230) the units are KiB;
  convert with `bytes = units << (20 - divisor)`, where `divisor` starts at
  10 and drops while any non-zero entry is smaller than `1 << divisor`. The
  menu does this and writes `partition_bytes.txt` in the dump folder
  (`/sdcard/Download` by default, `backup/` when storage permission is missing).
  On a phone whose `user_partition` holds a standard GPT — which is every
  modern device — the rows come from that table instead and the unit is MiB,
  the same number `partition-list` writes into the XML.
- `partition-list [FILE]` — the same table as the XML `repartition` reads,
  byte for byte what spd_dump's `partition_list` writes for it: one
  `<Partitions>` list, `size` in the table's own unit, last row `0xffffffff`
  ("take the rest"). This is how you get an XML to edit: dump the phone's own
  table and change the rows you need. On a phone those units are MiB — a 5 GiB
  `super` reads `size="5120"`, and growing it to 10 GB means `size="10000"`.
  Dumping a table is not a write — no `yes`.
  spd_dump also writes `partition_<unixtime>.xml` wherever it runs on **every**
  session that reads the table, so the file to edit is always there. spdhost
  writes that same file, into `--part-xml DIR` (env `SPDHOST_PART_XML_DIR`)
  instead of the working directory; the menu points it at the dump folder, so
  each table read leaves `partition_<unixtime>.xml` there (by default
  `/sdcard/Download`, or `backup/` without storage permission) and
  option 4 (list partitions) says so. One name per run: a session that reads the
  table twice rewrites its own copy. `--part-xml ""` turns it off.

  The table is read the way spd_dump reads it, and **once per session**.
  spd_dump keeps a `gpt_failed` latch (`spd_dump.c:144`, set by
  `common.c:1143/1088/1095`) and guards every call site with
  `if (gpt_failed == 1)`, so the first command that needs the table asks the
  device and everything after it in the same run re-prints the table already in
  hand — `parts`, `partition-list`, `check-part`, `part-size`, `read-parts`,
  `print` and `write-part` share one read. spdhost reads it at the same point,
  at the FDL2 stage of `fdl`, so the table is there whether or not the session
  asks for it and a later listing costs no USB round trips.
  The read is `user_partition`, the first 32 KiB, tried as a **standard GPT**
  first (spd_dump's `gpt_info()`, `common.c:977`): header at LBA 1, entry array
  at `partition_entry_lba`, names from `partition_name` at offset 56 of each
  128-byte entry, sizes from the LBA range. A header found at sector 1 means
  eMMC, anywhere else UFS. The dump is kept as `pgpt.bin` and the message says
  so. Only when that is not a GPT does it fall back to the SPRD
  `READ_PARTITION` (0x2d) packet, whose reply is kept as `sprdpart.bin`. A
  device that answers neither is reported as having no table, and a name lookup
  then sends the name as given — `parts` is still not needed first, but without
  a table a numeric id cannot be resolved.
- `check-part NAME` — print `1` when the partition exists in the live table,
  `0` when it does not, like `spd_dump check_part`. Needs `parts`.
- `part-size NAME` (also `size_part`, `part_size`) — print the byte size from
  the live table, `0` when the name is absent, like `spd_dump size_part`.
  Needs `parts`. The menu's read-only "partition size" action uses this.
- `read-part NAME OFF SIZE OUT` — `SIZE` may be `-` or `full` for the whole
  partition. `K`/`M`/`G` suffixes and `0x` hex work; a bare number is bytes.
  `-`/`full` and a `0xffffffff` size are the two cases where the size is asked
  of the device (spd_dump's `check_partition`), which is the only way to size a
  partition the table does not know; a name the device will not size falls back
  to the table's own size. `splloader` stays at its fixed 256 KiB. Needs
  `parts`.
- `print` (also `p`) — spd_dump's `p`: list each partition with its byte size,
  `splloader` first as row 0 at 256 KiB. Read-only, no `parts` needed.
- `read-parts FILE.xml [DIR]` — spd_dump's `read_parts`: read every partition
  the XML list names into `DIR/NAME.bin`, in the list's own order. `DIR`
  defaults to the `path` directory, then the current directory. `userdata` in
  the list is skipped, `splloader` is 256 KiB, a `size="0xffffffff"` row is
  sized by the device, and `super` reads its `metadata` beside it. A row the
  live table does not carry is skipped too, as spd_dump's `dump_partitions`
  does (`common.c:1757`); on an A/B phone the `misc` image is read a second
  time at the end as the slot info (`common.c:1771`). The list
  itself is copied into `DIR` only when a destination was named — with none,
  the reference leaves it where it is, and so does spdhost. Needs `parts`.
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
  `calinv` is skipped; `runtimenv` is written where spd_dump erases it.
  vbmeta flags are left as they are in the file.

  On a non-A/B eMMC/UFS phone that has a `NAME_bak` row, plain `write-part`
  is spd_dump's `load_partition_unify`, which is more than one write. It
  reads the primary back first — the size that counts is the one the
  **device** reports (`size0 = check_partition(io, name0, 1)`, common.c
  2122), not the `NAME` row, which is why a table read and a burst of read
  frames precede the write. Then it writes the primary through the same
  rename `w-force` uses (`load_partition_force`, common.c 2126), and only if
  the device's size and the `NAME_bak` row agree does it write the image a
  second time under `NAME_bak`. The second copy is the one that boots when
  the first is broken, so it is written even when the primary's write failed:
  the reference's `load_partition_force` is `void` and its caller never looks
  at the result (common.c 1321, 2126). spdhost keeps that behaviour and still
  reports the failure, and the command still exits non-zero.

  Two deliberate differences from the reference, both in the check that
  decides whether to take that path at all. spd_dump's `get_partition_info`
  scans for `NAME_bak` and then reads `ptable[i]` with `i == part_count` when
  the name is missing (common.c 1589-1648) — an out-of-bounds read, so it
  force-writes on garbage even with no `_bak` row. spdhost does not copy
  that: no `_bak` row means a plain write. (The frame-level parity of the
  path above is pinned in `tests/write-seq.sh`, including both REPARTITION
  packets byte for byte against the vendored tool.)
- `w-force NAME FILE` — spd_dump's `w_force`, CLI only: rename the target row
  to `w_force` in a temporary table, write the image under that name, then
  send the original table back. The write that gets through where a plain one
  is refused, and the only write that does not stop at the row's size — the
  loader checks a write against the partition names it knows, and a name it
  has never seen is not checked. Refuses `splloader` (the reference's own
  blacklist) and `misc`. Takes the same `yes` as `write-part`; the menu does
  not offer it.
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
- `wof NAME OFF FILE` / `wov NAME OFF VALUE` — patch `FILE` (or the 32-bit
  `VALUE`, little-endian) into `NAME` at `OFF`. `fixnv*`, `runtimenv*` and
  `userdata` are blacklisted, as in spd_dump's `w_mem_to_part_offset`; the
  phone has no partial write, so the whole partition is read, patched and
  written back under the same `yes` as `write-part`.
- `firstmode N` — write `0x53464D00 + N` at `miscdata` `0x2420` (spd_dump's
  `firstmode`). Writes misc, so it takes the same read-back and `yes` as the
  other misc writes.
- `repartition FILE.xml` — replace the phone's partition map with
  `<Partition id="name" size="N"/>` rows, `N` in MiB or `0xffffffff` for the
  last row ("take the rest"). Asks for `yes`; the menu never passes `--yes`
  to it. Get the starting XML with `partition-list` above (or the
  `partition_<unixtime>.xml` every table read leaves in the dump folder) rather
  than writing one by hand. The rest of the session resolves names and sizes against the
  new table, as spd_dump does, so `repartition grow.xml write-part boot
  boot.img` in one session writes against the enlarged boot. A later `parts`
  re-reads the table from the device, which need not match until the phone
  restarts. Up to 862 rows — the 16-bit frame length.

The loader tells us what it is stored on — `Da_Info.dwStorageType`, read from
the FDL2 exec reply and from the flash-info exchange that follows it, and
corroborated by the table read (`Storage is emmc`, `Storage is ufs`, `Storage
is nand`, printed once per session). On eMMC and UFS the table is read
automatically after FDL2; on NAND the reference does not read one at all
(spd_dump.c:772), and neither does spdhost, so `parts` has to be run by hand if
you need it. NAND also refuses `w-force` (`w-force is not allowed on
NAND(UBI) devices`) and a plain write skips the `_bak` twin, both as
spd_dump does.

Slots and misc:

- `set-active a|b [--bcb recovery|fastboot]` — one session: read misc,
  patch the 32-byte slot block at `0x800` (and with `--bcb` the 2048-byte
  BCB at 0), write the whole misc back, read it back; with `--bcb` it then
  resets. A switch keeps the other slot's tries and `successful_boot` when
  misc holds a valid `bootloader_control` (magic `BCAB` and CRC). Otherwise,
  or with the global `--spd-dump-slot`, it writes spd_dump's fresh block
  (other slot priority 14, tries 1, successful 0). Refused unless the table
  has `uboot_a` and `uboot_b`. Warns that slot b's system may be empty when
  `super` exists. `--confirm-token` covers the patch, not the image: it is the
  sha256 of the line `spdhost-set-active <a|b> <BCB sha256|none>\n`.
  `write-parts` no longer rewrites the slot block when the target slot is
  already active.
- `misc-backup FILE` — read all of misc to FILE and read it back. Any
  failure stops the session before a write, even with `--keep-going`.
- `reboot-recovery` / `reboot-fastboot` — synthesize the 2048-byte Android
  BCB, splice it into misc at 0, write the **whole** misc back and verify it,
  then `reset`. Before that, spdhost reads 4 KiB of the active slot's
  `boot`, `recovery` (if present) and `vbmeta` and warns if the
  `ANDROID!`/`VNDRBOOT`/`AVB0` magic is missing. fastbootd needs an
  Android 10+ recovery. See
  [misc BCB images](#misc-bcb-images-phone-data-not-host-isa).
- `reset`, `power-off` (also `poweroff`). If the device drops off the bus
  (USB `NO_DEVICE`/`IO`) after the frame was sent, the command counts as
  success: `device left the bus on reset (expected)`. A timeout is still a
  failure. With `SPDHOST_STATUS_FILE=PATH`, spdhost appends `misc-verify=`
  and `reset=`/`power-off=` lines, which the menu uses to report the two
  results separately.
- `chip-uid` — read-only.

Anything that writes misc reads the whole partition first, unless the same
session already ran `misc-backup`. The automatic copy is
`misc-before-YYYYMMDD-HHMMSS.img` in the current directory. After the write
spdhost reads misc back: the new bytes must match and the rest must be
unchanged, or it does not reset. Like spd_dump, the command list stops after
`reset`, `power-off` or `reboot-*` succeeds.

Dangerous:

- `verity 0|1 [DIR]` — write byte `0x7B` of `vbmeta`. `0` writes `0x01` (dm-verity
  off); `1` writes `0x00` on every `vbmeta*` name that exists. This is the
  byte spd_dump writes, and it **is** the AVB flag byte: the vbmeta header's
  `flags` field is a big-endian u32 at `0x78`, so `0x7B` is its low byte
  (bit0 `HASHTREE_DISABLED` = `--disable-verity`, bit1
  `VERIFICATION_DISABLED` = `--disable-verification`). `verity 0` sets bit0 and
  clears bit1. The flags are inside the signed header, so **a patched vbmeta
  only boots with an unlocked bootloader**; `verity 1` or the saved original is
  the undo. A partition without the `AVB0` magic is refused. Each original is
  saved as `DIR/vbmeta-before-<name>-<time>.img` (DIR defaults to the
  `--part-xml` folder, else `.`) and its sha256 printed before anything is
  written; no backup, no write. The whole partition is read and written back,
  and a row that does not cover `0x7B` or is over 64MB is not written. Needs
  `parts`.
  spd_dump writes it through its force-write path (`w_mem_to_part_offset` →
  `load_partition_force`): a REPARTITION renaming the partition to `w_force`, a
  write to that name, then the original table to put the name back. spdhost
  writes the partition plainly — same bytes into the same partition, since the
  image *is* that partition read back — so an interrupted run cannot leave the
  phone carrying a `w_force` row. `w-force` is still there for an image that
  really is larger than its table row.
- `frp-reset OUT` — read all of `persist` (or `persist_a`/`persist_b` for
  the active slot) to OUT, check the size, then erase it. A failed or short
  read does not erase. Over 512MB is refused. Needs `parts`.
- `danger-erase NAME` — erase only `persist`, `persist_a`, `persist_b`,
  `splloader` or `splloader_bak`. A persist name that is not in the live
  table is not erased; `splloader` is still sent when the table has no such
  row, which is what the release unlock does.
- `erase-part NAME` — erase any other partition. Refuses `persist`,
  `persist_a`, `persist_b`, `all`, `splloader` and `splloader_bak` even with
  `--yes` or `--dangerous`; `danger-erase` is the way to those. NAME is
  resolved against the live table first, as spd_dump's `e` does: `boot`
  erases `boot_a` on a slot-a phone, a number is a table index (`0` is
  `splloader`, so it is refused), and the refusals apply to the resolved
  name. A name the table does not know is refused, not sent literally.
- **`erase-part userdata` is refused** (also `userdata_a`/`userdata_b`).
  spd_dump's `e userdata` (common.c erase_partition, ~1170) never erases
  userdata: it writes the wipe BCB to misc and erases `persist`. Erasing the
  partition directly would leave recovery nothing to format, so spdhost
  refuses and points at the factory-reset path instead:
  `write-part misc misc/misc-wipe.bin` (menu `[10]` → `[1]`, or `[2]` → `[5]`).

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
--step N          partition chunk size, decimal or 0x hex; clamped to 0xf800
                  and rounded up to a multiple of 0x800 (spd_dump blk_size)
--no-line-state   skip the smartphone line-state control transfer
--keep-going      a failed read-part is logged and the next command runs
--yes             skip the typed yes for write/erase/repartition/reboot-*
--dangerous       authorize verity/frp-reset/danger-erase without a typed word
--confirm-token SHA256   authorize one misc write whose bytes hash to it
--part-xml DIR    leave partition_<unixtime>.xml in DIR on every table read
                  (env SPDHOST_PART_XML_DIR; "" = off). The menu sets it to the
                  dump folder, as spd_dump leaves that file behind itself
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
ones to `SHA256SUMS` in the dump folder.

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

Each file is exactly 2048 (`0x800`) bytes; A/B `bootloader_control` lives at
`0x800`. Do not `erase-part misc` as a shortcut. spdhost never sends a bare
2048-byte write. A BCB, whether from `reboot-*` or `write-part misc
<2048-byte file>`, is spliced into the misc image the session just read, and
the whole partition is written and read back. spd_dump writes the 2048 bytes
alone, so a loader that programs misc in 4 KiB (or larger) units zero-fills
`0x800..0xfff` and loses the slot block. The `--confirm-token` for a BCB is
still the sha256 of those 2048 bytes.

`reboot-recovery` and `reboot-fastboot` synthesize the same BCB TomKing
uses after two matching loaders, write it into `misc` (whole-partition
read-modify-write), then reset. fastbootd is part of recovery and only exists
on an Android 10+ recovery image. They ask
you to type `yes` unless you pass `--yes` (CLI automation only); the menu
uses `--confirm-token` instead, as described above.

The reboot submenu under `[2]` also has `[5]` wipe userdata (writes
`misc/misc-wipe.bin` then `reset`; recovery honors `--wipe_data` and erases
userdata on the next boot) and `[6]` restore misc from one of the
`misc-before-*.img` copies in the dump folder. The wipe item does **not** erase
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
[8] Repartition from XML ('new' dumps the phone's own table first)
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
/sdcard/Download    dumps land here (menu [1]); flashes read here (menu [6]);
                    partition_<unixtime>.xml lands here on every table read
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
[16] Extract a PAC firmware (offline, no phone)
```

`[13]` refuses `persist`, `splloader` and `all` outright. `[14]` runs
`pack-slot` with no phone attached and records the output in `SHA256SUMS`.
`[16]` lists a `.pac`, verifies its CRCs and extracts it, all through the
built-in `unpac` — the release only ships `extrac.sh` plus an x86-64
`pacextractor`, which cannot run on the phone. It writes into
`INPUT_DIR/extract` by default so it cannot overwrite a file you put in the
flash folder. `unpac check` exits 0 even on a CRC mismatch, the same as the
vendor tool, so `[16]` reports the mismatch itself instead of trusting the
status.

Unlock `[8]` sends nothing until it can see `fdl2-cboot.bin` and some way to
build `spl-unlock.bin`: the built-in `gen-spl-unlock`, or the release's
x86-64 binary as a fallback. `fdl2-cboot.bin` is searched for next to the
loaders of the model you selected. Once a model is selected (`DEVICE` set),
that folder is the only place searched; the current directory and the
package root are only tried before any model is chosen. Another model's
`fdl2-cboot.bin` must never be picked up: this file is written to `uboot` right
after `splloader` is erased, so the wrong phone's image is a brick. That is
why the lookup doesn't climb out of an `alternatif/<model>/` folder to the
brand-level copy.
`fdl2-cboot.bin` is a vendor blob (the model's own `fdl2-dl.bin` with some
`NOP`s patched into branches) and can't be derived from anything else in
the tree. One copy ships per chip and brand (`fdl/<chip>/<brand>/`) and per
ums9230 `alternatif/<model>/` (11 models, taken from the root release package
after checking that each model's `fdl1-dl.bin`/`fdl2-dl.bin` match ours byte for
byte). The generic `universal` set ships none: the vendor zip's copy there was
byte-identical to its `fdl2-dl.bin`, so it isn't an unlock image, and unlock
refuses `universal`. Before unlocking, the menu prefers `uboot_<active
slot>.img` from the dump.
`spl-unlock.bin` is generated from
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
permission dialog. Detection is a poll of `termux-usb -l` about every 0.3 s.
A list that itself took longer is not followed by another full pause, so a
slow answer does not stack on top of the interval. "found" still lands up to
one poll after the device appeared; `usb: listed … @Xms` and
`usb: child start fd=N @Zms` in the wrapper output are the two timestamps to
compare when a session dies right after detection.

The first poll is only a snapshot. A phone that appears on the next poll,
while a charger was already listed, is the device that gets opened. When the
listing names `vendor_id`, or when `/sys/bus/usb/devices` is readable, vendor
1782 is the download-mode phone (BootROM and diag both use it) and any other
vendor is left alone. One new path with no vendor, and a single
already-attached path with no vendor, stay the old rules, so a Termux:API
that prints only paths is unchanged. `SPD_USB_NO_SYSFS=1` skips the sysfs
read. An explicit `/dev/bus/usb/N/M` argument skips the wait entirely.

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

`SPDHOST_USB_CAPS=1` asks usbfs what the host kernel supports
(`USBDEVFS_GET_CAPABILITIES` on the termux-usb descriptor, the same ioctl
libusb runs when it opens the device) and prints the raw mask, the decoded
flags (`ZERO_PACKET`, `BULK_CONTINUATION`, `NO_PACKET_SIZE_LIM`,
`BULK_SCATTER_GATHER`, `REAP_AFTER_DISCONNECT`, `MMAP`, `DROP_PRIVILEGES`)
and the bulk path that puts libusb on:

- `BULK_SCATTER_GATHER` or `NO_PACKET_SIZE_LIM`: a single URB per transfer;
- otherwise the transfer is split into 16384-byte (`MAX_BULK_BUFFER_LENGTH`)
  URBs, with `BULK_CONTINUATION` when the kernel has it and without it when
  it does not.

If the ioctl fails it prints the errno; libusb then assumes
`BULK_CONTINUATION` only (linux_usbfs.c:1344). It is read-only and sends
nothing to the phone; with the variable unset (or anything but `1`) it does
nothing at all. spdhost caps every bulk IN at 16 KiB, which is a single URB
in every one of those branches. Why bigger reads failed on the Android 10 Go
host is not proven yet: run once with `SPDHOST_USB_CAPS=1
SPDHOST_BROM_TRACE=1` and keep the output to settle it.

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
| `SPDHOST_USB_CAPS` | 0 | `1` = print the usbfs capability mask and the libusb bulk path it implies (read-only) |
| `SPD_USB_ATTACHED_GRACE` | 0 | wrapper grace before it gives up on the device |
| `SPD_USB_SKIP_REQUEST` | 0 | `1` = omit `-r` on a warm, already-authorized run |
| `SPD_USB_NO_SYSFS` | 0 | `1` = do not read `idVendor` from sysfs when the listing has no vendor |

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

## Where this deliberately differs from spd_dump

Everything the two tools share is meant to put the same bytes on the wire, and
the sequence tests compare frame for frame against a build of spd_dump. These
are the places where spdhost knowingly does something else:

- **The verbs that only make sense inside spd_dump's own debug loop are not
  ported**: `send`, `write_flash`, `write_word`, `sendloop`, `end_data`,
  `rawdata`, `transcode`, `disable_transcode`, `blk_size`/`bs`,
  `fblk_size`/`fbs`, `nand_id`, `read_pactime`, `baudrate`, `slot`, `timeout`
  and `verbose`. Each is either a raw packet injector, a knob our CLI already
  has as an option (`--timeout`, `--verbose`, `--step`), or, in the case of
  `baudrate`, compiled out of spd_dump itself under `USE_LIBUSB` (`spd_dump.c`
  line 794). Transcode and the loader's raw-data mode are still *honoured* —
  they are read from `Da_Info` and acted on where the reference acts on them
  (`DISABLE_TRANSCODE` after FDL2) — they just cannot be toggled by hand.
- **`--kick` and `--kickto N` are not ported.** spd_dump opens its diag port
  (`boot_diag`/`cali_diag`/`dl_diag`) and writes a 10-byte mode-switch packet to
  it (`ChangeMode`, common.c:2451) to move a phone that came up on a *diagnostic*
  port into download mode. That is a hotplug-and-pick-a-device flow: it needs the
  diag port's own VID/PID, which is not the BootROM's 1782:4d00, and under
  `termux-usb` the device handed to the tool is the one the user already chose,
  so there is no port for spdhost to switch. Put the phone in download mode by
  hand (or with the vendor tool) and spdhost opens it as BootROM. `--wait` is
  the same story one level up: `SPD_USB_WAIT` (default 90 s) is the wrapper's
  wait for the device to appear, which is the whole of what `--wait` does before
  the open loop.
- **`erase_all` and `erase_part all` are not offered.** `spd_dump.c:1068,1088`
  send `erase_partition("all")` after a typed confirmation. spdhost refuses
  `all` in `erase-part` even with `--yes` or `--dangerous`; `danger-erase` is
  the only path to a whole-partition erase, and it is limited to `persist` and
  `splloader` names.
- **`exec` is not a separate verb.** The reference sends `EXEC_DATA` for the
  FDL2 loader from an `exec` command that must follow the two `fdl`s; spdhost's
  second `fdl` sends it itself. `fdl ... fdl ...` therefore reaches FDL2 where
  the reference needs `fdl ... fdl ... exec skip_confirm 1`.
- **`exec_addr` refuses a missing stub; the reference drops it.** spd_dump's
  `exec_addr` path (`spd_dump.c:815`) zeroes `exec_addr` when
  `custom_exec_no_verify_<hex>.bin` is not on disk and then flashes a plain
  download — the run proceeds without the no-verify stub, which is the one
  variable that decides whether FDL1 is signature-checked. spdhost names the
  missing file and stops (rc 1) instead of starting that run.
- **Verb spellings.** The reference's one-letter aliases `r`, `w` and `e` are
  not accepted; they are `dump`, `write-part` and `erase-part` here, and `dump`
  takes an explicit output directory rather than writing to the working
  directory. Wherever the reference spells a verb with an underscore
  (`read_part`, `check_part`, `partition_list`, `read_parts`, `size_part`,
  `w_force`, `keep_charge`, `read_flash`, `read_mem`, `erase_flash`) that
  spelling still works.
- **`skip_confirm` is `--yes`.** The reference's `skip_confirm 1` turns off its
  own typed prompts; spdhost spells that `--yes`, and the menu never passes it.
- **Exit codes.** spd_dump reaches `FDL2 >` and keeps reading commands, so a
  scripted run of it ends on a timeout; spdhost runs the command list and
  exits, nonzero on the first failure unless `--keep-going`.
- **Where the text goes.** spd_dump prints everything, including its table, to
  stderr. spdhost prints command *data* (`print`, `parts`, `part-size`,
  `check-part`, `chip-uid`) to stdout and its progress to stderr, so the output
  can be piped. The messages a test greps for are the same strings.
- **Up to 862 list entries.** spd_dump's partition-list parser stops at 128
  (`spd_dump.c` `dump_partitions`), while the frame it sends can hold 862;
  spdhost takes the larger bound.
- **The standard-GPT parse is bounded where the reference is not.** spd_dump's
  `gpt_info()` trusts whatever the 32 KiB `user_partition` dump happens to
  contain: a header at sector 0 makes its `real_SECTOR_SIZE` zero, it then seeks
  and reads with that, and a table claiming more entries than the dump holds is
  read past the end of the buffer. spdhost refuses the zero-sector header with a
  message, reads only the entries the 32 KiB dump actually contains (and says
  how many it trimmed), caps the count at 4096, and refuses an entry size below
  the 128 bytes a record needs. The tables a real phone answers with are parsed
  identically to the reference — the row names, sizes and the resulting XML are
  byte for byte the same (`tests/gpt-seq.sh` asserts that against the vendored
  spd_dump).
- **A full GPT with no empty entry.** spd_dump calls the count "the index of the
  first entry whose LBA range is all zero" (`common.c:1029`); when every entry is
  used, that index never arrives and its count stays 0, which it then reports as
  no table at all. spdhost takes all the entries in that one case, so the rows
  are not lost. A phone always leaves the array padded with zeroed entries, so
  this only matters for a table packed to the last record.
- **A read the device will not size falls back to the table.** spd_dump's
  `check_partition` returns 0 when the loader refuses to answer, and a
  `read_parts` row of `0xffffffff` then reads nothing. spdhost uses the table's
  own size for that row instead and says so, so a list dumped from one phone
  still reads on a loader that will not answer the probe. `read-part
  splloader 0 -` is the other side of the same coin: the reference refuses the
  name, spdhost keeps its fixed 256 KiB. A name the live table has no row for
  is refused by the reference — it says `part not exist` and skips the row — but
  the single `read-part` still sends the read when an explicit size was given,
  which is how a raw region with no table row is read without inventing a
  partition first. In a `read_parts` **list** the row is skipped instead, by
  both tools (`common.c:1757`).
- **NAND.** spdhost tracks the storage type and honours its consequences
  (no automatic table read, `w-force` refused, no `_bak` twin), but the UBI
  sizing path in `dump_partitions` and the `read_pactime`/NAND-id handling are
  not ported. Read and write on eMMC and UFS are the supported paths.
- **Raw-data writes.** `Da_Info.bSupportRawData` and `dwFlushSize` are parsed
  and reported, but the `ENABLE_RAW_DATA` write protocol is not implemented;
  spdhost writes with the plain protocol, which every loader accepts and which
  puts the same image bytes in the same partition.

## What this is not

Not a replacement for the full `sfd_tool` GUI, PAC flashing, or raw-data
mode. `unpac` lists, checks and extracts a PAC; it does not flash one, and
neither the CLI nor Extra `[16]` will take a PAC as a flash input — extract
it first, then flash the image. Reopen covers a USB reset between
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
