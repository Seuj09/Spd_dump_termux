#!/bin/sh
# ============================================================================
#  setup.sh — One-shot Ubuntu 22.04 chroot installer for rooted Termux.
#
#  Usage (in Termux):
#      pkg install busybox wget        # (wget, or install curl instead)
#      su                              # grant root to Termux
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
    aarch64|arm64)  echo arm64 ;;
    armv7l|armv8l|arm) echo armhf ;;
    x86_64|amd64)   echo amd64 ;;
    i686|i386)      echo i386  ;;
    *)              echo arm64 ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

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
[ "$(id -u 2>/dev/null || busybox id -u)" -eq 0 ] || fail "Run as root first (type 'su')."
have busybox || fail "busybox not found. Install it first (pkg install busybox)."

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
START_SCRIPT="$(dirname "$CHROOT_DIR")/start.sh"
log "Writing $START_SCRIPT ..."
cat > "$START_SCRIPT" <<'EOF'
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

groupadd -g 3003 aid_inet    2>/dev/null || true
groupadd -g 3004 aid_net_raw 2>/dev/null || true
groupadd -g 1003 aid_graphics 2>/dev/null || true
usermod -G 3003,3004 -a _apt 2>/dev/null || true
usermod -G 3003 -a root      2>/dev/null || true

apt update
apt upgrade -y
apt install -y nano vim net-tools sudo git
EOF
chmod +x "$BOOTSTRAP"

log "Mounting dev/sys/proc and running first-time setup ..."
busybox mount --bind /dev  "$CHROOT_DIR/dev" 2>/dev/null || true
busybox mount --bind /sys  "$CHROOT_DIR/sys" 2>/dev/null || true
busybox mount --bind /proc "$CHROOT_DIR/proc" 2>/dev/null || true
busybox chroot "$CHROOT_DIR" /bin/sh /tmp/bootstrap.sh

ok "Done. To enter the chroot later, run:  sh $START_SCRIPT"
