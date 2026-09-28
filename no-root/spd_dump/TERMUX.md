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

## Wrapper options and behaviour

`scripts/spd_dump-usb` environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SPD_USB_WAIT` | `90` | Seconds to wait for the device to appear |
| `SPD_WAKE_LOCK` | `1` | Hold a Termux wake lock while running (`0` = off); released on exit |
| `SPD_USB_ANY` | unset | Skip the `1782:4d00` ID check inside `spd_dump` |

- It remembers what was already attached and picks the **new** device, so a
  keyboard or hub on the OTG port no longer aborts the run. With exactly one
  device attached from the start (re-run at the FDL1 stage) it uses that one
  after about 3 seconds. With several and none new, pass the path.
- The exit status of `spd_dump` is passed through. If `spd_dump` never started
  (permission denied, device gone), the wrapper says so and exits 1.
- Works with both termux-api generations: the launcher takes the descriptor
  from `TERMUX_USB_FD` (`-E`) or, on older packages, from its first argument.
- `spd_dump` output goes to stderr so it shows live. `termux-usb` otherwise
  holds a child's stdout until the child exits.
- `termux-usb -l` is time-limited, so a missing or killed Termux:API app gives
  a diagnosis instead of hanging.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Wrapper says `termux-usb did not answer` | Termux:API app missing, from a different source than Termux, or killed by battery optimisation. Open it once; disable battery optimisation for it. |
| `no USB device appeared` | Cable/OTG problem, or the phone is not in download mode. The BootROM only waits a short time; start the wrapper first, then plug in while holding the key combo. |
| Permission dialog appears every time | Expected. Termux:API declares no USB-attach filter, so Android has no default to remember and grants permission per connection. Tap OK within 30 seconds. |
| `libusb_wrap_sys_device failed` | The descriptor is stale (device re-enumerated or replugged). Start again to get a new one. |
| `libusb_claim_interface failed : LIBUSB_ERROR_BUSY` | An earlier run or another app still holds the interface. Unplug, replug into download mode, retry. `spd_dump` now releases the interface on exit, including on error exits. |
| `Device xxxx:yyyy is not a Spreadtrum/Unisoc download-mode device` | Wrong device selected, or the phone is in a different mode. Pass the right `/dev/bus/usb/N/M`, or `SPD_USB_ANY=1` to override. |
| `spd_dump never started` | Read the `termux-usb` line above it (`Permission denied.`, `No such device.`, `Open device failed.`). |

`termux-usb` also accepts `vendorId productId` instead of a path, but the
current Termux:API app source does not read those fields, so the wrapper always
uses the `/dev/bus/usb/N/M` path from `termux-usb -l`.

## Related

- Seuj09 **spdhost** (protocol/hello hardening): [`../`](../) — same `termux-usb -E` contract (`SPD_USB_FD` alias).
- Prebuilt arm32 package: release tag `spd_dump-termux` on this repo.
