#!/bin/sh
# ============================================================================
#  setup.sh — One-shot Ubuntu 22.04 chroot installer for rooted Termux.
#
#  Usage (in Termux, as root):
#      # 1. Install a busybox module so `busybox` is reachable from the root
#      #    shell (NOT just `pkg install busybox`). See Chroot_tutorial.md.
#      # 2. Download this script and run it as root:
#      su
#      cd /data/local/tmp
#      sh setup.sh
#
#  What it does:
#    1. Detects architecture (arm64 default), downloads the Ubuntu base rootfs.
#    2. Extracts it to /data/local/tmp/chrootubuntu and creates mountpoints.
#    3. Writes `start.sh` (chroot entry script) next to it.
#    4. Writes and runs a first-time bootstrap inside the chroot (DNS, hosts,
#       Android uid groups, apt update/upgrade, base packages).
#
#  Re-run is safe: existing downloads and extracted rootfs are reused.
# ============================================================================
set -eu

# ---- config ---------------------------------------------------------------
CHROOT_DIR="/data/local/tmp/chrootubuntu"
UBUNTU_REL="22.04"

# ---- helpers --------------------------------------------------------------
log()  { printf '%s\n' "[*] $*"; }
ok()   { printf '%s\n' "[+] $*"; }
fail() { printf '%s\n' "[!] $*" >&2; exit 1; }

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64)       echo arm64 ;;
    armv7l|armv8l|arm)   echo armhf ;;
    x86_64|amd64)        echo amd64 ;;
    i686|i386)           echo i386  ;;
    *)                   echo arm64 ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# Locate a usable busybox. After `su`, Termux's busybox is often NOT on PATH,
# so probe common Magisk/module install locations first.
find_busybox() {
  for p in /system/xbin/busybox /system/bin/busybox /su/xbin/busybox \
           /sbin/.magisk/busybox/busybox /data/adb/magisk/busybox \
           /data/data/com.termux/files/usr/bin/busybox
  do
    [ -x "$p" ] && { BB="$p"; return 0; }
  done
  if have busybox; then BB="busybox"; return 0; fi
  return 1
}

download() {
  # $1 = URL, $2 = output file
  if have wget; then
    wget -O "$2" "$1"
  elif have curl; then
    curl -L -o "$2" "$1"
  else
    fail "wget or curl is required."
  fi
}

# ---- prerequisites --------------------------------------------------------
find_busybox || fail "busybox not found for the root shell. Install a busybox module (e.g. Magisk 'Busybox for Android NDK') — see Chroot_tutorial.md."
[ "$("$BB" id -u 2>/dev/null || id -u)" -eq 0 ] || fail "Run as root first (type 'su')."

ARCH="${ARCH:-$(detect_arch)}"
ROOTFS_NAME="ubuntu-base-${UBUNTU_REL}-base-${ARCH}.tar.gz"
ROOTFS_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_REL}/release/${ROOTFS_NAME}"

log "Architecture: $ARCH"
log "Chroot directory: $CHROOT_DIR"

# ---- download -------------------------------------------------------------
if [ ! -f "$ROOTFS_NAME" ]; then
  log "Downloading $ROOTFS_NAME ..."
  download "$ROOTFS_URL" "$ROOTFS_NAME"
else
  log "Found existing $ROOTFS_NAME, reusing it."
fi

# ---- extract --------------------------------------------------------------
if [ -f "$CHROOT_DIR/etc/os-release" ]; then
  log "Rootfs already extracted at $CHROOT_DIR, skipping extraction."
else
  mkdir -p "$CHROOT_DIR"
  log "Extracting rootfs ..."
  tar xf "$ROOTFS_NAME" -C "$CHROOT_DIR"
  ok "Extracted."
fi

# Mountpoints referenced by start.sh.
mkdir -p "$CHROOT_DIR/dev/shm" "$CHROOT_DIR/sdcard"

# ---- write start.sh (chroot entry script) ---------------------------------
# This embedded copy must stay in sync with the standalone start.sh in the repo.
START_SCRIPT="$(dirname "$CHROOT_DIR")/start.sh"
log "Writing $START_SCRIPT ..."
cat > "$START_SCRIPT" <<'EOF'
#!/bin/sh
set -eu
UBUNTUPATH="/data/local/tmp/chrootubuntu"
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
mkdir -p "$UBUNTUPATH/sdcard" "$UBUNTUPATH/dev/shm"
"$BB" mount -o remount,dev,suid /data
"$BB" mount --bind /dev  "$UBUNTUPATH/dev"
"$BB" mount --bind /sys  "$UBUNTUPATH/sys"
"$BB" mount --bind /proc "$UBUNTUPATH/proc"
"$BB" mount -t devpts devpts "$UBUNTUPATH/dev/pts" 2>/dev/null || true
"$BB" mount -t tmpfs -o size=256M tmpfs "$UBUNTUPATH/dev/shm" 2>/dev/null || true
"$BB" mount --bind /sdcard "$UBUNTUPATH/sdcard" 2>/dev/null || true
"$BB" chroot "$UBUNTUPATH" /bin/su - root
EOF
chmod +x "$START_SCRIPT"

# ---- write + run first-time bootstrap inside the chroot -------------------
BOOTSTRAP="$CHROOT_DIR/tmp/bootstrap.sh"
log "Writing in-chroot bootstrap ..."
cat > "$BOOTSTRAP" <<'EOF'
#!/bin/sh
set -eu
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "127.0.0.1 localhost" > /etc/hosts

groupadd -g 3003 aid_inet     2>/dev/null || true
groupadd -g 3004 aid_net_raw  2>/dev/null || true
groupadd -g 1003 aid_graphics 2>/dev/null || true
usermod -G 3003,3004 -a _apt  2>/dev/null || true
usermod -G 3003 -a root       2>/dev/null || true

apt update
apt upgrade -y
apt install -y nano vim net-tools sudo git
EOF
chmod +x "$BOOTSTRAP"

log "Mounting dev/sys/proc and running first-time setup ..."
"$BB" mount --bind /dev  "$CHROOT_DIR/dev"  2>/dev/null || true
"$BB" mount --bind /sys  "$CHROOT_DIR/sys"  2>/dev/null || true
"$BB" mount --bind /proc "$CHROOT_DIR/proc" 2>/dev/null || true
"$BB" chroot "$CHROOT_DIR" /bin/sh /tmp/bootstrap.sh

ok "Done. To enter the chroot later, run:  sh $START_SCRIPT"
