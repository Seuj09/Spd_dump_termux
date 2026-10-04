#!/usr/bin/env bash
# SPDHOST_USB_CAPS=1: the usbfs capability probe in spd_usb_open. It must be
# silent unless the variable is exactly 1, must not change a single frame,
# must report a failed ioctl with its errno and libusb's fallback, and must
# decode the mask into the bulk path libusb takes. The decode cases use an
# LD_PRELOAD shim that answers USBDEVFS_GET_CAPABILITIES with MOCK_CAPS; the
# descriptor itself is /dev/null on the mock FDL, where the real ioctl fails.
# Usage (from no-root/): tests/usb-caps.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0 skip=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
gcc -O2 -w -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
printf '%s\n' 'misc 1024' 'boot_a 4096' 'boot_b 4096' 'userdata 8192' > pt
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a
LOAD=(fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
sh() { local L=$1; shift
	MOCK_LOG=sh_$L.seq timeout 20 ./sh --usb-fd 7 --step 0x1000 exec_addr 0x65015f08 \
		custom_exec_no_verify_65015f08.bin "${LOAD[@]}" parts pt.txt 7</dev/null </dev/null >sh_$L.log 2>&1; }

( unset SPDHOST_USB_CAPS; sh off ); rc_off=$?
check "unset: no usbfs caps output at all (rc $rc_off)" bash -c "[ $rc_off = 0 ] && ! grep -q 'usbfs caps' sh_off.log"
SPDHOST_USB_CAPS=0 sh zero; rc=$?
check "SPDHOST_USB_CAPS=0: still silent (rc $rc)" bash -c "[ $rc = 0 ] && ! grep -q 'usbfs caps' sh_zero.log"
SPDHOST_USB_CAPS=1 sh on; rc=$?
check "set, ioctl fails on a non-usbfs fd: errno printed (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'USBDEVFS_GET_CAPABILITIES failed: errno [0-9]' sh_on.log"
check "set, ioctl fails: says libusb then assumes BULK_CONTINUATION" \
	grep -q 'assumes BULK_CONTINUATION.*linux_usbfs.c:1344' sh_on.log
check "the probe changes no frame (same SEQ log set and unset)" \
	bash -c "[ -s sh_off.seq ] && diff -q <(grep '^SEQ' sh_off.seq) <(grep '^SEQ' sh_on.seq) >/dev/null"

cat > shim.c <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/ioctl.h>
int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	void *arg;
	static int (*real)(int, unsigned long, ...);
	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);
	if (req == (unsigned long)_IOR('U', 26, unsigned int) && getenv("MOCK_CAPS")) {
		*(unsigned int *)arg = (unsigned int)strtoul(getenv("MOCK_CAPS"), NULL, 0);
		return 0;
	}
	if (!real)
		real = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
	return real(fd, req, arg);
}
C
if gcc -shared -fPIC -O1 -o shim.so shim.c -ldl 2>/dev/null; then
	run_caps() { SPDHOST_USB_CAPS=1 MOCK_CAPS=$1 LD_PRELOAD=$tmp/shim.so sh "c$1"; }
	run_caps 0x7f
	check "0x7f: raw mask and all seven flags decoded" \
		grep -q 'usbfs caps: 0x0000007f ZERO_PACKET BULK_CONTINUATION NO_PACKET_SIZE_LIM BULK_SCATTER_GATHER REAP_AFTER_DISCONNECT MMAP DROP_PRIVILEGES' sh_c0x7f.log
	check "0x7f: scatter-gather means a single URB" grep -q 'single URB per transfer (scatter-gather)' sh_c0x7f.log
	run_caps 0x07
	check "0x07: NO_PACKET_SIZE_LIM alone also means a single URB" \
		grep -q 'single URB per transfer (no packet size limit)' sh_c0x07.log
	run_caps 0x03
	check "0x03: split with continuation" grep -q 'split into 16384-byte URBs, with BULK_CONTINUATION' sh_c0x03.log
	run_caps 0x01
	check "0x01: split without continuation" grep -q 'split into 16384-byte URBs, WITHOUT continuation' sh_c0x01.log
else
	echo "skip  no shared-library toolchain for the ioctl shim; decode cases not run"
	skip=$((skip + 1))
fi
echo "usb-caps: $pass passed, $fail failed, $skip skipped"
[[ $fail -eq 0 ]]
