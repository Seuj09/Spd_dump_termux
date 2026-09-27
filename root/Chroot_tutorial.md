# Chroot Ubuntu (Termux) — Setup Guide

Set up an Ubuntu 22.04 rootfs inside a chroot on a rooted Android device, then
use it to run the `spd_dump` tools.

> **⚠️ Do this at your own risk.** Flashing/unlocking a device can brick it.
> See the disclaimer in the main [README](README.md).

---

## Requirements

- A **rooted** phone (root access via Magisk/SuperSU).
- **Termux** installed (from [GitHub](https://github.com/termux/termux-app) or
  [F-Droid](https://f-droid.org/en/packages/com.termux/)).
- A **busybox** binary reachable from the **root shell** (see Step 0).
- A downloader (`wget` or `curl`).
- An internet connection.

---

## Step 0 — Install busybox for the root shell

> ⚠️ `pkg install busybox` only works **inside Termux**. Its binary lives at
> `/data/data/com.termux/files/usr/bin/busybox`, which is **not** on the `PATH`
> of the root shell you get after `su`. The `mount`/`chroot` commands in
> `setup.sh` and `start.sh` run as root, so they need a `busybox` the root
> shell can find.

**Recommended:** install a **Magisk busybox module** (e.g. *Busybox for
Android NDK* by osm0sis). It places `busybox` at `/system/xbin/busybox`, which
both scripts auto-detect.

Verify it is reachable from root:

```sh
su
busybox | head -1
```

If that prints the busybox banner, you are good to go. The scripts probe
several common module locations and fall back to whatever is on `PATH`, so a
non-standard path still works.

---

## Step 1 — Get the scripts

Download `setup.sh` into `/data/local/tmp` (it writes `start.sh` for you):

```sh
su
cd /data/local/tmp
curl -L -O https://raw.githubusercontent.com/Seuj09/Spd_dump_termux/main/root/setup.sh
chmod +x setup.sh
```

> If you only need the entry script (e.g. the chroot is already set up), grab
> `start.sh` the same way:
>
> ```sh
> curl -L -O https://raw.githubusercontent.com/Seuj09/Spd_dump_termux/main/root/start.sh
> chmod +x start.sh
> ```

---

## Method 1 — Automated (`setup.sh`) *(recommended)*

One command downloads the rootfs, extracts it, writes `start.sh`, and runs the
first-time in-chroot setup:

```sh
su
cd /data/local/tmp
sh setup.sh
```

When it finishes, enter the chroot any time with:

```sh
su
sh /data/local/tmp/start.sh
```

Your prompt will change to `root@localhost:~#` — you are now inside Ubuntu.

---

## Method 2 — Manual

### 1. Create the chroot directory

```sh
su
mkdir -p /data/local/tmp/chrootubuntu
cd /data/local/tmp/chrootubuntu
```

### 2. Download the Ubuntu 22.04 rootfs

```sh
busybox wget https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz
```

If `wget` fails:

```sh
busybox curl -o ubuntu-base-22.04-base-arm64.tar.gz \
  https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz
```

### 3. Extract and create mountpoints

```sh
tar xf ubuntu-base-22.04-base-arm64.tar.gz
mkdir -p dev/shm sdcard
cd ..
```

### 4. Get the entry script (`start.sh`)

Either download it (recommended):

```sh
curl -L -O https://raw.githubusercontent.com/Seuj09/Spd_dump_termux/main/root/start.sh
chmod +x start.sh
```

Or create `/data/local/tmp/start.sh` yourself with the content from
[`start.sh`](start.sh) in this repo.

> To create it with `vi`: `vi start.sh`, press `i` to insert, paste the text,
> then `Esc` → `:wq` → `Enter`.

### 5. Run it

```sh
./start.sh
```

Your prompt changes from `$` to `root@localhost:~#` — you are in Ubuntu now.

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
| `busybox: not found` (as root) | Install a busybox **module** — see Step 0 |
| `busybox: not found` (in Termux) | `pkg install busybox` |
| `Permission denied` / mount fails | Run as root: type `su` first |
| `setuid` / `sudo` broken in chroot | Ensure `busybox mount -o remount,dev,suid /data` ran |
| No internet inside chroot | Re-run the `resolv.conf` step above |
| Wrong architecture download | Set `ARCH=armhf` (or `amd64`) before running `setup.sh` |
| Scripts not found | Follow **Step 1** to download them into `/data/local/tmp` |

## Notes

- The rootfs and scripts live under `/data/local/tmp/` (a writable area
  reachable via `su`).
- `start.sh` is safe to re-run; it re-binds the mounts before entering.
- `setup.sh` is safe to re-run; existing downloads and the extracted rootfs
  are reused.
