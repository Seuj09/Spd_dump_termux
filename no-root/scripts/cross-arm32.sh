#!/usr/bin/env bash
# Cross-compile spdhost and spd_dump for 32-bit ARM Termux (armv7l / armv8l)
# on any Linux x86-64/arm64 build machine. Output is fully static (musl), so it
# runs on a phone with no libusb or libc installed and does not need to be
# built on the device.
#
# Usage:   scripts/cross-arm32.sh            # build into no-root/dist/arm32/
#          OUT=/some/dir scripts/cross-arm32.sh
#          SKIP_TESTS=1 scripts/cross-arm32.sh
#
# Needs: python3 + pip (for the `ziglang` package, used only as a C compiler
#        with bundled musl) OR a `zig` binary on PATH; git, make, autoconf,
#        automake, libtool. qemu-arm (qemu-user) is optional, for smoke tests.
#   Debian/Ubuntu: apt install git make autoconf automake libtool qemu-user
#                  pip install ziglang
#
# Why static musl and not the Android NDK / glibc:
#  - No Android SDK download needed, works offline once ziglang is installed.
#  - Termux runs commands inside an Android app process with a seccomp syscall
#    filter. musl's startup uses few syscalls; static glibc registers rseq and
#    robust lists and can be killed with SIGSYS on some Android versions.
#
# Why libusb is built here with -D__ANDROID__:
#  libusb's Linux backend can only assume /dev/bus/usb exists (it cannot list
#  /dev under SELinux) when compiled for Android. Without the define,
#  libusb_init() fails with LIBUSB_ERROR_OTHER ("could not find usbfs") on a
#  phone. A stub <android/log.h> is provided because only the logging code
#  includes it and system logging is not enabled here.
#
# arm32 baseline: ARMv7-A with NEON (generic+v7a-neon-d32). arm64: generic aarch64.
set -euo pipefail

LIBUSB_TAG=${LIBUSB_TAG:-v1.0.27}
LIBUSB_URL=${LIBUSB_URL:-https://github.com/libusb/libusb.git}
# ARCH=arm32 (default) or ARCH=arm64. scripts/cross-arm64.sh sets arm64.
ARCH=${ARCH:-arm32}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)                  # no-root/
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 2)}

die() { echo "cross-$ARCH: $*" >&2; exit 1; }

case $ARCH in
	arm32|armv7|arm)
		: "${TARGET:=arm-linux-musleabihf}"
		: "${MCPU:=-mcpu=generic+v7a-neon-d32}"
		: "${LIBUSB_HOST:=arm-linux-gnueabihf}"
		: "${OUT:=$root/dist/arm32}"
		: "${WORK:=$root/.cross-arm32}"
		file_bits="32-bit"
		file_arch="ARM"
		qemu_bin=qemu-arm
		pkg_root=spdhost-arm32
		zip_prefix=spdhost-arm32-static
		;;
	arm64|aarch64)
		: "${TARGET:=aarch64-linux-musl}"
		: "${MCPU:=-mcpu=generic}"
		: "${LIBUSB_HOST:=aarch64-linux-gnu}"
		: "${OUT:=$root/dist/arm64}"
		: "${WORK:=$root/.cross-arm64}"
		file_bits="64-bit"
		file_arch="aarch64"
		qemu_bin=qemu-aarch64
		pkg_root=spdhost-arm64
		zip_prefix=spdhost-arm64-static
		;;
	*)
		die "ARCH must be arm32 or arm64 (got $ARCH)"
		;;
esac
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 ($2)"; }

need git "apt install git"
need make "apt install make"
need autoconf "apt install autoconf automake libtool"
need automake "apt install autoconf automake libtool"
need libtoolize "apt install libtool"

if command -v zig >/dev/null 2>&1; then
	ZIG=(zig)
elif python3 -m ziglang version >/dev/null 2>&1; then
	ZIG=(python3 -m ziglang)
else
	die "need zig: pip install ziglang   (or put a zig binary on PATH)"
fi
echo "compiler: $("${ZIG[@]}" version) target=$TARGET $MCPU"

mkdir -p "$WORK/bin" "$WORK/stub/android" "$OUT"
sysroot=$WORK/sysroot

# Compiler wrappers (libtool/autoconf need a single command word).
zig_str=$(printf '%q ' "${ZIG[@]}")
cat >"$WORK/bin/cc" <<EOF
#!/bin/sh
exec $zig_str cc -target $TARGET $MCPU "\$@"
EOF
cat >"$WORK/bin/ar" <<EOF
#!/bin/sh
exec $zig_str ar "\$@"
EOF
cat >"$WORK/bin/ranlib" <<EOF
#!/bin/sh
exec $zig_str ranlib "\$@"
EOF
chmod +x "$WORK/bin/"*
printf '/* stub: libusb includes this under __ANDROID__; only used with --enable-system-log */\n' \
	>"$WORK/stub/android/log.h"

export PATH="$WORK/bin:$PATH"
export CC=cc AR=ar RANLIB=ranlib

# --- static libusb ----------------------------------------------------------
if [[ ! -f $sysroot/lib/libusb-1.0.a ]]; then
	if [[ ! -d $WORK/libusb/.git ]]; then
		git clone --quiet --depth 1 --branch "$LIBUSB_TAG" "$LIBUSB_URL" "$WORK/libusb"
	fi
	(
		cd "$WORK/libusb"
		make distclean >/dev/null 2>&1 || true
		./autogen.sh --host="$LIBUSB_HOST" \
			--disable-udev --enable-static --disable-shared \
			--disable-examples-build --disable-tests-build \
			--prefix="$sysroot" \
			CFLAGS="-O2 -fPIC -D__ANDROID__ -D_GNU_SOURCE -I$WORK/stub" \
			>"$WORK/libusb-configure.log" 2>&1 || { tail -30 "$WORK/libusb-configure.log"; exit 1; }
		make -j"$JOBS" >"$WORK/libusb-make.log" 2>&1 || { tail -30 "$WORK/libusb-make.log"; exit 1; }
		make install >/dev/null 2>&1
	)
fi
[[ -f $sysroot/lib/libusb-1.0.a ]] || die "libusb build failed (see $WORK/*.log)"
INC=(-I"$sysroot/include" -I"$sysroot/include/libusb-1.0")
LIB=(-L"$sysroot/lib" -lusb-1.0)

# --- spdhost ----------------------------------------------------------------
echo "building spdhost"
cc -static -s -O2 -Wall -Wextra -Wno-sign-compare -Werror=implicit-function-declaration \
	-std=c11 -D_FILE_OFFSET_BITS=64 "${INC[@]}" \
	-o "$OUT/spdhost" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" \
	"$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" \
	"$root/src/dhtb.c" "$root/src/pac.c" \
	"${LIB[@]}" -lpthread

# --- spd_dump (vendored TomKing tree) ---------------------------------------
echo "building spd_dump"
sd=$root/spd_dump
sha=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)
branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
gv=$WORK/gitver; mkdir -p "$gv"
printf '#define GIT_VER "%s"\n#define GIT_SHA1 "%s"\n' "$branch" "$sha" >"$gv/GITVER.h"
cc -static -s -O2 -Wall -Wextra -Werror=implicit-function-declaration -std=c99 -pedantic -Wno-unused \
	-Wno-unused-parameter -D_GNU_SOURCE -D__ANDROID__ -DUSE_LIBUSB=1 -I"$gv" -I"$sd" "${INC[@]}" \
	-o "$OUT/spd_dump" "$sd/spd_dump.c" "$sd/common.c" "${LIB[@]}" -lm -lpthread

# --- checks -----------------------------------------------------------------
for b in spdhost spd_dump; do
	desc=$(file -b "$OUT/$b" 2>/dev/null || echo "")
	if [[ -n $desc && ( $desc != *"$file_bits"* || $desc != *"$file_arch"* || $desc != *"statically linked"* ) ]]; then
		die "$b is not a static $file_bits $file_arch executable: $desc"
	fi
done

if [[ -z ${SKIP_TESTS:-} ]] && command -v "$qemu_bin" >/dev/null 2>&1; then
	echo "smoke tests ($qemu_bin; no USB hardware involved)"
	fail=0
	t() { # name expected-substring cmd...
		local n=$1 want=$2; shift 2
		local o; o=$("$@" 2>&1 </dev/null || true)
		if [[ $o == *"$want"* ]]; then echo "  ok   $n"; else echo "  FAIL $n: $o" | head -5; fail=1; fi
	}
	t "spd_dump no fd"        "needs a USB file descriptor"  "$qemu_bin" "$OUT/spd_dump"
	t "spd_dump bad fd"       "bad --usb-fd"                 "$qemu_bin" "$OUT/spd_dump" --usb-fd abc
	t "spd_dump closed fd"    "not open in this process"     env TERMUX_USB_FD=99 "$qemu_bin" "$OUT/spd_dump"
	t "spd_dump libusb init"  "not open in this process"     env TERMUX_USB_FD=98 "$qemu_bin" "$OUT/spd_dump"
	t "spdhost self-test"     "self-test ok"                 "$qemu_bin" "$OUT/spdhost" --self-test
	t "spdhost help"          "Unisoc download-mode client"  "$qemu_bin" "$OUT/spdhost" --help
	t "spdhost closed fd"     "is not open"                  env TERMUX_USB_FD=99 "$qemu_bin" "$OUT/spdhost" ping
	t "spdhost non-usb fd"    "must be a live usbfs FD"      bash -c 'exec 5</dev/null; TERMUX_USB_FD=5 exec "$@"' _ "$qemu_bin" "$OUT/spdhost" ping
	(( fail == 0 )) || die "smoke tests failed"
fi

# --- package ----------------------------------------------------------------
pkg=$OUT/pkg
rm -rf "$pkg"; mkdir -p "$pkg/scripts"
cp "$OUT/spdhost" "$pkg/spdhost"
mkdir -p "$pkg/spd_dump/scripts"
cp "$OUT/spd_dump" "$pkg/spd_dump/spd_dump"
cp "$root/scripts/"*.sh "$root/scripts/spdhost-usb" "$pkg/scripts/"
rm -f "$pkg/scripts/cross-arm32.sh" "$pkg/scripts/cross-arm64.sh" "$pkg/scripts/cross-both.sh"
cp "$sd/scripts/spd_dump-usb" "$pkg/spd_dump/scripts/"
cp "$sd/TERMUX.md" "$sd/PIN.txt" "$pkg/spd_dump/" 2>/dev/null || true
cp -r "$root/fdl" "$pkg/fdl"
cp -r "$root/misc" "$pkg/misc"   # BCB images for menu [5] wipe (package-relative lookup)
mkdir -p "$pkg/input"
cp "$root/input/"*.txt "$pkg/input/" 2>/dev/null || true
cp "$root/README.md" "$root/LICENSE" "$pkg/"
chmod +x "$pkg/spdhost" "$pkg/spd_dump/spd_dump" "$pkg/scripts/"* "$pkg/spd_dump/scripts/"*
short=$(printf '%s' "$sha" | cut -c1-7)
zipname=$zip_prefix-$short.zip
( cd "$pkg" && python3 - "$OUT/$zipname" "$pkg_root" <<'PY'
import os, stat, sys, zipfile
out, rootname = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for d, _, fs in os.walk("."):
        for f in sorted(fs):
            p = os.path.join(d, f)
            info = zipfile.ZipInfo.from_file(p, arcname=os.path.join(rootname, p[2:]))
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(p, "rb") as fh:
                z.writestr(info, fh.read())
PY
)
( cd "$OUT" && sha256sum spdhost spd_dump "$zipname" >SHA256SUMS )
echo
echo "done -> $OUT"
cat "$OUT/SHA256SUMS"
