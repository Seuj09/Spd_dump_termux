#!/usr/bin/env bash
# The feature-audit batch (feature-audit/REPORT.md) on mock_fdl2:
#   R1  a guessed table unit (divisor != 10) that the size probe does not
#       confirm is never sent back or saved (twin write, w-force, partition-list)
# Usage (from no-root/): tests/feature-fixes-seq.sh   (KEEP=1 keeps the tmp dir)
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] && echo "tmp=$tmp" || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
gcc -O2 -w -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
gcc -O2 -w -I"$root/tests" "$root/tests/gen_expected.c" -o "$tmp/gen" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
LOAD=(fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
EX=(exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin)
# The menu never passes --yes; --yes is used here only where the test is about
# a refusal that happens before any confirmation would matter.
sh() { local L=$1 o=(); shift; while [[ ${1:-} == --* ]]; do o+=("$1"); shift; done
	MOCK_LOG=sh_$L.seq SPDHOST_STATUS_FILE=$tmp/sh_$L.st timeout 30 ./sh --usb-fd 7 "${o[@]}" \
		"${EX[@]}" "${LOAD[@]}" "$@" 7</dev/null </dev/null >sh_$L.log 2>&1; }
reparts() { grep -cE '^SEQ 0b ' "$1"; }

# ---- R1: guessed unit ----------------------------------------------------------------------
# The audit's table: misc 512 KiB drags spd_dump's divisor to 9, so every row
# reads doubled and is still a whole MiB -- the H1 rounding check passes it.
printf '%s\n' 'misc 512' 'uboot 1024' 'uboot_bak 1024' 'boot 4096' 'metadata 1024' 'super 8192' > pt9
printf '%s\n' 'misc 1024' 'uboot 1024' 'uboot_bak 1024' 'boot 4096' 'metadata 1024' 'super 8192' > pt10
head -c 1048576 /dev/zero | tr '\0' 'U' > ub.img
export MOCK_PTABLE=$tmp/pt9
sh r1w --yes parts pt.txt write-part uboot ub.img; rc=$?
check "R1: twin write on an unconfirmed guessed unit is refused, no REPARTITION, no write (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'table unit unverified' sh_r1w.log && [ \$(grep -cE '^SEQ 0b ' sh_r1w.seq) = 0 ] && ! grep -q 'write w_force' sh_r1w.log"
sh r1f --yes parts pt.txt w-force boot ub.img; rc=$?
check "R1: w-force on an unconfirmed guessed unit sends no REPARTITION (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'table unit unverified' sh_r1f.log && [ \$(grep -cE '^SEQ 0b ' sh_r1f.seq) = 0 ]"
mkdir -p xd
sh r1x --yes --part-xml=xd parts pt.txt partition-list r1.xml; rc=$?
check "R1: partition-list writes no XML, and the auto XML is skipped too (rc $rc)" \
	bash -c "[ $rc != 0 ] && [ ! -e r1.xml ] && grep -q 'partition-list: table unit unverified' sh_r1x.log && ! ls xd/partition_*.xml >/dev/null 2>&1"
check "R1: the fetch says the session will not send the table back" \
	grep -q 'will not send the table back' sh_r1w.log
# Control: a divisor-10 table with the same rows is not affected.
MOCK_PTABLE=$tmp/pt10 sh r1ok --yes parts pt.txt write-part uboot ub.img; rc=$?
check "R1 control: the same twin write on a KiB (divisor 10) table sends both REPARTITIONs (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(grep -cE '^SEQ 0b ' sh_r1ok.seq) = 2 ] && ! grep -q 'unverified' sh_r1ok.log"
# A plain write (no _bak twin, nothing echoed) still works on the guessed table:
# it sends no table and the device size-checks the image itself.
sh r1p --yes parts pt.txt write-part boot ub.img; rc=$?
check "R1: a plain write (no twin) is not blocked by the latch (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(grep -cE '^SEQ 0b ' sh_r1p.seq) = 0 ]"

# verity and frp-reset size their row from the same table: they use the
# device's own size for the row instead of the doubled one.
cp pt9 pt9vp; printf '%s\n' 'vbmeta 1024' 'persist 1024' >> pt9vp
MOCK_PTABLE=$tmp/pt9vp MOCK_IMAGES=vbmeta sh r1v --dangerous parts pt.txt verity 0; rc=$?
check "R1: verity on a guessed unit uses the device's 1 MiB for vbmeta, not the table's 2 MiB (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q \"using the device's size for vbmeta: 1048576 bytes (table says 2097152)\" sh_r1v.log && grep -q '(1048576-byte rewrite)' sh_r1v.log"
MOCK_PTABLE=$tmp/pt9vp sh r1p2 --dangerous parts pt.txt frp-reset r1persist.img; rc=$?
check "R1: frp-reset on a guessed unit backs up the device's 1 MiB persist (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(stat -c %s r1persist.img) = 1048576 ] && grep -q \"using the device's size for persist\" sh_r1p2.log"

echo "feature-fixes-seq: $pass passed, $fail failed"
(( fail == 0 ))
