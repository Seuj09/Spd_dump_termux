# Spd_dump_termux

Ways to run a Spreadtrum/Unisoc download-mode tool from an Android phone.

| | Root | No root (spdhost) | No root (TomKing spd_dump) |
| --- | --- | --- | --- |
| What you run | Ubuntu chroot + arm64 `spd_dump` | Seuj09 `spdhost` | Vendored TomKing `spd_dump` |
| Needs | Magisk (or similar) + busybox | Termux + Termux:API (F-Droid) | Same Termux + Termux:API |
| USB access | root opens `/dev/bus/usb` | `termux-usb` FD | `termux-usb` FD (`--usb-fd` / env) |
| Guide | [root/README.md](root/README.md) | [no-root/README.md](no-root/README.md) | [no-root/spd_dump/TERMUX.md](no-root/spd_dump/TERMUX.md) |

Flashing the wrong loader or partition can brick a phone. Read the disclaimer
in the guide you follow before you connect a device.

## Root

Chroot Ubuntu on the phone, then run the existing arm64 `spd_dump` menu.
Start at the [chroot tutorial](root/Chroot_tutorial.md), then the
[root guide](root/README.md).

## No root — spdhost

Build `spdhost` with Termux's clang and libusb. The wrapper
`scripts/spdhost-usb` asks Termux:API for the OTG device and passes the
descriptor in. Details: [no-root guide](no-root/README.md).

## No root — TomKing spd_dump

Full TomKing client, vendored under [`no-root/spd_dump/`](no-root/spd_dump/)
(pin `f2fc779` + Termux FD patches). Prebuilt arm32 zip on release tag
[`spd_dump-termux`](https://github.com/Seuj09/Spd_dump_termux/releases/tag/spd_dump-termux).
Guide: [TERMUX.md](no-root/spd_dump/TERMUX.md).
