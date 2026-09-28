# Termux + termux-usb (TomKing spd_dump)

Product path for BootROM → SPRD3 → FDL1 on an unrooted Android **host** phone.
Uses Termux + Termux:API (`termux-usb`) to hand an open usbfs FD to `spd_dump`.

**Out of scope for v1:** FDL2 SEND timeout / full flash success. Stop at FDL1 OK.

## Pin

Sources are TomKing `f2fc779210d9e4b5ca1904c79a49cc5e114b58f3`
(`put FindPort in loop`), plus Termux FD fixes (see `PIN.txt`):

- `--usb-fd N` as the **next** argument (normal parse)
- Legacy last-argv fallback for `termux-usb -e "./spd_dump --usb-fd"`
- If no `--usb-fd`, adopt `TERMUX_USB_FD` or `SPD_USB_FD` from the environment
  (what `termux-usb -E` exports)
- `libusb_wrap_sys_device` + `LIBUSB_OPTION_NO_DEVICE_DISCOVERY` (already at pin)

## Build on Termux

```bash
# Termux + Termux:API from F-Droid
pkg install termux-api clang make libusb git
git clone https://github.com/Seuj09/Spd_dump_termux.git
cd Spd_dump_termux/no-root/spd_dump
make
```

Or use a prebuilt from the `spd_dump-termux` release (arm32 zip).

## FDL assets (ums9230 / Infinix)

Loaders live next door in this same repo:

```bash
# from no-root/spd_dump/
ls ../fdl/ums9230/infinix/fdl1-dl.bin ../fdl/ums9230/infinix/fdl2-dl.bin
```

Release zips ship a copy under `fdl/ums9230/infinix/`.

## Smoke (BootROM → FDL1)

Cold-plug target in download mode (BootROM `1782:4d00`). Grant the USB
permission dialog immediately.

```bash
cd ~/Spd_dump_termux/no-root/spd_dump   # or unzipped spd_dump-arm32/

./scripts/spd_dump-usb --verbose 1 \
  exec_addr 0x65015f08 \
  fdl ../fdl/ums9230/infinix/fdl1-dl.bin 0x65000800 \
  fdl ../fdl/ums9230/infinix/fdl2-dl.bin 0x9efffe00 \
  exec
```

From a release zip package root (`spd_dump-arm32/`):

```bash
./scripts/spd_dump-usb --verbose 1 \
  exec_addr 0x65015f08 \
  fdl ./fdl/ums9230/infinix/fdl1-dl.bin 0x65000800 \
  fdl ./fdl/ums9230/infinix/fdl2-dl.bin 0x9efffe00 \
  exec
```

Expect: permission grant → CHECK_BAUD / SPRD3 handshake → FDL1 load/exec.
FDL2 SEND may still time out — that is **out of scope** for this gate.

## Raw termux-usb (advanced)

`spd_dump-usb` is a thin poll + `termux-usb -r -E -e` wrapper. Equivalent
one-shot once you know the bus path:

```bash
termux-usb -r -E -e ./spd_dump /dev/bus/usb/N/M --verbose 1 \
  exec_addr 0x65015f08 \
  fdl ../fdl/ums9230/infinix/fdl1-dl.bin 0x65000800 \
  fdl ../fdl/ums9230/infinix/fdl2-dl.bin 0x9efffe00 \
  exec
```

Legacy append style (still supported):

```bash
termux-usb -e "./spd_dump --usb-fd" /dev/bus/usb/N/M
```

Or pass the FD explicitly:

```bash
./spd_dump --usb-fd "$TERMUX_USB_FD" --verbose 1 exec_addr 0x65015f08 ...
```

## Related

- Seuj09 **spdhost** (protocol/hello hardening): [`../`](../) — same `termux-usb -E` contract (`SPD_USB_FD` alias).
- Prebuilt arm32 package: release tag `spd_dump-termux` on this repo.
