#!/bin/sh
# ============================================================================
#  start.sh — mount filesystems and chroot into the Ubuntu rootfs.
#
#  Run from Termux as root (after `su`), from /data/local/tmp.
#
#  Requires a `busybox` binary reachable from the ROOT shell. Termux's own
#  busybox (/data/data/com.termux/files/usr/bin/busybox) is usually NOT on the
#  root PATH, so this script probes common Magisk/module install locations
#  first. See Chroot_tutorial.md (Step 0).
# ============================================================================
set -eu

UBUNTUPATH="/data/local/tmp/chrootubuntu"

# Locate a usable busybox.
find_busybox() {
  for p in /system/xbin/busybox /system/bin/busybox /su/xbin/busybox \
           /sbin/.magisk/busybox/busybox /data/adb/magisk/busybox \
           /data/data/com.termux/files/usr/bin/busybox
  do
    [ -x "$p" ] && { BB="$p"; return 0; }
  done
  command -v busybox >/dev/null 2>&1 && { BB="busybox"; return 0; }
  echo "busybox not found for the root shell." >&2
  echo "Install a busybox module (e.g. Magisk 'Busybox for Android NDK')." >&2
  return 1
}
find_busybox

# (Re)create mountpoints if missing.
mkdir -p "$UBUNTUPATH/sdcard" "$UBUNTUPATH/dev/shm"

# Allow setuid binaries on /data (needed for su/sudo inside the chroot).
"$BB" mount -o remount,dev,suid /data

# Bind the host kernel interfaces into the chroot.
"$BB" mount --bind /dev  "$UBUNTUPATH/dev"
"$BB" mount --bind /sys  "$UBUNTUPATH/sys"
"$BB" mount --bind /proc "$UBUNTUPATH/proc"

# devpts so terminals work inside the chroot.
"$BB" mount -t devpts devpts "$UBUNTUPATH/dev/pts" 2>/dev/null || true

# /dev/shm (some apps, e.g. Electron, expect it).
"$BB" mount -t tmpfs -o size=256M tmpfs "$UBUNTUPATH/dev/shm" 2>/dev/null || true

# Bind the sdcard so files are reachable from inside the chroot.
"$BB" mount --bind /sdcard "$UBUNTUPATH/sdcard" 2>/dev/null || true

# Enter the chroot as root.
"$BB" chroot "$UBUNTUPATH" /bin/su - root
