# Spd_dump_termux

Two ways to run a Spreadtrum/Unisoc download-mode tool from an Android phone.
They are separate because they need different privileges.

| | Root | No root |
| --- | --- | --- |
| What you run | Ubuntu chroot + the arm64 `spd_dump` build | `spdhost`, built in Termux |
| Needs | Magisk (or similar) and a busybox module | Termux and Termux:API, both from F-Droid |
| USB access | root can open `/dev/bus/usb` | `termux-usb` hands over one open file descriptor |
| Guide | [root/README.md](root/README.md) | [no-root/README.md](no-root/README.md) |

Flashing the wrong loader or partition can brick a phone. Read the disclaimer
in the guide you follow before you connect a device.

## Root

Chroot Ubuntu on the phone, then run the existing arm64 `spd_dump` menu.
Start at the [chroot tutorial](root/Chroot_tutorial.md), then the
[root guide](root/README.md).

## No root

Build `spdhost` with Termux's clang and libusb. No chroot. The wrapper
`scripts/spdhost-usb` asks Termux:API for the OTG device and passes the
descriptor in. Details are in the [no-root guide](no-root/README.md).
