# Spd_dump_termux

Use the `spd_dump` tool on a rooted device.

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
curl -L -O https://github.com/Seuj09/Spd_dump_termux/releases/download/Release/spreadtrum_flash_termux.zip
unzip spreadtrum_flash_termux.zip
cd spreadtrum_flash_termux
```

### 4. Make the binaries executable

```bash
chmod +x spd_dump
chmod +x menu.sh
chmod +x gen_spl-unlock
chmod +x gen_spl-unlock-legacy
chmod +x gen_fdl1-dl
chmod +x misc-fastbootd.bin
chmod +x misc-wipe.bin
```

## Usage

Run the menu, then choose your phone and chipset. A menu will appear — choose
the option you want:

```bash
./menu.sh
```
