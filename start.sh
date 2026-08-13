#!/bin/sh
# ============================================================================
#  start.sh — mount filesystems and chroot into the Ubuntu rootfs.
#
#  Run from Termux as root (after `su`), from /data/local/tmp.
# ============================================================================
set -eu

UBUNTUPATH="/data/local/tmp/chrootubuntu"

# (Re)create mountpoints if missing.
mkdir -p "$UBUNTUPATH/sdcard" "$UBUNTUPATH/dev/shm"

# Allow setuid binaries on /data (needed for su/sudo inside the chroot).
busybox mount -o remount,dev,suid /data

# Bind the host kernel interfaces into the chroot.
busybox mount --bind /dev  "$UBUNTUPATH/dev"
busybox mount --bind /sys  "$UBUNTUPATH/sys"
busybox mount --bind /proc "$UBUNTUPATH/proc"

# devpts so terminals work inside the chroot.
busybox mount -t devpts devpts "$UBUNTUPATH/dev/pts" 2>/dev/null || true

# /dev/shm (some apps, e.g. Electron, expect it).
busybox mount -t tmpfs -o size=256M tmpfs "$UBUNTUPATH/dev/shm" 2>/dev/null || true

# Bind the sdcard so files are reachable from inside the chroot.
busybox mount --bind /sdcard "$UBUNTUPATH/sdcard" 2>/dev/null || true

# Enter the chroot as root.
busybox chroot "$UBUNTUPATH" /bin/su - root
