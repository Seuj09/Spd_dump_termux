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

## 1b. Grant permissions to both apps

- **Termux:** `termux-setup-storage` asks for file access. Allow it, so the menu can read images and save dumps on `/sdcard`.
- **Termux:API:** open its app info (Settings → Apps → Termux:API) and:
  - turn off battery restrictions (set battery usage to *Unrestricted*), and
  - allow **Display over other apps**.

Without these, the USB permission prompt and device handoff can fail or get killed in the background.

## 2. Download and unzip spdhost

Check your Termux architecture with `uname -m`: `aarch64` is 64-bit, `armv7l` or
`armv8l` is 32-bit.

The commands below fetch the **spdhost-exp-audit6** pre-release of the
`experiment/brom-hello-diagnostics` branch (not an older `spdhost-exp-audit-f616c0f`,
`spdhost-exp-audit4-*` or `spdhost-exp-multidev-*` zip — those still have bugs this
tutorial treats as fixed). Paste them as they are.

**64-bit** (`aarch64`):

```sh
TAG=spdhost-exp-audit6-79d7cd0
ZIP=spdhost-arm64-static-79d7cd0.zip
curl -fLO "https://github.com/Seuj09/Spd_dump_termux/releases/download/${TAG}/${ZIP}"
unzip -o "$ZIP" -d ~ && cd ~/spdhost-arm64
```

**32-bit** (`armv7l` or `armv8l`):

```sh
TAG=spdhost-exp-audit6-79d7cd0
ZIP=spdhost-arm32-static-79d7cd0.zip
curl -fLO "https://github.com/Seuj09/Spd_dump_termux/releases/download/${TAG}/${ZIP}"
unzip -o "$ZIP" -d ~ && cd ~/spdhost-arm32
```

The zip also holds this tutorial, the [FAQ](FAQ.md) and the README. Building from
source (`make -C no-root`) on the tip of that branch is also fine.

## 3. Start the menu

```sh
bash scripts/menu.sh
```

## 4. Connect the target

The order matters (it is the same as in the [FAQ](FAQ.md)):

1. Pick a menu option and press Enter. The target stays **off and unplugged**.
2. If the target still boots, hold power for about 8 seconds so it is fully off.
3. Wait until the menu says **Plug the target in NOW**.
4. Only then hold the target's download-mode keys and plug the cable in through OTG. On many Unisoc phones (Infinix, for example) that is **power + volume down**; other models use volume up, both volume keys, or a boot key, so use whatever your model needs.
5. Tap **Allow** on the USB permission dialog as soon as it appears. It appears on **every** plug-in.
6. If it times out, unplug, wait at least 5 seconds, and run the same option again from step 1.

If the target is bricked and won't turn on: unplug, restart the menu, hold the download-mode keys for 6-8 seconds, then plug in at the prompt.

## 5. Always dump first

Back up boot, misc and any partition you plan to touch before you write anything.
Images land alone in the dump folder; the parts table, XML, manifest, slotinfo, backups and `SHA256SUMS` go under `meta/` inside it. To check a dump, from the dump folder:

```sh
cd /sdcard/Download && sha256sum -c meta/SHA256SUMS
```

## One-line dump without the menu (Infinix ums9230)

Run from the unzipped folder:

```sh
bash scripts/spdhost-usb exec_addr 0x65015f08 fdl/ums9230/custom_exec_no_verify_65015f08.bin fdl fdl/ums9230/infinix/fdl1-dl.bin 0x65000800 fdl fdl/ums9230/infinix/fdl2-dl.bin 0x9efffe00 parts read-part boot 0 full ~/boot.img
```

- For another brand, swap `infinix` for its folder under `fdl/ums9230/` (universal, tecno, realme, itel, or an `alternatif/<model>` pair).
- `boot` is resolved against the live table: on an A/B phone it reads `boot_a` or `boot_b` for the active slot, and on a non-A/B phone it reads plain `boot`. Name a slot explicitly (`boot_b`) only if the `parts` list has it.
- Swap `boot` for any name from the `parts` list, and the last argument for the output file.

## Other chips: ums512 and sc9863a

The FDL1 address and the exec stub belong to the chip. Menu option 3 sets all of them when you pick a chip and brand. spdhost refuses a stub that doesn't match the FDL1 address.

| Chip | FDL1 address | Exec stub (hex mode 2) | FDL2 address |
|---|---|---|---|
| ums9230 | `0x65000800` | `0x65015f08` (`0x65015f48`) | `0x9efffe00` |
| ums512 | `0x5500` | `0x3ee8` (`0x3f48`) | `0x9efffe00` |
| sc9863a | `0x5000` | `0x4ee8` (`0x4f48`) | `0x9efffe00` |

ums512 (Infinix; `realme` works the same way):

```sh
bash scripts/spdhost-usb exec_addr 0x3ee8 fdl/ums512/custom_exec_no_verify_3ee8.bin fdl fdl/ums512/infinix/fdl1-dl.bin 0x5500 fdl fdl/ums512/infinix/fdl2-dl.bin 0x9efffe00 parts
```

sc9863a (realme; `itel` works the same way):

```sh
bash scripts/spdhost-usb exec_addr 0x4ee8 fdl/sc9863a/custom_exec_no_verify_4ee8.bin fdl fdl/sc9863a/realme/fdl1-dl.bin 0x5000 fdl fdl/sc9863a/realme/fdl2-dl.bin 0x9efffe00 parts
```

## Slot changes and recovery

- Menu Extra [2] changes the active slot in **one** session. spdhost reads misc, patches the slot block, writes the whole misc back and checks it. The other slot keeps its tries and its successful-boot flag.
- Slot **b** is often empty on these phones. Before a recovery ending, spdhost checks `boot_b`/`vbmeta_b` and warns if they look blank.
- **fastbootd** lives inside recovery and needs an Android 10+ recovery. Older phones only have plain recovery.
- If the menu says misc verified OK but the reset didn't complete, misc already holds the change. Hold power to restart.

## Detection timing out?

Run this and include the full output in your report:

```sh
SPDHOST_USB_CAPS=1 SPDHOST_BROM_TRACE=1 bash scripts/spdhost-usb ping
```

See also the [FAQ](FAQ.md).
