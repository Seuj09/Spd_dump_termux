# spdhost setup tutorial (Termux, no root)

## You need

- **Termux** and **Termux:API**, both from F-Droid (install both from the same source).
- An **OTG adapter** that puts the host phone in USB host mode.
- The **target** phone powered off.

The *host* is the phone running Termux. The *target* is the phone you flash, in download mode.

## 1. Install packages

```sh
pkg update -y && pkg install -y termux-api unzip curl
termux-setup-storage
```

## 2. Download and unzip spdhost

Check your Termux architecture with `uname -m`.

**64-bit** (`aarch64`):

```sh
curl -LO https://github.com/Seuj09/Spd_dump_termux/releases/download/spdhost-exp-audit-f616c0f/spdhost-arm64-static-f616c0f.zip
unzip -o spdhost-arm64-static-f616c0f.zip -d ~ && cd ~/spdhost-arm64
```

**32-bit** (`armv7l` or `armv8l`):

```sh
curl -LO https://github.com/Seuj09/Spd_dump_termux/releases/download/spdhost-exp-audit-f616c0f/spdhost-arm32-static-f616c0f.zip
unzip -o spdhost-arm32-static-f616c0f.zip -d ~ && cd ~/spdhost-arm32
```

Newer builds are on the [releases page](https://github.com/Seuj09/Spd_dump_termux/releases).

## 3. Start the menu

```sh
bash scripts/menu.sh
```

## 4. Connect the target

1. Pick a menu option and press Enter.
2. Hold the target's download-mode keys and plug it in through OTG.
3. Tap **Allow** on the USB prompt as fast as you can.
4. If the first try times out, unplug, wait about 5 seconds, and retry. Later runs usually skip the prompt.

## 5. Always dump first

Back up boot, misc and any partition you plan to touch before you write anything.

## One-line dump without the menu (Infinix ums9230)

Run from the unzipped folder:

```sh
bash scripts/spdhost-usb exec_addr 0x65015f08 fdl/ums9230/custom_exec_no_verify_65015f08.bin fdl fdl/ums9230/infinix/fdl1-dl.bin 0x65000800 fdl fdl/ums9230/infinix/fdl2-dl.bin 0x9efffe00 parts read-part boot_a 0 full ~/boot_a.img
```

- For another brand, swap `infinix` for its folder under `fdl/ums9230/` (universal, tecno, realme, itel, or an `alternatif/<model>` pair).
- Swap `boot_a` for any name from the `parts` list, and the last argument for the output file.

## Detection timing out?

Run this and include the full output in your report:

```sh
SPDHOST_USB_CAPS=1 SPDHOST_BROM_TRACE=1 bash scripts/spdhost-usb ping
```

See also the [FAQ](FAQ.md).
