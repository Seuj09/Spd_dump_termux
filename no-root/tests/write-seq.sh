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

# Oversized boot image is not sent.
dd if=/dev/zero of=huge.img bs=1 count=1 seek=$((5*1024*1024)) status=none
sh huge parts pt.txt write-part boot_a huge.img; rc=$?
check "oversized write refused before START (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothing sent' sh_huge.log && ! grep -q '62006f006f0074005f006100' sh_huge.seq"

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
	bash -c "[ $rc != 0 ] && ! grep -q '62006f006f0074005f006100' sh_hugedir.seq"

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
            break
    else:
        try:
            os.write(master, b"\n")
        except OSError:
            break
if p.poll() is None:
    p.kill()
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

echo
echo "write-seq: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
