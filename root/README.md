# Root method

Use the `spd_dump` tool on a rooted device — **arm64 build for Termux**.

This is the chroot path. The no-root client is
[spdhost](../no-root/README.md). The repo index is the
[top README](../README.md).

## ⚠️ Disclaimer

> I'm not responsible for bricked devices, dead SD cards, thermonuclear war,
> or you getting fired because the alarm app failed (like it did for me...).
> Please do some research if you have any concerns about the features included
> in the products you find here before flashing them!
>
> **YOU** are choosing to make these modifications, and if you point the
> finger at me for messing up your device, I will laugh at you.
>
> Your warranty will be void if you tamper with any part of your device/software.

## Requirements

- A rooted phone
- Termux
- Internet connection

## Setup

### 1. Set up the chroot

Follow the [Chroot tutorial](Chroot_tutorial.md) first.

### 2. Update packages and install build tools

```bash
apt update && apt upgrade -y
```

Wait until it finishes, then install the drivers:

```bash
sudo apt-get install build-essential libusb-1.0-0-dev git wget curl unzip zip
```

### 3. Download and extract the tools

```bash
curl -L -O https://github.com/Seuj09/Spd_dump_termux/releases/download/Release/spreadtrum_flash_termux_arm64.zip
unzip spreadtrum_flash_termux_arm64.zip
cd spreadtrum_flash_termux
```

> The host binaries and scripts already ship with the executable bit set inside
> the zip. If you ever need to re-set it:
>
> ```bash
> chmod +x spd_dump chsize gen_fdl1-dl gen_spl-unlock gen_spl-unlock-legacy \
>          pacextractor unpac menu.sh extrac.sh misc-fastbootd.bin misc-wipe.bin
> ```

## Usage

Run the menu, then choose your phone and chipset. A menu will appear — choose
the option you want:

```bash
./menu.sh
```

## Limitations

- **`spdfl` is not included.** It is a closed-source x86-64 binary with no
  public source, so it cannot run on arm64. Use `./menu.sh` instead — the menu
  drives `spd_dump` directly.
- **`pacextractor` and `unpac` are still x86-64.** They have no public source,
  so they could not be rebuilt for arm64. They are only used by `extrac.sh` for
  PAC-archive extraction; the main flash/unlock flow does not depend on them.
- **V35 device folders are empty.** The new tool's per-device directories ship
  without `fdl*.bin` firmware, so device coverage is unchanged from the original
  tool. If your device isn't listed, you'll need to supply its `fdl` firmware
  yourself.

## Credits

- **[TomKing062](https://github.com/TomKing062/CVE-2022-38694_unlock_bootloader)** —
  the open-source CVE-2022-38694 unlock-bootloader toolchain, source of the
  arm64 `spd_dump`, `chsize`, `gen_fdl1-dl`, `gen_spl-unlock`, and
  `gen_spl-unlock-legacy` binaries and the unlock method.
- **[Massatriof16](https://github.com/Massatriof16/recovery-collections)** —
  the Spreadtrum Flash V35 tool, which provided the tool layout used here.
- The **Spreadtrum/Unisoc reverse-engineering community** for the underlying
  flashing research and `fdl` firmware.
