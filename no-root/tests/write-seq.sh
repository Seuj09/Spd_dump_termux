#!/usr/bin/env bash
# Write / repartition / set-active against vendored spd_dump on mock_fdl2.
# From no-root/: tests/write-seq.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
make -C "$root/spd_dump" GITVER.h >/dev/null
gcc -O1 -w -std=c99 -D_GNU_SOURCE -DUSE_LIBUSB=1 -D__ANDROID__ -I"$root/spd_dump" -I"$root/tests" \
	"$root/spd_dump/spd_dump.c" "$root/spd_dump/common.c" "$root/tests/mock_fdl2.c" -lm -lpthread -o "$tmp/sd" || exit 1
gcc -O2 -w -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/proto.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' \
	'l_fixnv1 1024' 'l_fixnv2 1024' 'metadata 1024' 'super 8192' > pt
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a
LOAD=(fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
sd() { local L=$1; shift; MOCK_LOG=sd_$L.seq TERMUX_USB_FD=7 timeout 20 ./sd exec_addr 0x65015f08 "${LOAD[@]}" exec "$@" 7</dev/null </dev/null >sd_$L.log 2>&1; }
sh() { local L=$1 o=(); shift; while [[ ${1:-} == --* ]]; do o+=("$1"); shift; done
	MOCK_LOG=sh_$L.seq timeout 20 ./sh --usb-fd 7 --step 0x1000 --yes "${o[@]}" exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin "${LOAD[@]}" "$@" 7</dev/null </dev/null >sh_$L.log 2>&1; }
# One START frame whose UTF-16LE name begins with the given hex.
start_frame() { awk -v p="$2" '$1=="SEQ" && $2=="01" && index($4,p){print; exit}' "$1"; }

# 100-byte boot image. spd_dump `w` uses blk_size 0x1000 unless set; --step matches it.
dd if=/dev/zero bs=100 count=1 status=none | tr '\0' 'B' > boot.img
# Minimal NV body: u32 reserved, one item (id 1, len 4), pad, 0xffff terminator.
python3 - << 'PY'
import struct
body = struct.pack('<I', 0) + struct.pack('<HH', 1, 4) + b'\x11\x22\x33\x44' + struct.pack('<H', 0xffff) + b'\x00'*6
open('nv.bin','wb').write(body)
open('parts.xml','w').write(
'''<Partitions>
    <Partition id="boot_a" size="32"/>
    <Partition id="userdata" size="0xffffffff"/>
</Partitions>
''')
PY

sd wboot skip_confirm 1 partition_list p.xml w boot_a boot.img; sdrc=$?
sh wboot parts pt.txt write-part boot_a boot.img; shrc=$?
start_frame sd_wboot.seq 62006f006f0074005f006100 > a_w
start_frame sh_wboot.seq 62006f006f0074005f006100 > b_w
check "write boot_a START matches spd_dump (rc $sdrc/$shrc)" \
	bash -c '[ -s a_w ] && diff -q a_w b_w >/dev/null && [ '"$shrc"' = 0 ]'

sd wnv skip_confirm 1 partition_list p2.xml w l_fixnv1 nv.bin; sdrc=$?
sh wnv parts pt.txt write-part l_fixnv1 nv.bin; shrc=$?
start_frame sd_wnv.seq 6c005f006600690078006e0076003100 > a_nv
start_frame sh_wnv.seq 6c005f006600690078006e0076003100 > b_nv
check "fixnv1 NV START matches spd_dump (rc $sdrc/$shrc)" \
	bash -c '[ -s a_nv ] && diff -q a_nv b_nv >/dev/null && [ '"$shrc"' = 0 ]'
# The framed body (the MIDST after that START) must match too.
awk 'f&&/SEQ 02/{print; exit} /6c005f006600690078006e0076003100/{f=1}' sd_wnv.seq > a_mid
awk 'f&&/SEQ 02/{print; exit} /6c005f006600690078006e0076003100/{f=1}' sh_wnv.seq > b_mid
check "fixnv1 MIDST matches spd_dump" bash -c '[ -s a_mid ] && diff -q a_mid b_mid >/dev/null'

sd rep skip_confirm 1 repartition parts.xml; sdrc=$?
sh rep repartition parts.xml; shrc=$?
awk '/^SEQ 0b /{print; exit}' sd_rep.seq > a_rep
awk '/^SEQ 0b /{print; exit}' sh_rep.seq > b_rep
check "repartition packet matches spd_dump (rc $sdrc/$shrc)" \
	bash -c '[ -s a_rep ] && diff -q a_rep b_rep >/dev/null && [ '"$shrc"' = 0 ]'

rm -f misc.out
MOCK_MISC_OUT=$tmp/misc_sd_slot.bin sd slot set_active a; sdrc=$?
MOCK_MISC_OUT=$tmp/misc_sh_slot.bin sh slot parts pt.txt set-active a; shrc=$?
python3 - << 'PY'
import pathlib, sys
exp = bytes.fromhex('5f61000042434142010200006f001e00000000000000000000000000e6bfeac5')
ok = True
for n in ('misc_sd_slot.bin','misc_sh_slot.bin'):
    b = pathlib.Path(n).read_bytes()
    good = len(b) >= 0x820 and b[0x800:0x820] == exp
    print(n, len(b), good)
    ok = ok and good
sys.exit(0 if ok else 1)
PY
check "set-active a: both tools leave spd_dump's 32-byte slot block (rc $sdrc/$shrc)" test $? -eq 0

# write-parts: slot a image is sent, slot b is not, metadata erased when super is present.
mkdir -p imgs
printf 'A' > imgs/boot_a.img
printf 'B' > imgs/boot_b.img
printf 'S' > imgs/super.img
sh restore parts pt.txt write-parts imgs; rc=$?
check "write-parts writes boot_a, skips boot_b, erases metadata (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q '62006f006f0074005f006100' sh_restore.seq && ! grep -q '62006f006f0074005f006200' sh_restore.seq && grep -q 'erasing metadata' sh_restore.log && grep -q 'set-active: slot a' sh_restore.log"

sh noerase parts pt.txt erase-part persist; rc=$?
check "erase persist refused (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'refusing' sh_noerase.log"
sh nospl parts pt.txt erase-part splloader; rc=$?
check "erase splloader refused (rc $rc)" bash -c "[ $rc != 0 ] && grep -q 'refusing' sh_nospl.log"

# Oversized boot image is not sent.
dd if=/dev/zero of=huge.img bs=1 count=1 seek=$((5*1024*1024)) status=none
sh huge parts pt.txt write-part boot_a huge.img; rc=$?
check "oversized write refused before START (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothing sent' sh_huge.log && ! grep -q '62006f006f0074005f006100' sh_huge.seq"

# Menu rows: UBL prints the disabled note and does not call the wrapper.
check "menu unlock is disabled" bash -c "SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c 'source \"$root/scripts/menu.sh\"; unlock_bootloader_menu' | grep -q 'temporary disabled'"
check "menu flash/restore/repartition functions exist" bash -c "SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c 'source \"$root/scripts/menu.sh\"; type flash_input_menu restore_backup_menu repartition_menu set_slot_menu extra_menu dump_imei_session'"
bash -n "$root/scripts/menu.sh"
check "menu.sh syntax" test $? -eq 0

echo
echo "write-seq: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
