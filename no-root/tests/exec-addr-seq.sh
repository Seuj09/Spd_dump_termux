#!/usr/bin/env bash
# Dry check: spdhost's exec_addr packet sequence must be byte-identical to
# vendored spd_dump's (non-v2 exec_addr path) up to check_baud_loader.
# spd_dump is linked against tests/mock_libusb.c (no hardware); spdhost uses
# --dry-run. Both print one line per OUT frame: cmd, addr/len, FNV-1a of the
# exact framed bytes. Usage: tests/exec-addr-seq.sh  (from no-root/)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
make -C "$root" spdhost >/dev/null
make -C "$root/spd_dump" GITVER.h >/dev/null
gcc -O1 -w -std=c99 -D_GNU_SOURCE -DUSE_LIBUSB=1 -D__ANDROID__ -I"$root/spd_dump" \
	"$root/spd_dump/spd_dump.c" "$root/spd_dump/common.c" "$root/tests/mock_libusb.c" \
	-lm -lpthread -o "$tmp/spd_dump_mock"
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" "$tmp/"
cd "$tmp"
TERMUX_USB_FD=7 ./spd_dump_mock exec_addr 0x65015f08 fdl fdl1-dl.bin 0x65000800 7</dev/null 2>/dev/null \
	| grep '^DRY' > spd_dump.seq
"$root/spdhost" --dry-run exec_addr 0x65015f08 fdl fdl1-dl.bin 0x65000800 2>/dev/null \
	| grep '^DRY' | awk '/CHECK_BAUD/{n++} {print} n==2{exit}' > spdhost.seq
grep -v 'MIDST len=528' spdhost.seq
if diff -u spd_dump.seq spdhost.seq; then
	echo "PASS: $(wc -l < spdhost.seq) frames identical (no END/EXEC after exec stub)"
else
	echo "FAIL: sequences differ"; exit 1
fi
# The stub's final MIDST may never be acked: spdhost must still reach check_baud.
SPDHOST_DRY_EXEC_NOACK=1 "$root/spdhost" --dry-run exec_addr 0x65015f08 fdl fdl1-dl.bin 0x65000800 2>&1 \
	| grep -q 'FDL1 is running' && echo "PASS: missing final ack tolerated" || { echo "FAIL: no-ack path"; exit 1; }
