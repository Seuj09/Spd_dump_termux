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
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
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

# spd_dump's scan_xml_partitions() rewrites its in-memory table from the XML, so
# the command after a repartition in the same session -- a write to the
# partition just enlarged, which is the whole reason to repartition -- uses the
# NEW layout. Keeping the pre-repartition table refused a file the device would
# now take, and refused a partition the XML had just added by name.
python3 - << 'PY'
open('grow.xml','w').write(
'''<Partitions>
    <Partition id="metadata" size="2048"/>
    <Partition id="userdata" size="0xffffffff"/>
    <Partition id="newpart" size="2048"/>
</Partitions>
''')
PY
printf 'N' > newpart.img
# metadata is 1 MiB in pt; the XML grows it to 2048 units (2 MiB), the size of
# grow.img. The mock applies the repartition it is sent, so the write has to
# complete -- the frame and the device's table both have to agree. The same file
# under the stale table is refused here, which is what makes the growth the thing
# that allows it and not some other difference.
head -c 2097152 /dev/zero | tr '\0' 'G' > grow.img
sh old parts pt.txt write-part metadata grow.img; rc=$?
check "the same file is refused before the repartition, so the growth is what fits it (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothing sent' sh_old.log &&
		! grep -q 'write metadata: 2097152 bytes from' sh_old.log"
sh grow parts pt.txt repartition grow.xml write-part metadata grow.img; rc=$?
check "a write after a repartition uses the new size, not the old one (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'write metadata: 2097152 bytes' sh_grow.log &&
		grep -qE '^SEQ 01 len=76 ' sh_grow.seq"
sh add parts pt.txt repartition grow.xml write-part newpart newpart.img; rc=$?
check "a partition added by the repartition resolves in the same session (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'write newpart: ' sh_add.log &&
		! grep -q 'not in the live partition table' sh_add.log"

# spd_dump hands scan_xml_partitions 0xffff as a BYTE budget and then overruns
# its own 128-entry ptable past 128 entries. The real ceiling is the 16-bit BSL
# frame length: the payload is n * 0x4c, so 862 entries is the last that fits.
python3 - << 'PY'
for n in (129, 863):
    open('n%d.xml' % n, 'w').write('<Partitions>\n' +
        ''.join('    <Partition id="p%03d" size="16"/>\n' % i for i in range(n)) +
        '</Partitions>\n')
PY
sh n129 repartition n129.xml; rc=$?
check "129 entries: past spd_dump's 128-entry table, and still sent (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -qE '^SEQ 0b len=9804 ' sh_n129.seq"
sh n863 repartition n863.xml; rc=$?
check "863 entries: refused before sending anything, at the frame limit (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 0b ' sh_n863.seq &&
		grep -q 'more than 862' sh_n863.log"

# spd_dump's w_force (spd_dump.c ~1126, load_partition_force common.c ~1302):
# rename the target row to "w_force" in a temporary table, write to that name,
# then send the original table back. Two repartitions around one write, and the
# row has to come back -- a phone left with a "w_force" row has no name to write
# its own partition with. The mock applies each table it is sent, so the write
# only reaches the device if the temporary table really was sent first.
sh force parts pt.txt w-force boot_a boot.img; rc=$?
check "w-force sends two repartitions and writes under the temporary name (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(grep -cE '^SEQ 0b ' sh_force.seq) = 2 ] &&
		grep -qE '^SEQ 01 len=76 77005f0066006f00720063006500' sh_force.seq &&
		grep -q 'w-force boot_a: done, table restored' sh_force.log"
# The rename is the only difference between the two tables: the 0x4c-byte record
# for boot_a (row 4, so hex chars 457..608 of the payload) is the one field that
# changes. A table sent back with a stale size or a dropped row would not match.
check "the second table differs from the first only in the renamed row" \
	bash -c 'awk "/^SEQ 0b /{n++; if(n==1)a=\$4; else if(n==2)b=\$4} END{
		print (length(a)==length(b) && substr(a,1,456)==substr(b,1,456) &&
			substr(a,609)==substr(b,609)) ? 1 : 0}" sh_force.seq | grep -qx 1'
# A force write is the one write that does not stop at the row: the loader is
# what refuses, by name, and this exists to get past that. Ours must send it
# rather than refuse locally -- the reference's w_force has no size check either.
head -c 8388608 /dev/zero | tr '\0' 'F' > over.img
# boot_a is 1 unit here, and the 1 drags spd_dump's divisor to 0, so the unit is
# MiB and the row is 1 MiB. An 8 MiB image is past it.
printf '%s\n' 'boot_a 1' 'big 8192' > overpt
MOCK_PTABLE=$tmp/overpt sh over parts overpt w-force boot_a over.img; rc=$?
check "w-force sends a file past the row's size instead of refusing it (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'w-force boot_a: WARNING the file is 8388608 bytes' sh_over.log &&
		[ \$(grep -cE '^SEQ 0b ' sh_over.seq) = 2 ] && grep -q 'table is back to normal' sh_over.log"
MOCK_PTABLE=$tmp/overpt sh over2 parts overpt write-part boot_a over.img; rc=$?
check "the same file through write-part is refused before anything is sent (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothing sent' sh_over2.log &&
		! grep -q 'write boot_a: 8388608 bytes from' sh_over2.log"
# splloader is the reference's own blacklist (spd_dump.c ~1139) and misc keeps our
# backup-path rule. Both must refuse before the first repartition.
printf '%s\n' 'splloader 256' 'boot_a 4096' > splpt
MOCK_PTABLE=$tmp/splpt sh fspl parts splpt w-force splloader boot.img; rc=$?
check "w-force refuses splloader before sending anything (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 0b ' sh_fspl.seq &&
		grep -q 'splloader (the reference blacklists it)' sh_fspl.log"
sh fmisc parts pt.txt w-force misc boot.img; rc=$?
check "w-force refuses misc before sending anything (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 0b ' sh_fmisc.seq &&
		grep -q 'never force-written' sh_fmisc.log"
sh fmiss parts pt.txt w-force nosuch boot.img; rc=$?
check "w-force on a name that is not in the table sends nothing (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 0b ' sh_fmiss.seq &&
		grep -q 'not in the live partition table' sh_fmiss.log"

# The XML repartition reads is the XML spd_dump's partition_list writes, and now
# the XML partition-list writes too: dumping the table gives a starting point
# that is accepted back. The two writers must agree byte for byte, so this
# compares ours against the vendored tool on the same device table.
#
# The table is a phone's own shape: 1 MiB rows like misc and sml_a, a 64 MiB
# boot, a 5 GiB super. Those 1s are what make spd_dump's divisor land on 0, so
# the wire unit is MiB and the XML carries each row's number unchanged. That is
# the case the format exists for, and the one a 5 GB -> 10 GB super edit is
# written against.
printf '%s\n' 'prodnv 64' 'misc 1' 'sml_a 1' 'boot_a 64' 'super 5120' 'userdata 6144' > phonept
MOCK_PTABLE=$tmp/phonept sh phone partition-list ours.xml; shrc=$?
MOCK_PTABLE=$tmp/phonept sd xml2 skip_confirm 1 partition_list theirs.xml reset; sdrc=$?
check "partition-list is byte-identical to spd_dump partition_list (rc $shrc/$sdrc)" \
	bash -c '[ '"$shrc"' = 0 ] && [ '"$sdrc"' = 0 ] && cmp -s ours.xml theirs.xml'
check "a phone's MiB row is dumped as its own number, not shifted (super=5120)" \
	bash -c 'grep -q "Partition id=\"super\" size=\"5120\"" ours.xml &&
		grep -q "Partition id=\"misc\" size=\"1\"" ours.xml'
# And what we wrote must be accepted back by our own parser -- the round trip,
# with the numbers the device would see unchanged.
sh round repartition ours.xml; rc=$?
check "the dumped XML is accepted back by repartition, super still 5120 (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'SEQ 0b len=456 ' sh_round.seq &&
		grep -q 'repartition: \[5\] super size=5120' sh_round.log"
# spd_dump writes partition_<unixtime>.xml (spd_dump.c:191) on every session
# that reads the table, wherever it runs, so the XML a repartition edit starts
# from is always there. spdhost writes the same file, but into a folder the
# caller names -- the menu points that at the dump folder -- so the copy lands
# with the dumps instead of in whatever directory the tool was started in.
mkdir -p autoxml
MOCK_PTABLE=$tmp/phonept SPDHOST_PART_XML_DIR=$tmp/autoxml sh auto parts pt_auto.txt; arc=$?
autof=$(ls "$tmp"/autoxml/partition_*.xml 2>/dev/null | head -1)
check "a table read leaves partition_<unixtime>.xml in SPDHOST_PART_XML_DIR (rc $arc)" \
	bash -c "[ $arc = 0 ] && [ -n '$autof' ] &&
		grep -qE '^partition xml: .*/partition_[0-9]+\.xml \(6 entries\)$' sh_auto.log"
# The automatic copy and `partition-list` must be the same bytes, or editing
# one and feeding it back would depend on which command produced it.
check "the automatic copy is byte-identical to partition-list (ours.xml)" cmp -s "$autof" ours.xml
# The device is asked for its table once per session and everything after that
# re-prints the table already in hand, as in the reference: its call sites are
# guarded by `if (gpt_failed == 1)` (spd_dump.c:755, 954, 1034) and a successful
# read clears the flag (common.c:1143), so `parts` then `partition-list` is one
# READ_PARTITION, one automatic file (the name is picked once per process), and
# both outputs still written from the cached table.
mkdir -p once
MOCK_PTABLE=$tmp/phonept SPDHOST_PART_XML_DIR=$tmp/once \
	sh once parts pt_once.txt partition-list once.xml; rc=$?
n=$(ls "$tmp"/once/partition_*.xml 2>/dev/null | wc -l)
check "two listings in one run: one device read, one auto file, both outputs (rc $rc, $n file)" \
	bash -c "[ $rc = 0 ] && [ $n = 1 ] && [ -s once.xml ] && [ -s pt_once.txt ] &&
		[ \$(grep -c '^parts: ' sh_once.log) = 1 ] && [ \$(grep -c '^SEQ 2d ' sh_once.seq) = 1 ]"
# Off unless asked for: an empty value means no copy, which is also what an
# unset variable does, so no command grows a file nobody asked about.
mkdir -p noxml
MOCK_PTABLE=$tmp/phonept SPDHOST_PART_XML_DIR= sh offenv parts pt_off.txt
MOCK_PTABLE=$tmp/phonept sh offunset parts pt_off2.txt
check "no folder configured: no XML is written" \
	bash -c "[ -z \"\$(ls noxml/partition_*.xml 2>/dev/null)\" ] &&
		! grep -q '^partition xml:' sh_offenv.log && ! grep -q '^partition xml:' sh_offunset.log"
# The reference does drop its copy in the working directory (the `sd` runs above
# left one here), which is exactly why spdhost takes a folder instead: a tool
# run from / should not write there, and the menu's dumps are in one place.
check "spd_dump itself leaves partition_<unixtime>.xml in its cwd, as spd_dump.c:191 does" \
	bash -c '[ -n "$(ls partition_*.xml 2>/dev/null)" ]'
# The same folder as the flag, for a PC user driving the tool by hand. The flag
# wins over the variable, so a caller can override what the menu exported.
mkdir -p flagx envx
MOCK_PTABLE=$tmp/phonept SPDHOST_PART_XML_DIR=$tmp/envx timeout 20 ./sh --usb-fd 7 --step 0x1000 \
	--yes --part-xml "$tmp/flagx" exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin \
	"${LOAD[@]}" parts pt_flag.txt 7</dev/null </dev/null >sh_flagx.log 2>&1
frc=$?
check "--part-xml DIR writes there and beats SPDHOST_PART_XML_DIR (rc $frc)" \
	bash -c "[ $frc = 0 ] && [ -n \"\$(ls flagx/partition_*.xml 2>/dev/null)\" ] &&
		[ -z \"\$(ls envx/partition_*.xml 2>/dev/null)\" ]"
# A table whose rows are all >= 1 MiB reads in KiB (divisor 10), and the XML is
# MiB anyway: spd_dump writes size >> 20 and its reader turns the number back
# into bytes with size << 20, so MiB is the format rather than a property of the
# phone. Writing the read shift here instead was a bug -- it put 1024x the real
# size in every row, and feeding that back would claim a 5 GiB super was 5 TiB.
# Parity with the reference is the contract, on both kinds of table.
printf '%s\n' 'boot_a 4096' 'super 8192' 'userdata 6144' > unitspt
MOCK_PTABLE=$tmp/unitspt sh unit partition-list ours10.xml; shrc=$?
MOCK_PTABLE=$tmp/unitspt sd unit2 skip_confirm 1 partition_list theirs10.xml reset; sdrc=$?
check "KiB-unit table: partition-list is byte-identical to spd_dump (rc $shrc/$sdrc)" \
	bash -c "[ $shrc = 0 ] && [ $sdrc = 0 ] && cmp -s ours10.xml theirs10.xml"
check "the unit normalises to MiB (boot_a 4096 KiB -> 4, super 8192 KiB -> 8)" \
	bash -c "grep -q 'Partition id=\"boot_a\" size=\"4\"' ours10.xml &&
		grep -q 'Partition id=\"super\" size=\"8\"' ours10.xml &&
		grep -q 'Partition id=\"userdata\" size=\"0xffffffff\"' ours10.xml"
sh unitrt repartition ours10.xml; rc=$?
check "the same dump fed back carries the MiB numbers (super 8) (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'repartition: \[2\] super size=8' sh_unitrt.log"
# A table whose unit is not KiB, and one holding a zero-size row. fetch_ptab's
# divisor loop skips zero entries; spd_dump's own loop spins on one, which is
# why ours is written to survive the table that would hang the reference.
printf '%s\n' 'tiny 1' 'boot_a 4096' > tinypt
MOCK_PTABLE=$tmp/tinypt sh tiny partition-list tiny.xml; rc=$?
check "a table in another unit dumps as whole MiB, not rounded to 0 (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'Partition id=\"tiny\" size=\"1\"' tiny.xml"
printf '%s\n' 'zero 0' 'boot_a 4096' > zeropt
MOCK_PTABLE=$tmp/zeropt sh zero partition-list zero.xml; rc=$?
check "a zero-size row dumps as size=\"0\" instead of hanging (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'Partition id=\"zero\" size=\"0\"' zero.xml"

# The real table this feature exists for: a 73-row ums9230 layout whose super is
# grown from the stock 5 GiB to 10 GiB (size 10000), the edit people actually
# make. It is the shape a phone reports -- 1 MiB rows all over, ~0 on the last --
# and it has to parse whole: 73 entries is 5548 bytes, well inside the 862 the
# 16-bit frame allows, and none of its names or sizes may be dropped.
cp "$root/tests/repart-super10g.xml" .
sh real repartition repart-super10g.xml; rc=$?
check "the real 5 GB -> 10 GB super table is sent whole (73 entries, rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -qE '^SEQ 0b len=5548 ' sh_real.seq &&
		grep -q 'repartition: \[46\] super size=10000' sh_real.log &&
		grep -q 'repartition: sent 73 entries' sh_real.log"

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

# The slot a bare name resolves to is read from misc, so a command sequence that
# changes the slot and then resolves again has to see the NEW one. Caching the
# slot per connection answered the second resolve with the first slot's row,
# which is the wrong partition for a read -- and would be for a write.
sh slotflip parts pt.txt read-part boot 0 0x100 fa.bin set-active b read-part boot 0 0x100 fb.bin
rc=$?
# The resolved name is what spdhost logs for the read; the READ_PARTITION frame
# carries it too, but the log states the resolution without unpacking a frame.
grep -o 'read boot_[ab]:' sh_slotflip.log > slotflip.names
check "slot change mid-session: boot resolves boot_a then boot_b (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \"\$(tr '\n' ' ' < slotflip.names)\" = 'read boot_a: read boot_b: ' ]"

# write-parts: slot a image is sent, slot b is not, metadata erased when super is present.
mkdir -p imgs
printf 'A' > imgs/boot_a.img
printf 'B' > imgs/boot_b.img
printf 'S' > imgs/super.img
sh restore parts pt.txt write-parts imgs; rc=$?
check "write-parts writes boot_a, skips boot_b, erases metadata (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q '62006f006f0074005f006100' sh_restore.seq && ! grep -q '62006f006f0074005f006200' sh_restore.seq && grep -q 'erasing metadata' sh_restore.log && grep -q 'set-active: slot a' sh_restore.log"
mkdir -p flashdir
printf 'A' > flashdir/boot_a.img
printf 'B' > flashdir/boot_b.img
printf 'S' > flashdir/super.img
sh flash parts pt.txt write-files flashdir; rc=$?
check "write-files writes both slots and leaves metadata and the slot (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q '62006f006f0074005f006100' sh_flash.seq && grep -q '62006f006f0074005f006200' sh_flash.seq && ! grep -q 'erasing metadata' sh_flash.log && ! grep -q 'set-active: slot' sh_flash.log"

sh noerase parts pt.txt erase-part persist; rc=$?
check "erase persist refused (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'refusing' sh_noerase.log"
sh nospl parts pt.txt erase-part splloader; rc=$?
check "erase splloader refused (rc $rc)" bash -c "[ $rc != 0 ] && grep -q 'refusing' sh_nospl.log"

# Oversized boot image is not sent. The check is on a START_DATA frame (0x01),
# not on the name appearing anywhere in the log: the table read probes the
# DEVICE with READ_START (0x10) frames that carry partition names too, and
# "uboot_a" has "boot_a" inside it, so a whole-file grep matched the probe the
# FDL2 stage sends and stopped meaning "this partition was written".
dd if=/dev/zero of=huge.img bs=1 count=1 seek=$((5*1024*1024)) status=none
sh huge parts pt.txt write-part boot_a huge.img; rc=$?
check "oversized write refused before START (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothing sent' sh_huge.log && ! grep -qE '^SEQ 01 .*62006f006f0074005f006100' sh_huge.seq"

# An unknown name is skipped. The sibling that is on the phone is still written.
mkdir -p skipdir
printf 'A' > skipdir/boot_a.img
printf 'Z' > skipdir/nosuchpart.img
sh skip parts pt.txt write-parts skipdir; rc=$?
check "unknown name skipped, boot_a still written (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q '62006f006f0074005f006100' sh_skip.seq && grep -q 'skip nosuchpart' sh_skip.log"

# A broken fixnv1 is skipped during a restore. A single write-part still sends nothing.
mkdir -p nvbad
printf 'A' > nvbad/boot_a.img
printf 'NOTNV' > nvbad/l_fixnv1.img
sh nvbad parts pt.txt write-parts nvbad; rc=$?
check "broken fixnv1 skipped, boot_a still written (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q '62006f006f0074005f006100' sh_nvbad.seq && ! grep -q '6c005f006600690078006e0076003100' sh_nvbad.seq && grep -q 'not an NV image' sh_nvbad.log"
sh nvone parts pt.txt write-part l_fixnv1 nvbad/l_fixnv1.img; rc=$?
check "single broken fixnv1 sends nothing (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothing sent' sh_nvone.log && ! grep -q '6c005f006600690078006e0076003100' sh_nvone.seq"

# A numeric partition id is expanded to the table row's real name, so the
# literal-name checks in spd_write_named have to run on the resolved name:
# id 1 is misc here (0 is splloader, the first row is 1), and writing it as a
# raw partition would skip every size/backup/read-back guard that the misc
# path enforces. The neighbouring id must still write normally, so this is
# not just "id 1 is always refused".
sh idmisc parts pt.txt write-part 1 boot.img; rc=$?
check "numeric id resolving to misc is sent to the backup path, not written raw (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'resolves to misc' sh_idmisc.log && ! grep -qE '^SEQ 01 .*6d00690073006300' sh_idmisc.seq"
sh iduboot parts pt.txt write-part 2 boot.img; rc=$?
check "the next numeric id (uboot_a) still writes (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'write uboot_a' sh_iduboot.log"

# A numeric id with no table takes the -2 path: the name is sent as given. The
# lookup must fill the resolved name there too, or the misc/calinv comparisons
# in spd_write_named read an uninitialised buffer.
#
# There is no "no table" session any more just by leaving `parts` out: the FDL2
# stage reads the table by itself, as the reference does (spd_dump.c:755), so
# the only way to reach -2 is a device that REFUSES one. The mock refuses only
# when MOCK_PTABLE is unset -- its empty and "1" values both select the built-in
# table -- so this case runs with the variable removed rather than blanked.
sh_nopt() { local L=$1; shift; ( unset MOCK_PTABLE; MOCK_LOG=sh_$L.seq timeout 20 ./sh --usb-fd 7 --step 0x1000 --yes \
	exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin "${LOAD[@]}" "$@" 7</dev/null </dev/null >sh_$L.log 2>&1 ); }
sh_nopt nonpt write-part 5 boot.img; rc=$?
check "a refused table: a numeric id is sent as given and read no stale name (rc $rc)" \
	bash -c "grep -q 'no partition table yet' sh_nonpt.log && ! grep -q 'resolves to misc' sh_nonpt.log && ! grep -q 'restore calinv' sh_nonpt.log"

# No splloader row: a file past the 256 KiB dump size is offered. This mock's
# unlisted splloader is still 256 KiB, so the device NACKs, but the client
# must not refuse before START.
dd if=/dev/zero of=bigspl.img bs=1024 count=300 status=none
sh splnack parts pt.txt write-part splloader bigspl.img; rc=$?
check "splloader over 256KiB is offered when the table has no row (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q '730070006c006c006f006100640065007200' sh_splnack.seq && ! grep -q 'nothing sent' sh_splnack.log"
# A listed row of 2048 KiB (shift stays 10) accepts that same 300 KiB file.
cp pt pt-spl
echo 'splloader 2048' >> pt-spl
MOCK_PTABLE=$tmp/pt-spl sh splok parts ptspl-out.txt write-part splloader bigspl.img; rc=$?
check "splloader write uses the live row, not the 256KiB dump size (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q '730070006c006c006f006100640065007200' sh_splok.seq && ! grep -q 'nothing sent' sh_splok.log"

# A mid-partition refusal: the loader takes the first chunk and NACKs the
# second. spd_dump's load_partition breaks out of its loop and STILL sends
# END_DATA; stopping without it leaves the loader waiting for the rest of a
# partition we have abandoned. The loader lets go after the refused chunk, so
# the only frame after it may be that END_DATA.
dd if=/dev/zero bs=9000 count=1 status=none | tr '\0' 'M' > mid.img
sd wmid skip_confirm 1 partition_list p.xml w boot_a mid.img
MOCK_FAIL_WRITE_MID=boot_a sh wmid parts pt.txt write-part boot_a mid.img; shrc=$?
wtail() { awk -v p="$2" '$1=="SEQ"&&$2=="01"&&index($4,p){on=1} on' "$1"; }
wtail sd_wmid.seq 62006f006f0074005f006100 | tail -1 > a_wmid
wtail sh_wmid.seq 62006f006f0074005f006100 > b_wmid
check "mid-write refusal: END_DATA still sent, nothing after it (rc $shrc)" \
	bash -c "[ $shrc != 0 ] && grep -q 'write response 0x0082 at offset 4096' sh_wmid.log &&
		tail -1 b_wmid | grep -q '^SEQ 03 ' && [ \$(grep -c '^SEQ 02 ' b_wmid) = 2 ] &&
		[ -s a_wmid ] && [ \"\$(cut -d' ' -f1-2 a_wmid)\" = \"\$(cut -d' ' -f1-2 <(tail -1 b_wmid))\" ]"

# super without a metadata row must not erase after the super write.
grep -v '^metadata ' pt > pt-nometa
mkdir -p nometa
printf 'S' > nometa/super.img
MOCK_PTABLE=$tmp/pt-nometa sh nometa parts ptnometa.txt write-parts nometa; rc=$?
check "no metadata row: super is written and metadata is left alone (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'leaving it alone' sh_nometa.log && ! grep -q 'erasing metadata' sh_nometa.log && grep -q '73007500700065007200' sh_nometa.seq"

# Sparse container: same bytes, longer per-chunk wait. Mock acks immediately.
python3 -c 'open("sparse.img","wb").write(bytes.fromhex("3aff26ed")+b"\x00"*64)'
sh sparse parts pt.txt write-part super sparse.img; rc=$?
check "sparse image uses the 100s chunk wait (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'waiting up to 100000 ms' sh_sparse.log && grep -q '73007500700065007200' sh_sparse.seq"

# One oversized image still aborts the whole plan before any START.
mkdir -p hugedir
dd if=/dev/zero of=hugedir/boot_a.img bs=1 count=1 seek=$((5*1024*1024)) status=none
printf 'V' > hugedir/notapart.img
sh hugedir parts pt.txt write-parts hugedir; rc=$?
check "oversized image aborts the plan before START (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ 01 .*62006f006f0074005f006100' sh_hugedir.seq"

# Two dumps in one process must both stay in the manifest (imei set).
mkdir -p twodump
sh twodump parts pt.txt dump boot_a twodump dump boot_b twodump; rc=$?
check "two dumps append the manifest (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'ok boot_a' twodump/dump-manifest.txt && grep -q 'ok boot_b' twodump/dump-manifest.txt && [ \$(stat -c %s twodump/boot_a.img) = $((4096*1024)) ]"

# DANGEROUS commands. --yes is already on the sh() line and must not be enough.
cp pt pt-vb
echo 'vbmeta 1024' >> pt-vb
MOCK_PTABLE=$tmp/pt-vb sh verbad --dangerous parts ptv.txt verity 0; rc=$?
check "verity 0 rewrites vbmeta byte 0x7b to 01 (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'DANGEROUS verity: vbmeta byte 0x7b: .* -> 01' sh_verbad.log && grep -q '760062006d00650074006100' sh_verbad.seq"
MOCK_PTABLE=$tmp/pt-vb sh veron --dangerous parts ptv2.txt verity 1; rc=$?
check "verity 1 writes 00 and skips missing vbmeta_* (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'DANGEROUS verity: vbmeta byte 0x7b: .* -> 00' sh_veron.log && grep -q 'skip vbmeta_system' sh_veron.log"
sh vergate --dangerous parts pt.txt verity 0; rc=$?
check "verity 0 with no vbmeta sends nothing (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothing sent' sh_vergate.log && ! grep -q 'DANGEROUS verity:' sh_vergate.log"
MOCK_PTABLE=$tmp/pt-vb sh vergate2 parts ptv3.txt verity 0; rc=$?
check "verity ignores --yes (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'does not authorize' sh_vergate2.log && ! grep -q 'DANGEROUS verity:' sh_vergate2.log"
cp pt pt-huge
echo 'vbmeta 81920' >> pt-huge
MOCK_PTABLE=$tmp/pt-huge sh verhuge --dangerous parts pthuge.txt verity 0; rc=$?
check "verity refuses a vbmeta over 64MB before the patch (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q '64MB' sh_verhuge.log && ! grep -q 'DANGEROUS verity:' sh_verhuge.log"

cp pt pt-frp
echo 'persist 1024' >> pt-frp
MOCK_PTABLE=$tmp/pt-frp sh frp --dangerous parts ptfrp.txt frp-reset persist-out.img; rc=$?
check "frp-reset backs up persist then erases it (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(wc -c < persist-out.img) = 1048576 ] && grep -q 'erased persist' sh_frp.log && grep -q 'SEQ 0a ' sh_frp.seq && grep -q '7000650072007300690073007400' sh_frp.seq"
MOCK_PTABLE=$tmp/pt-frp sh frpgate parts ptfrp2.txt frp-reset persist-no.img; rc=$?
check "frp-reset ignores --yes and does not erase (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothing sent' sh_frpgate.log && ! grep -q 'SEQ 0a ' sh_frpgate.seq && [ ! -f persist-no.img ]"
sh frpstill --dangerous parts pt.txt erase-part persist; rc=$?
check "erase-part persist stays refused with --dangerous (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'refusing' sh_frpstill.log && ! grep -q 'SEQ 0a ' sh_frpstill.seq"
sh splerg --dangerous parts pt.txt danger-erase splloader; rc=$?
check "danger-erase splloader is sent when the row is absent (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'erasing that name anyway' sh_splerg.log && grep -q 'SEQ 0a ' sh_splerg.seq && grep -q '730070006c006c006f006100640065007200' sh_splerg.seq"
sh splno parts pt.txt danger-erase splloader; rc=$?
check "danger-erase ignores --yes (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothing sent' sh_splno.log && ! grep -q 'SEQ 0a ' sh_splno.seq"
sh bootno --dangerous parts pt.txt danger-erase boot_a; rc=$?
check "danger-erase refuses boot_a (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'refusing' sh_bootno.log && ! grep -q 'SEQ 0a ' sh_bootno.seq"

# Menu: missing unlock files send nothing. Present files still need a TTY word.
menu_unlock_missing() {
	local d
	d=$(mktemp -d)
	( cd "$d" && SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/echo bash -c "source \"$root/scripts/menu.sh\"; unlock_bootloader_menu" >"$d/out" 2>"$d/err" )
	grep -q fdl2-cboot.bin "$d/out" && grep -q "nothing sent" "$d/out" && ! grep -q danger-erase "$d/out"
}
menu_danger_notty() {
	local d rec
	d=$(mktemp -d)
	rec=$d/ran
	: >"$rec"
	cat >"$d/run" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$rec"
EOF
	chmod +x "$d/run"
	( cd "$d" && SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER="$d/run" bash -c "source \"$root/scripts/menu.sh\"; verity_menu; frp_reset_menu" </dev/null >"$d/out" 2>"$d/err" )
	grep -q "Nothing sent" "$d/out" && ! grep -q . "$rec"
}
check "menu unlock names missing loaders and sends nothing" menu_unlock_missing
menu_find_release_files() {
	local d found
	d=$(mktemp -d)
	mkdir -p "$d/ums9230/infinix" "$d/pkg/ums9230/infinix"
	printf x > "$d/ums9230/infinix/fdl2-cboot.bin"
	printf x > "$d/pkg/gen_spl-unlock"
	chmod +x "$d/pkg/gen_spl-unlock"
	: > "$d/pkg/ums9230/infinix/fdl1-dl.bin"
	found=$(cd "$d" && SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c "source \"$root/scripts/menu.sh\"
find_user_file fdl2-cboot.bin
FDL1=\"$d/pkg/ums9230/infinix/fdl1-dl.bin\"
find_gen_spl_unlock")
	[[ $found == "$d/ums9230/infinix/fdl2-cboot.bin"$'\n'"$d/pkg/gen_spl-unlock" ]]
}
check "menu finds release fdl2-cboot.bin and gen_spl-unlock" menu_find_release_files
check "menu verity and FRP refuse without a TTY" menu_danger_notty
# Release menu endings: recovery and fastbootd after the images.
sh after parts pt.txt write-parts imgs reboot-recovery; rc=$?
check "write-parts then reboot-recovery writes the BCB (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q '62006f006f0074005f006100' sh_after.seq && grep -q 'writing 2048-byte BCB' sh_after.log && grep -q 'reboot-recovery' sh_after.log"
# SPDHOST_MENU_CONFIG: boot_after_menu now persists the choice, and without
# this it would write over the developer's real ~/.spdhost-menu.conf.
ba=$(SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true SPDHOST_MENU_CONFIG="$tmp/none.conf" \
	bash -c "source '$root/scripts/menu.sh'
boot_after_menu >/dev/null <<'EOF'
2
y
EOF
boot_after_menu >/dev/null <<'EOF'
3
y
EOF
printf %s \"\$BOOT_AFTER\"")
check "menu boot-after offers recovery and fastbootd" test "$ba" = reboot-fastboot
check "menu boot-after is persisted to the config" bash -c \
	"grep -qx 'BOOT_AFTER=reboot-fastboot' '$tmp/none.conf'"
# A config with a bogus BOOT_AFTER must not be believed: the value reaches
# run_session as a command argument, so load_config allowlists it.
printf 'BOOT_AFTER=rm-rf\n' > "$tmp/bad.conf"
badba=$(SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true SPDHOST_MENU_CONFIG="$tmp/bad.conf" \
	bash -c "source '$root/scripts/menu.sh'; printf %s \"\$BOOT_AFTER\"")
check "menu ignores a BOOT_AFTER outside the allowlist" test "$badba" = reset

# Extra [11]: chip-uid, the read-only spd_dump chip_uid the menu used to have no
# entry for. One session, the exec stub in front of FDL1, and no --yes.
menu_extra_chip_uid() {
	cat > "$tmp/cu.sh" <<EOF
source '$root/scripts/menu.sh'
FDL1=$tmp/fdl1-dl.bin FDL1_ADDR=0x65000800 FDL2=$tmp/fdl2-dl.bin FDL2_ADDR=0x9efffe00
cls() { :; }; pause() { :; }; ready() { :; }
extra_menu <<'IN'
11
y
IN
EOF
	SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true SPDHOST_MENU_CONFIG="$tmp/none.conf" \
		SPDHOST_EXEC_ADDR=0x65015f08 timeout 20 bash "$tmp/cu.sh" 2>&1
}
cu=$(menu_extra_chip_uid)
# $cu goes in as an argument: `bash -c` gets a fresh shell and cannot see the
# parent's variables, so a `\$cu` inside the string would expand to nothing
# (and an empty subject makes the `! grep` check below pass for the wrong reason).
check "menu Extra [11] sends one chip-uid session" \
	bash -c "[ \$(grep -c '^+ ' <<<\"\$1\") = 1 ] && grep -Eq '^\+ .* chip-uid\$' <<<\"\$1\"" _ "$cu"
check "menu Extra [11] sends no --yes for chip-uid" \
	bash -c "! grep -q -- '--yes' <<<\"\$1\"" _ "$cu"

# EOF must end a prompt loop, not restart it: read leaves its variable empty,
# so the old ask_* loops treated a closed stdin as endless invalid answers.
menu_askers_stop_on_eof() {
	local out rc
	out=$(timeout 10 env SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c \
		"source '$root/scripts/menu.sh'
ask_addr 'FDL1 address:' </dev/null; echo rc=\$?
ask_file 'FDL1 file:' </dev/null; echo rc=\$?" 2>&1); rc=$?
	[[ $rc = 0 ]] || return 1
	[[ $(grep -c 'rc=1' <<<"$out") = 2 ]]
}
check "menu ask_addr/ask_file return on EOF instead of spinning" menu_askers_stop_on_eof

# Declining the loader confirm must leave the live chip globals alone, or the
# rejected chip's exec stub stays selected (and hex mode would persist it).
menu_shipped_decline_keeps_stub() {
	local got
	got=$(timeout 30 env SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true \
		SPDHOST_MENU_CONFIG="$tmp/none3.conf" bash -c "source '$root/scripts/menu.sh'
printf 'before=%s\n' \"\$EXEC_ADDR_DEFAULT\"
select_shipped_model >/dev/null 2>&1 <<'EOF'
2
y
1
y
no
EOF
printf 'after=%s\n' \"\$EXEC_ADDR_DEFAULT\"")
	grep -qx 'before=0x65015f08' <<<"$got" && grep -qx 'after=0x65015f08' <<<"$got"
}
check "menu keeps the old exec stub when the loader confirm is declined" menu_shipped_decline_keeps_stub

# The main loop used to treat EOF as "Not a choice." and re-prompt forever.
menu_eof_quits() {
	local out rc
	out=$(cd "$root" && timeout 30 env SPDHOST_MENU_LIB= SPDHOST_MENU_CONFIG="$tmp/none4.conf" \
		SPDHOST_DUMP_DIR="$tmp/eof-dump" SPDHOST_INPUT_DIR="$tmp/eof-input" \
		bash scripts/menu.sh </dev/null 2>&1); rc=$?
	[[ $rc = 0 ]] && grep -q 'Input closed' <<<"$out"
}
check "menu quits on EOF at the main prompt (no spin)" menu_eof_quits

# smoke_test used a hardcoded /tmp (absent on Termux): the redirect failed, the
# grep failed on the missing file, and it reported PASS having read nothing.
check "menu resolves a Termux-safe temp dir for the smoke probe" bash -c \
	"SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c \"source '$root/scripts/menu.sh'
grep -q 'spd_tmpdir' \\\"\\\$(declare -f smoke_test)\\\"
d=\\\$(TMPDIR='$tmp' spd_tmpdir) && [ \\\"\\\$d\\\" = '$tmp' ]
u=\\\$(TMPDIR=/nonexistent-xyz PREFIX= spd_tmpdir) && [ \\\"\\\$u\\\" = /tmp ]\""
check "menu flash/restore/repartition functions exist" bash -c "SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c 'source \"$root/scripts/menu.sh\"; type flash_input_menu restore_backup_menu repartition_menu set_slot_menu extra_menu dump_imei_session verity_menu frp_reset_menu unlock_bootloader_menu'"
# Files present, no TTY: still nothing. Files present on a pty: sessions run, erase only after the dump, and the menu does not pass --dangerous.
check "menu unlock on a pty dumps before erase and does not pass --dangerous" python3 - "$root" "$tmp" << 'PY'
import os, pty, select, subprocess, sys, time, pathlib
root = pathlib.Path(sys.argv[1])
work = pathlib.Path(sys.argv[2]) / "ubl"
work.mkdir()
(work / "fdl2-cboot.bin").write_bytes(b"cboot")
(work / "spl-unlock.bin").write_bytes(b"unlock")
rec = work / "ran"
runner = work / "run"
runner.write_text("""#!/bin/sh
printf '%%s\\n' "$*" >> "%s"
case "$*" in
  *read-part*splloader*|*dump*splloader*)
    mkdir -p "%s/backup_spl"
    printf spl > "%s/backup_spl/splloader.img"
    printf ub > "%s/backup_spl/uboot_a.img"
    printf 'old\\n' > "%s/backup_spl/uboot.img"
    printf 'slot a\\nok uboot_a\\n' > "%s/backup_spl/dump-manifest.txt"
    ;;
esac
exit 0
""" % (rec, work, work, work, work, work))
runner.chmod(0o755)
fdl1 = root / "fdl/ums9230/infinix/fdl1-dl.bin"
fdl2 = root / "fdl/ums9230/infinix/fdl2-dl.bin"
script = """
source "%s/scripts/menu.sh"
FDL1="%s"
FDL1_ADDR=0x65000800
FDL2="%s"
FDL2_ADDR=0x9efffe00
unlock_bootloader_menu
""" % (root, fdl1, fdl2)
env = os.environ.copy()
env.update(SPDHOST_MENU_LIB="1", SPDHOST_MENU_RUNNER=str(runner), SPDHOST_DUMP_DIR=str(work / "backup"))
master, slave = pty.openpty()
p = subprocess.Popen(["bash", "-c", script], stdin=slave, stdout=slave, stderr=slave, cwd=work, env=env)
os.close(slave)
os.write(master, b"dangerous\n")
deadline = time.time() + 15
while time.time() < deadline and p.poll() is None:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            os.read(master, 4096)
        except OSError:
            # EOF: the child closed the pty on its way out. poll() can still
            # report None for a moment after that, so wait for the exit instead
            # of calling a finished menu hung (it did hang CI once).
            time.sleep(0.05)
            continue
    else:
        try:
            os.write(master, b"\n")
        except OSError:
            time.sleep(0.05)
if p.poll() is None:
    p.kill()
    p.wait()
    raise SystemExit("unlock menu hung")
rc = p.wait()
text = rec.read_text() if rec.exists() else ""
lines = [ln for ln in text.splitlines() if ln.strip()]
def has(pred):
    return next((i for i, ln in enumerate(lines) if pred(ln)), -1)
dump_i = has(lambda s: "read-part" in s and "splloader" in s and "262144" in s and "danger-erase" not in s)
erase_i = has(lambda s: "danger-erase" in s and "splloader_bak" in s)
cboot_i = has(lambda s: "write-part" in s and "uboot" in s and "fdl2-cboot.bin" in s)
unlock_i = has(lambda s: "spl-unlock.bin" in s and "fdl2-dl.bin" not in s)
status_i = has(lambda s: "read-part" in s and "miscdata" in s and "8192" in s)
restore_i = has(lambda s: "write-part" in s and "splloader.img" in s and "uboot_a.img" in s and "parts" in s)
bad = []
if rc != 0:
    bad.append("rc %s" % rc)
if any("--dangerous" in ln or "--yes" in ln or "--keep-going" in ln for ln in lines):
    bad.append("flag leaked: " + text)
order = [dump_i, erase_i, cboot_i, unlock_i, status_i, restore_i]
if any(i < 0 for i in order) or order != sorted(order):
    bad.append("order %s\n%s" % (order, text))
if bad:
    raise SystemExit("; ".join(bad))
PY
bash -n "$root/scripts/menu.sh"
check "menu.sh syntax" test $? -eq 0

# 'new' at the repartition prompt dumps the phone's own table as the XML to
# start from. That step must be a READ: the menu used to demand an XML the tool
# could not produce, and the obvious wrong wiring here would be to send the
# table it had just read straight back as a repartition.
check "menu 'new' dumps the table as XML and sends no repartition" python3 - "$root" "$tmp" << 'PY'
import os, pty, select, subprocess, sys, time, pathlib
root = pathlib.Path(sys.argv[1])
work = pathlib.Path(sys.argv[2]) / "rep"
work.mkdir()
(work / "backup").mkdir()
rec = work / "ran"
runner = work / "run"
runner.write_text("#!/bin/sh\nprintf '%%s\\n' \"$*\" >> \"%s\"\nexit 0\n" % rec)
runner.chmod(0o755)
script = """
source "%s/scripts/menu.sh"
FDL1="%s"
FDL1_ADDR=0x65000800
FDL2="%s"
FDL2_ADDR=0x9efffe00
repartition_menu
""" % (root, root / "fdl/ums9230/infinix/fdl1-dl.bin", root / "fdl/ums9230/infinix/fdl2-dl.bin")
env = os.environ.copy()
env.update(SPDHOST_MENU_LIB="1", SPDHOST_MENU_RUNNER=str(runner),
           SPDHOST_DUMP_DIR=str(work / "backup"))
master, slave = pty.openpty()
p = subprocess.Popen(["bash", "-c", script], stdin=slave, stdout=slave,
                     stderr=slave, cwd=work, env=env)
os.close(slave)
os.write(master, b"new\n")
out = b""
stall = time.time()
deadline = time.time() + 30
while time.time() < deadline and p.poll() is None:
    r, _, _ = select.select([master], [], [], 0.2)
    if not r:
        # A prompt that printed nothing would otherwise wait forever: this menu
        # answers every question with a pause, so an empty line is always a
        # legal answer here.
        if time.time() - stall > 1.5:
            stall = time.time()
            try:
                os.write(master, b"\n")
            except OSError:
                pass
        continue
    stall = time.time()
    try:
        out += os.read(master, 4096)
    except OSError:
        # EOF while the child exits: poll() can lag that by a moment, so wait
        # for the exit rather than declaring a finished menu hung.
        time.sleep(0.05)
        continue
    # Any later prompt (ready's pause) just gets an empty line.
    try:
        os.write(master, b"\n")
    except OSError:
        pass
if p.poll() is None:
    p.kill()
    p.wait()
    raise SystemExit("repartition menu hung\n" + out.decode("utf-8", "replace"))
rc = p.wait()
text = out.decode("utf-8", "replace")
ran = rec.read_text() if rec.exists() else ""
bad = []
if rc != 0:
    bad.append("rc %s" % rc)
if "partition-list" not in ran or ".xml" not in ran:
    bad.append("no partition-list dump: %r" % ran)
if "repartition" in ran:
    bad.append("sent a repartition: %r" % ran)
if "Nothing was sent to the phone" not in text:
    bad.append("did not say it only read: %r" % text)
if bad:
    raise SystemExit("; ".join(bad))
PY

# Ctrl-C stops the run whatever --keep-going says. An interrupted read leaves
# the loader waiting for the rest of a transfer that was never ended, so the
# next command in the sequence would go into a desynchronised loader -- and a
# long read is exactly when a user reaches for Ctrl-C. 32 MiB at the smallest
# legal step is ~500k round trips, so the signal lands inside the read; the
# second read must never run.
printf '%s\n' 'slowpart 32768' >> pt
./sh --usb-fd 7 --step 0x40 --yes --keep-going exec_addr 0x65015f08 \
	custom_exec_no_verify_65015f08.bin "${LOAD[@]}" parts pt.txt \
	read-part slowpart 0 - slow1.bin read-part boot_a 0 0x100 slow2.bin reset 7</dev/null \
	</dev/null >sigint.log 2>&1 &
sigpid=$!
sleep 1
kill -INT "$sigpid" 2>/dev/null
wait "$sigpid"; rc=$?
check "Ctrl-C under --keep-going stops the run before the next command (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q \"interrupted; stopping before 'read-part'\" sigint.log &&
		! grep -q \"stopping before 'reset'\" sigint.log && [ ! -f slow2.bin ]"

echo
echo "write-seq: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
