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

# ---- R2: repartition checks ------------------------------------------------------------------
# KiB rows: misc 1, prodnv 1, boot 4, super 8, userdata 16 MiB = 30 MiB in all.
printf '%s\n' 'misc 1024' 'prodnv 1024' 'boot 4096' 'super 8192' 'userdata 16384' > ptr
xml() { local f=$1; shift; { echo '<Partitions>'; for r in "$@"; do
	echo "    <Partition id=\"${r% *}\" size=\"${r#* }\"/>"; done; echo '</Partitions>'; } > "$f"; }
xml same.xml 'misc 1' 'prodnv 1' 'boot 4' 'super 8' 'userdata 0xffffffff'
xml grow.xml 'misc 1' 'prodnv 1' 'boot 8' 'super 8' 'userdata 0xffffffff'
xml dup.xml 'misc 1' 'boot 4' 'boot 4' 'super 8' 'userdata 0xffffffff'
xml bytes.xml 'misc 1' 'prodnv 1' 'boot 4194304' 'super 8' 'userdata 0xffffffff'
xml full.xml 'misc 1' 'prodnv 1' 'boot 4' 'super 24' 'userdata 0xffffffff'
xml lastbig.xml 'misc 1' 'prodnv 1' 'boot 4' 'super 8' 'userdata 17'
export MOCK_PTABLE=$tmp/ptr
mkdir -p bk
sh r2same --yes --part-xml=bk repartition same.xml; rc=$?
check "R2: an XML equal to the live table is sent, diff says every row matches (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(grep -cE '^SEQ 0b ' sh_r2same.seq) = 1 ] && grep -q 'every row before the last matches' sh_r2same.log &&
		grep -qE '^  3 +boot 4 @2 +boot 4 @2 +same' sh_r2same.log && grep -q 'backup of the current table: bk/partition_' sh_r2same.log"
sh r2grow --yes --part-xml=bk repartition grow.xml; rc=$?
check "R2: a grown row shows old/new size and start, and the rows it moves (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -qE '^  3 +boot 4 @2 +boot 8 @2 +SIZE CHANGED' sh_r2grow.log &&
		grep -qE '^  4 +super 8 @6 +super 8 @10 +MOVED' sh_r2grow.log && grep -q 'WARNING 2 row(s) before the last differ' sh_r2grow.log"
sh r2dup --yes --part-xml=bk repartition dup.xml; rc=$?
check "R2: duplicate names are refused, nothing sent (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q \"rows 2 and 3 are both named 'boot'\" sh_r2dup.log && ! grep -qE '^SEQ 0b ' sh_r2dup.seq"
sh r2bytes --yes --part-xml=bk repartition bytes.xml; rc=$?
check "R2: a byte count typed as MiB is over the capacity: refused (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'live table adds up to 30 MiB' sh_r2bytes.log && ! grep -qE '^SEQ 0b ' sh_r2bytes.seq"
sh r2full --yes --part-xml=bk repartition full.xml; rc=$?
check "R2: rows before a 'rest' last row that use all 30 MiB are refused (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'which would get nothing' sh_r2full.log && ! grep -qE '^SEQ 0b ' sh_r2full.seq"
sh r2last --yes --part-xml=bk repartition lastbig.xml; rc=$?
check "R2: an explicit last row that takes the total past capacity is refused (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'needs 31 MiB' sh_r2last.log && ! grep -qE '^SEQ 0b ' sh_r2last.seq"
sh r2nobk --yes repartition same.xml; rc=$?
check "R2: no XML backup of the current table this session: refused (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'no backup of the current table was written' sh_r2nobk.log && ! grep -qE '^SEQ 0b ' sh_r2nobk.seq"
SPDHOST_PART_XML_DIR= sh r2nobk2 --yes repartition same.xml; rc=$?
check "R2: SPDHOST_PART_XML_DIR= (copy off) also blocks the send (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 0b ' sh_r2nobk2.seq"
sh r2plist --yes parts pt.txt partition-list pl.xml repartition same.xml; rc=$?
check "R2: a partition-list FILE in the same session counts as the backup (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'backup of the current table: pl.xml' sh_r2plist.log && [ \$(grep -cE '^SEQ 0b ' sh_r2plist.seq) = 1 ]"
MOCK_PTABLE=$tmp/pt9 sh r2unit --yes --part-xml=bk repartition same.xml; rc=$?
check "R2: an unverified table unit blocks the repartition (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'unit is unverified' sh_r2unit.log && ! grep -qE '^SEQ 0b ' sh_r2unit.seq"
# No --yes and no terminal: the confirm refuses -- and the diff was printed first.
sh r2ask --part-xml=bk repartition grow.xml; rc=$?
check "R2: the diff is printed before the confirm question (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 0b ' sh_r2ask.seq &&
		awk '/SIZE CHANGED/{d=NR} /refusing repartition from/{q=NR} END{exit !(d && q && d < q)}' sh_r2ask.log"

echo "feature-fixes-seq: $pass passed, $fail failed"
(( fail == 0 ))
