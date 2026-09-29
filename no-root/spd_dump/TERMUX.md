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

**Gate:** CHECK_BAUD → SPRD3 → FDL1 load/exec. Keep `exec_addr` + FDL1/FDL2
paths as below; FDL2 SEND success is **out of scope** (may still time out).

Cold-plug target in download mode (BootROM `1782:4d00`). Grant the USB
permission dialog immediately.

Before FDL1 smoke, optionally re-prove BootROM hello-only with **spdhost**
(tip `c4e79d8` / menu `1`×`3` or `2`×`3` — see
[`../README.md`](../README.md) BootROM hello debug). That is a hello-only
diagnostic; it does not replace the `spd_dump-usb` FDL1 gate below.

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

### Warm Allow / pre-grant recipe (`spd_dump-usb`)

Same wrapper knobs as `spdhost-usb`. First session keeps `-r`. After Android
has authorized this host↔device pairing at least once, cold-unplug ≥5 s, then
skip redundant `-r`:

```bash
cd ~/Spd_dump_termux/no-root/spd_dump

# First session: normal grant (default keeps -r)
./scripts/spd_dump-usb --verbose 1 \
  exec_addr 0x65015f08 \
  fdl ../fdl/ums9230/infinix/fdl1-dl.bin 0x65000800 \
  fdl ../fdl/ums9230/infinix/fdl2-dl.bin 0x9efffe00 \
  exec

# Warm already-authorized (cold-unplug ≥5s first):
SPD_USB_SKIP_REQUEST=1 ./scripts/spd_dump-usb --verbose 1 \
  exec_addr 0x65015f08 \
  fdl ../fdl/ums9230/infinix/fdl1-dl.bin 0x65000800 \
  fdl ../fdl/ums9230/infinix/fdl2-dl.bin 0x9efffe00 \
  exec
```

**Warn:** if the grant was never given, `SPD_USB_SKIP_REQUEST=1` fails open —
keep default `-r` for a cold first plug. Correlate always-on `usb:` millis
(`listed` → `termux-usb -e start` → `child start`) with device-side progress.

## Raw termux-usb (advanced)

`spd_dump-usb` is a thin poll + single combined `termux-usb … -e` wrapper
(default includes `-r`; optional `SPD_USB_SKIP_REQUEST=1` omits `-r`).
Equivalent one-shot once you know the bus path:

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
| `SPD_USB_ATTACHED_GRACE` | `0` | Seconds before accepting an already-attached single device (was ~3s); cold new-device path unchanged |
| `SPD_USB_SKIP_REQUEST` | unset/`0` | `1` = omit `termux-usb -r` (warm already-authorized only); default keeps `-r` |
| `SPD_USB_LIST_TIMEOUT` | `8` | Timeout seconds for each `termux-usb -l` |
| `SPD_USB_ANY` | unset | Skip the `1782:4d00` ID check inside `spd_dump` |

Always-on thin stderr timing (no env needed):

- `usb: listed $dev @Xms`
- `usb: termux-usb -e start @Yms`
- `usb: child start fd=N @Zms`

Behaviour notes:

- Prefers package-local `./spd_dump` before PATH.
- Remembers what was already attached and picks the **new** device, so a
  keyboard or hub on the OTG port no longer aborts the run. With exactly one
  device attached from the start (re-run at the FDL1 stage) it uses that one
  after `SPD_USB_ATTACHED_GRACE` (default **0**). With several and none new,
  pass the path.
- Keeps a **single** combined `termux-usb … -e` round (does not split
  request vs exec).
- Passes `--usb-fd` as the **next** argument (not last-argv); `spd_dump` also
  accepts env `TERMUX_USB_FD` / `SPD_USB_FD`.
- The exit status of `spd_dump` is passed through. If `spd_dump` never started
  (permission denied, device gone), the wrapper says so and exits 1.
- Works with both termux-api generations: the launcher takes the descriptor
  from `TERMUX_USB_FD` (`-E`) or, on older packages, from its first argument.
- `spd_dump` output goes to stderr so it shows live. `termux-usb` otherwise
  holds a child's stdout until the child exits.
- `termux-usb -l` is time-limited, so a missing or killed Termux:API app gives
  a diagnosis instead of hanging.

## Post-EXEC re-termux reconnect (P4 — deferred)

**Not in this release.** Full post-bus-leave reconnect SM (close → wait unique
`1782`, prefer `4d00` → re-`termux-usb` → new wrap; refuse multi-device
auto-pick; never mid-hello) is held until the FDL1 gate is green. See
[`../README.md`](../README.md) “Post-FDL reconnect SM (P4 — deferred)” and
existing spdhost helpers `grab_termux` / `spd_usb_reacquire` (docs pointer
only — `spd_dump` does not ship that SM here).

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Wrapper says `termux-usb did not answer` | Termux:API app missing, from a different source than Termux, or killed by battery optimisation. Open it once; disable battery optimisation for it. |
| `no USB device appeared` | Cable/OTG problem, or the phone is not in download mode. The BootROM only waits a short time; start the wrapper first, then plug in while holding the key combo. |
| Permission dialog appears every time | Expected with default `-r`. Termux:API declares no USB-attach filter, so Android grants per connection. Tap OK within 30 seconds. Warm path: after a successful Allow + cold-unplug ≥5 s, try `SPD_USB_SKIP_REQUEST=1`. |
| `SPD_USB_SKIP_REQUEST=1` and never started | Grant was never given for this pairing — unset SKIP and retry with default `-r`. |
| `libusb_wrap_sys_device failed` | The descriptor is stale (device re-enumerated or replugged). Start again to get a new one. |
| `libusb_claim_interface failed : LIBUSB_ERROR_BUSY` | An earlier run or another app still holds the interface. Unplug, replug into download mode, retry. `spd_dump` now releases the interface on exit, including on error exits. |
| `Device xxxx:yyyy is not a Spreadtrum/Unisoc download-mode device` | Wrong device selected, or the phone is in a different mode. Pass the right `/dev/bus/usb/N/M`, or `SPD_USB_ANY=1` to override. |
| `spd_dump never started` | Read the `termux-usb` line above it (`Permission denied.`, `No such device.`, `Open device failed.`). |
| A BootROM/FDL reply seems to go missing right at the edge of a timeout | `spd_dump` used to discard any bytes libusb returned together with `LIBUSB_ERROR_TIMEOUT`, even when some had actually arrived. It now keeps them instead of returning empty — a real reply landing a few ms after the timeout fired is no longer silently dropped (`recv_msg_orig` and all three `ChangeMode` bulk-IN reads). |

`termux-usb` also accepts `vendorId productId` instead of a path, but the
current Termux:API app source does not read those fields, so the wrapper always
uses the `/dev/bus/usb/N/M` path from `termux-usb -l`.

## Related

- Seuj09 **spdhost** (protocol/hello hardening): [`../`](../) — same `termux-usb -E` contract (`SPD_USB_FD` alias); BootROM hello debug + warm recipe in [`../README.md`](../README.md).
- Prebuilt arm32 package: release tag `spd_dump-termux` on this repo.
