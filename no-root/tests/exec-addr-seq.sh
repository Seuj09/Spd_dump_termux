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

# exec_addr2 / loadexec2 (spd_dump.c:607): the stub is appended to FDL1's OWN
# download -- no END after FDL1, zero filler up to the stub's address, then the
# stub as one MIDST -- for a BootROM that takes only one download.
TERMUX_USB_FD=7 ./spd_dump_mock exec_addr2 0x65015f08 fdl fdl1-dl.bin 0x65000800 7</dev/null 2>/dev/null \
	| grep '^DRY' | awk '/CHECK_BAUD/{n++} {print} n==2{exit}' > spd_dump2.seq
"$root/spdhost" --dry-run exec_addr2 0x65015f08 fdl fdl1-dl.bin 0x65000800 2>/dev/null \
	| grep '^DRY' | awk '/CHECK_BAUD/{n++} {print} n==2{exit}' > spdhost2.seq
# spd_dump sends an UNWRITTEN malloc(528) for the filler, so its bytes (and so
# its FNV) are whatever the heap held and cannot be reproduced. Everything the
# filler must get right is its length run, and every frame that carries real
# bytes -- the START, the loader, the stub -- is compared whole, below.
if diff -u <(sed 's/ fnv=.*//' spd_dump2.seq) <(sed 's/ fnv=.*//' spdhost2.seq); then
	echo "PASS: $(wc -l < spdhost2.seq) frames, same shape as spd_dump's (one download, no END/EXEC)"
else
	echo "FAIL: exec_addr2 sequences differ in shape"; exit 1
fi
grep -q '^DRY START addr=0x65000800 len=61624 ' spdhost2.seq \
	&& echo "PASS: exec_addr2: FDL1 is one START at its own address, as usual" \
	|| { echo "FAIL: exec_addr2 START"; exit 1; }
! grep -qE '^DRY (END|EXEC)' spdhost2.seq \
	&& echo "PASS: exec_addr2: no END and no EXEC -- the stub rides in the same download" \
	|| { echo "FAIL: exec_addr2 sent END/EXEC"; exit 1; }
# The gap: exec_addr - addr - fdl1_size = 26192 bytes at 528 each (49 + 320),
# then the stub's 96 bytes. The stub's frame must be byte-identical to the
# reference's, which is the one frame of the filler run that is not filler.
check_stub=$(grep -c '^DRY MIDST len=96 fnv=' spdhost2.seq)
ref_stub=$(grep '^DRY MIDST len=96 fnv=' spd_dump2.seq)
[ "$check_stub" = 1 ] && grep -qx "$ref_stub" spdhost2.seq \
	&& echo "PASS: exec_addr2: the stub is one MIDST, byte-identical to spd_dump's ($ref_stub)" \
	|| { echo "FAIL: exec_addr2 stub frame"; exit 1; }
fill=$(grep -c '^DRY MIDST len=528 fnv=' spdhost2.seq)
[ "$fill" = 165 ] && grep -q '^DRY MIDST len=320 fnv=' spdhost2.seq \
	&& echo "PASS: exec_addr2: 26192 filler bytes fill the gap to the stub (116+49 x528, then 320)" \
	|| { echo "FAIL: exec_addr2 filler run ($fill 528-byte frames)"; exit 1; }
# A stub name that is not on disk is refused, not silently dropped: spd_dump
# (spd_dump.c:815) zeroes exec_addr and flashes without the no-verify stub,
# which is exactly the run the menu must never start by accident. LOADEXEC is
# the other way round -- see extra-cmd-seq.sh, which pins our "does not exist"
# + exec_addr 0 to the reference's for that verb.
rc=0
"$root/spdhost" --dry-run exec_addr2 0x65000fff fdl fdl1-dl.bin 0x65000800 >/dev/null 2>err2.txt || rc=$?
[ "$rc" != 0 ] && grep -q 'custom_exec_no_verify_65000fff.bin not found' err2.txt \
	&& echo "PASS: exec_addr2 with no stub file is refused before any USB traffic (rc $rc)" \
	|| { echo "FAIL: exec_addr2 missing-stub path (rc $rc)"; exit 1; }
