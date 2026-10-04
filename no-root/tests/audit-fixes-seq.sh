#!/usr/bin/env bash
# The approved fixes from the full menu audit, on mock_fdl2 (with spd_dump as
# the reference where the frames have to match):
#   H1  a row that is not a whole MiB is never echoed back or saved as XML
#   M1  erase-part resolves the name (boot -> boot_a, 0 -> splloader) first
#   M3  misc-backup-expect stops the session before a write when misc changed
#   L2  a misc.img of the wrong size is skipped, not a reason to abort
#   L3  a folder flash never sends more than 256 KiB to splloader
#   L6  persist-before-*.img is not a flash candidate
# Usage (from no-root/): tests/audit-fixes-seq.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
make -C "$root/spd_dump" GITVER.h >/dev/null
gcc -O1 -w -std=c99 -D_GNU_SOURCE -DUSE_LIBUSB=1 -D__ANDROID__ -I"$root/spd_dump" -I"$root/tests" \
	"$root/spd_dump/spd_dump.c" "$root/spd_dump/common.c" "$root/tests/mock_fdl2.c" -lm -lpthread -o "$tmp/sd" || exit 1
gcc -O2 -w -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
# A/B table, slot a. KiB units, as an eMMC FDL2 reports them.
printf '%s\n' 'misc 1024' 'persist 2048' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' \
	'metadata 1024' 'userdata 8192' > pt
# Non-A/B table with a 1.5 MiB uboot/uboot_bak twin (the force-write path).
printf '%s\n' 'misc 1024' 'uboot 1536' 'uboot_bak 1536' 'boot 4096' 'userdata 8192' > ptn
# The same, every row whole MiB (control: the force path still runs).
printf '%s\n' 'misc 1024' 'uboot 2048' 'uboot_bak 2048' 'boot 4096' 'userdata 8192' > ptm
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a
LOAD=(fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
sd() { local L=$1; shift; MOCK_LOG=sd_$L.seq TERMUX_USB_FD=7 timeout 30 ./sd exec_addr 0x65015f08 "${LOAD[@]}" exec "$@" 7</dev/null </dev/null >sd_$L.log 2>&1; }
sh() { local L=$1 o=(); shift; while [[ ${1:-} == --* ]]; do o+=("$1"); shift; done
	MOCK_LOG=sh_$L.seq timeout 30 ./sh --usb-fd 7 --step 0x1000 --yes "${o[@]}" exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin "${LOAD[@]}" "$@" 7</dev/null </dev/null >sh_$L.log 2>&1; }
erase_frames() { awk '$1=="SEQ" && $2=="0a" {print $4}' "$1"; }
# UTF-16LE hex of an ASCII name, as it appears at the start of a frame body.
u16() { local s=$1 i o=; for ((i = 0; i < ${#s}; i++)); do o+=$(printf '%02x00' "'${s:i:1}"); done; printf '%s' "$o"; }
export -f erase_frames u16

# ------------------------------------------------------------------ H1
head -c 1000 /dev/zero | tr '\0' 'U' > u.img
MOCK_PTABLE=$tmp/ptn sh h1twin parts ptn.txt write-part uboot u.img; rc=$?
check "H1 twin: write-part uboot on a 1.5 MiB row is refused (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'not a whole MiB\|not a multiple of 1 MiB' sh_h1twin.log"
check "H1 twin: the offending row is named" grep -q 'row 2 uboot: 1572864 bytes' sh_h1twin.log
check "H1 twin: no REPARTITION and no write START is sent" \
	bash -c "! grep -qE '^SEQ 0b ' sh_h1twin.seq && ! grep -qE '^SEQ 01 .*$(u16 uboot)' sh_h1twin.seq"
MOCK_PTABLE=$tmp/ptn sd h1ref skip_confirm 1 partition_list y.xml w uboot u.img
check "H1 twin: (spd_dump does send that table, rounded: the bug being refused)" \
	grep -qE '^SEQ 0b ' sd_h1ref.seq
MOCK_PTABLE=$tmp/ptn sh h1force parts ptn.txt w-force uboot u.img; rc=$?
check "H1 w-force: refused before anything is sent (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 0b ' sh_h1force.seq && grep -q 'refused before anything was sent' sh_h1force.log"
MOCK_PTABLE=$tmp/ptm sh h1ok parts ptm.txt write-part uboot u.img; rc=$?
check "H1 control: an all-MiB table still takes the force path (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(grep -cE '^SEQ 0b ' sh_h1ok.seq) = 2 ]"
MOCK_PTABLE=$tmp/ptn sh h1xml partition-list out.xml; rc=$?
check "H1 partition-list: refuses to write a rounded XML (rc $rc)" \
	bash -c "[ $rc != 0 ] && [ ! -e out.xml ] && grep -q 'partition-list: refused' sh_h1xml.log"
MOCK_PTABLE=$tmp/ptm sh h1xmlok partition-list outm.xml; rc=$?
check "H1 partition-list control: an all-MiB table writes its XML (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'id=\"uboot\" size=\"2\"' outm.xml"
mkdir -p xmldir
MOCK_PTABLE=$tmp/ptn SPDHOST_PART_XML_DIR=$tmp/xmldir sh h1auto parts ptn.txt; rc=$?
check "H1 auto XML: skipped with a warning, the session still succeeds (rc $rc)" \
	bash -c "[ $rc = 0 ] && ! ls xmldir/partition_*.xml >/dev/null 2>&1 && grep -q 'auto partition xml: .* not written' sh_h1auto.log"
printf '%s\n' '<Partitions>' '    <Partition id="boot" size="0"/>' \
	'    <Partition id="userdata" size="0xffffffff"/>' '</Partitions>' > zero.xml
sh h1zero repartition zero.xml; rc=$?
check "H1 repartition XML: a 0 row before the last is refused, nothing sent (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 0b ' sh_h1zero.seq && grep -q 'has size 0' sh_h1zero.log"
printf '%s\n' '<Partitions>' '    <Partition id="boot" size="4"/>' \
	'    <Partition id="userdata" size="0"/>' '</Partitions>' > lastzero.xml
sh h1last repartition lastzero.xml; rc=$?
check "H1 repartition XML: 0 on the last row is still allowed (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -qE '^SEQ 0b ' sh_h1last.seq"

# ------------------------------------------------------------------ M1
sd m1boot skip_confirm 1 partition_list x.xml e boot
sh m1boot --dangerous parts pt.txt erase-part boot; rc=$?
check "M1: erase-part boot on slot a erases boot_a (rc $rc)" \
	bash -c "[ $rc = 0 ] && erase_frames sh_m1boot.seq | grep -q '^$(u16 boot_a)00'"
check "M1: the literal 'boot' is never sent" \
	bash -c "! erase_frames sh_m1boot.seq | grep -q '^$(u16 boot)0000'"
check "M1: same ERASE frame as spd_dump's e boot" \
	bash -c "[ -n \"\$(erase_frames sd_m1boot.seq)\" ] && [ \"\$(erase_frames sd_m1boot.seq)\" = \"\$(erase_frames sh_m1boot.seq)\" ]"
check "M1: the resolution is printed" grep -q 'erase-part: boot -> boot_a' sh_m1boot.log
MOCK_SLOT=b sh m1b --dangerous parts pt.txt erase-part boot; rc=$?
check "M1: on slot b it is boot_b (rc $rc)" \
	bash -c "[ $rc = 0 ] && erase_frames sh_m1b.seq | grep -q '^$(u16 boot_b)00'"
sh m1zero --dangerous parts pt.txt erase-part 0; rc=$?
check "M1: erase-part 0 resolves to splloader and is refused, nothing erased (rc $rc)" \
	bash -c "[ $rc != 0 ] && [ -z \"\$(erase_frames sh_m1zero.seq)\" ] && grep -q \"refusing 'splloader'\" sh_m1zero.log"
sh m1idx --dangerous parts pt.txt erase-part 2; rc=$?
check "M1: erase-part 2 (row 2 = persist) is refused on the resolved name (rc $rc)" \
	bash -c "[ $rc != 0 ] && [ -z \"\$(erase_frames sh_m1idx.seq)\" ] && grep -q \"refusing 'persist'\" sh_m1idx.log"
sh m1idx5 --dangerous parts pt.txt erase-part 5; rc=$?
check "M1: erase-part 5 erases row 5 (boot_a) (rc $rc)" \
	bash -c "[ $rc = 0 ] && erase_frames sh_m1idx5.seq | grep -q '^$(u16 boot_a)00'"
sh m1none --dangerous parts pt.txt erase-part nosuch; rc=$?
check "M1: a name not in the table is refused, nothing sent (rc $rc)" \
	bash -c "[ $rc != 0 ] && [ -z \"\$(erase_frames sh_m1none.seq)\" ] && grep -q 'not in the live partition table' sh_m1none.log"
./sh --help > help.txt 2>&1
check "M2: the help says erase-part userdata writes no wipe BCB and leaves persist" \
	bash -c "grep -q 'does NOT write the wipe BCB' help.txt && grep -q 'does NOT erase persist' help.txt"

# ------------------------------------------------------------------ M3
sh m3a parts pt.txt misc-backup m3a.img; rc=$?
good=$(sha256sum m3a.img | awk '{print $1}')
head -c 2048 /dev/zero > bcb.bin
sh m3ok parts pt.txt misc-backup-expect m3b.img "$good" part-size boot; rc=$?
check "M3: misc-backup-expect goes on when misc is unchanged (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'misc is unchanged' sh_m3ok.log && grep -q '^4194304' sh_m3ok.log"
sh m3bad parts pt.txt misc-backup-expect m3c.img 0000000000000000000000000000000000000000000000000000000000000000 write-part misc bcb.bin reset; rc=$?
check "M3: a changed misc stops the session before the write (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'misc CHANGED' sh_m3bad.log && ! grep -qE '^SEQ 01 .*$(u16 misc)0000' sh_m3bad.seq && ! grep -qE '^SEQ 05 ' sh_m3bad.seq"
check "M3: the current misc is still backed up" test -s m3c.img
sh m3kg --keep-going parts pt.txt misc-backup-expect m3d.img 1111111111111111111111111111111111111111111111111111111111111111 write-part misc bcb.bin reset; rc=$?
check "M3: --keep-going does not go past a mismatch (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 05 ' sh_m3kg.seq"

# ------------------------------------------------------------------ L2 / L3 / L6
mkdir -p l2
head -c 2097152 /dev/zero > l2/misc.img   # 2 MiB; the live misc row is 1 MiB
printf 'A' > l2/boot_a.img
sh l2 parts pt.txt write-parts l2; rc=$?
check "L2: a misc.img that is not 2048 bytes or the row size is skipped (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'skip misc: .* misc is NOT written' sh_l2.log"
check "L2: the rest of the restore still goes (boot_a written)" \
	grep -qE "^SEQ 01 .*$(u16 boot_a)" sh_l2.seq
check "L2: the misc image itself is never written (only set-active's own patch)" \
	bash -c "! grep -q 'write misc: .* from l2/misc.img' sh_l2.log"

mkdir -p l3big l3ok
head -c 262145 /dev/zero > l3big/splloader.img
printf 'A' > l3big/boot_a.img
sh l3big parts pt.txt write-files l3big; rc=$?
check "L3: a splloader.img over 256 KiB aborts the folder flash before anything is sent (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE \"^SEQ 01 .*(\$(u16 splloader)|\$(u16 boot_a))\" sh_l3big.seq && grep -q 'splloader is empty or larger than the partition (262145 > 262144)' sh_l3big.log"
sh l3bigr parts pt.txt write-parts l3big; rc=$?
check "L3: the same in a restore (write-parts) (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE \"^SEQ 01 .*(\$(u16 splloader)|\$(u16 boot_a))\" sh_l3bigr.seq"
head -c 262144 /dev/zero > l3ok/splloader.img
sh l3ok parts pt.txt write-files l3ok; rc=$?
check "L3: exactly 256 KiB is still sent" \
	grep -qE "^SEQ 01 .*$(u16 splloader)" sh_l3ok.seq

mkdir -p l6
printf 'P' > l6/persist-before-20260101-000000.img
printf 'A' > l6/boot_a.img
sh l6 parts pt.txt write-files l6; rc=$?
check "L6: persist-before-*.img is not even considered (rc $rc)" \
	bash -c "[ $rc = 0 ] && ! grep -q 'persist-before' sh_l6.log && grep -qE '^SEQ 01 .*$(u16 boot_a)' sh_l6.seq"

echo "audit-fixes-seq: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
