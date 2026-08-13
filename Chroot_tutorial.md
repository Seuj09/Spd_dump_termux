# Chroot Ubuntu (Termux) — Setup Guide

Set up an Ubuntu 22.04 rootfs inside a chroot on a rooted Android device, then
use it to run the `spd_dump` tools.

> **⚠️ Do this at your own risk.** Flashing/unlocking a device can brick it.
> See the disclaimer in the main [README](README.md).

---

## Requirements

- A **rooted** phone (root access via Magisk/SuperSU).
- **Termux** installed (from [GitHub](https://github.com/termux/termux-app) or [F-Droid](https://f-droid.org/en/packages/com.termux/)).
- **busybox** and a downloader (`wget` or `curl`).
- An internet connection.

---

## Method 1 — Automated (`setup.sh`) *(recommended)*

One command does everything: download the rootfs, extract it, write the
`start.sh` entry script, and run the first-time in-chroot setup.

```sh
# In Termux:
pkg update && pkg install -y busybox wget
su                                   # grant root to Termux
sh setup.sh
```

When it finishes, enter the chroot any time with:

```sh
su
sh /data/local/tmp/start.sh
```

Your prompt will change to `root@localhost:~#` — you're now inside Ubuntu.

---

## Method 2 — Manual

### 1. Install Termux and busybox

Install Termux, then inside it:

```sh
pkg update && pkg install -y busybox
su          # grant root permission to Termux
```

### 2. Create the chroot directory

```sh
mkdir -p /data/local/tmp/chrootubuntu
cd /data/local/tmp/chrootubuntu
```

### 3. Download the Ubuntu 22.04 rootfs

```sh
busybox wget https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz
```

If `wget` fails:

```sh
busybox curl -o ubuntu-base-22.04-base-arm64.tar.gz \
  https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz
```

### 4. Extract and create mountpoints

```sh
tar xf ubuntu-base-22.04-base-arm64.tar.gz
mkdir -p dev/shm sdcard
cd ..
```

### 5. Create the entry script (`start.sh`)

Create `/data/local/tmp/start.sh` with the content below (or copy the
`start.sh` provided in this repo):

```sh
#!/bin/sh
set -eu
UBUNTUPATH="/data/local/tmp/chrootubuntu"
mkdir -p "$UBUNTUPATH/sdcard" "$UBUNTUPATH/dev/shm"
busybox mount -o remount,dev,suid /data
busybox mount --bind /dev  "$UBUNTUPATH/dev"
busybox mount --bind /sys  "$UBUNTUPATH/sys"
busybox mount --bind /proc "$UBUNTUPATH/proc"
busybox mount -t devpts devpts "$UBUNTUPATH/dev/pts" 2>/dev/null || true
busybox mount -t tmpfs -o size=256M tmpfs "$UBUNTUPATH/dev/shm" 2>/dev/null || true
busybox mount --bind /sdcard "$UBUNTUPATH/sdcard" 2>/dev/null || true
busybox chroot "$UBUNTUPATH" /bin/su - root
```

> To create the file with `vi`: `vi start.sh`, press `i` to insert, paste the
> text, then `Esc` → `:wq` → `Enter`.

Make it executable and run it:

```sh
chmod +x start.sh
./start.sh
```

Your prompt changes from `$` to `root@localhost:~#` — you're in Ubuntu now.

### 6. First-time in-chroot setup

Run these once inside the chroot to fix DNS, add Android uid groups, and
install the base packages:

```sh
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "127.0.0.1 localhost" > /etc/hosts

groupadd -g 3003 aid_inet
groupadd -g 3004 aid_net_raw
groupadd -g 1003 aid_graphics
usermod -G 3003,3004 -a _apt
usermod -G 3003 -a root

apt update
apt upgrade -y
apt install -y nano vim net-tools sudo git
```

### 7. Install the spd_dump libraries

Follow the steps in the main [README](README.md) to install the build tools
and download the `spd_dump` package.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `busybox: not found` | `pkg install busybox` |
| `Permission denied` / mount fails | Run as root: type `su` first |
| `setuid` / `sudo` broken in chroot | Ensure `busybox mount -o remount,dev,suid /data` ran |
| No internet inside chroot | Re-run the `resolv.conf` step above |
| Wrong architecture download | Set `ARCH=armhf` (or `amd64`) before running `setup.sh` |

## Notes

- The rootfs and scripts live under `/data/local/tmp/` (a writable, non-PIE
  area reachable via `su`).
- `start.sh` is safe to re-run; it re-binds the mounts before entering.
