#!/usr/bin/env bash
# The compat-audit batch (compat-audit/REPORT.md §2/§4) on mock_fdl2:
#   H2  set-active a|b [--bcb recovery|fastboot]: one session, token = patch
#   H3  every BCB write is a read-modify-write of the WHOLE misc
#   H1  a reset whose ack is lost (device off the bus) after misc-verify OK
#   M1  a slot switch keeps the other slot's tries/successful; --spd-dump-slot
#   M5  boot/recovery/vbmeta of the target slot checked before a recovery end
#   M6  set-active refused without uboot_a/uboot_b
#   L1  a table divisor that is not 10 is called out and probed
#   L2  read-only menu sessions end the session
#   L4  misc rows other than 1 MiB
#   L5  unlock_pick_uboot prefers the active slot's uboot
#   M4  ums512 / sc9863a end to end, and a stub/FDL1 chip mismatch refused
# Usage (from no-root/): tests/compat-fixes-seq.sh   (KEEP=1 keeps the tmp dir)
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] && echo "tmp=$tmp" || trap 'rm -rf "$tmp"' EXIT
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
gcc -O2 -w -I"$root/tests" "$root/tests/gen_expected.c" -o "$tmp/gen" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' \
	'vbmeta_a 1024' 'vbmeta_b 1024' 'super 8192' 'metadata 1024' > pt
printf '%s\n' 'misc 1024' 'uboot 1024' 'boot 4096' 'recovery 4096' 'vbmeta 1024' > ptn
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a
LOAD=(fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
EX=(exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin)
sd() { local L=$1; shift; MOCK_LOG=sd_$L.seq MOCK_MISC_OUT=$tmp/sd_$L.misc TERMUX_USB_FD=7 timeout 30 ./sd exec_addr 0x65015f08 "${LOAD[@]}" exec "$@" 7</dev/null </dev/null >sd_$L.log 2>&1; }
# --yes only in tests that are about something else; the token cases pass
# --confirm-token like the menu does. The menu never passes --yes.
sh() { local L=$1 o=(); shift; while [[ ${1:-} == --* ]]; do o+=("$1"); shift; done
	MOCK_LOG=sh_$L.seq MOCK_MISC_OUT=$tmp/sh_$L.misc SPDHOST_STATUS_FILE=$tmp/sh_$L.st timeout 30 ./sh --usb-fd 7 "${o[@]}" \
		"${EX[@]}" "${LOAD[@]}" "$@" 7</dev/null </dev/null >sh_$L.log 2>&1; }
# The slot block helpers: build a valid AOSP bootloader_control, decode one.
cat > abc.py <<'PY'
import sys, zlib, struct
def build(active, a, b):
    # a/b = (priority, tries, successful)
    blk = bytearray(32)
    blk[0:2] = b'_' + active.encode()
    blk[4:8] = b'BCAB'
    blk[8] = 1
    blk[9] = 2
    for i, (p, t, s) in enumerate((a, b)):
        # slot_metadata: priority:4 tries_remaining:3 successful_boot:1
        blk[12 + 2 * i] = p | (t << 4) | ((s & 1) << 7)
    struct.pack_into('<I', blk, 28, zlib.crc32(bytes(blk[:28])) & 0xffffffff)
    return bytes(blk)
def show(path, off=0x800):
    d = open(path, 'rb').read()[off:off + 32]
    crc = struct.unpack_from('<I', d, 28)[0]
    out = [d[0:2].decode('latin1'), 'magic=' + d[4:8].decode('latin1'),
           'crc=' + ('ok' if crc == zlib.crc32(d[:28]) & 0xffffffff else 'bad')]
    for i in range(2):
        x, y = d[12 + 2 * i], d[13 + 2 * i]
        out.append('%s:p%d,t%d,s%d' % ('ab'[i], x & 15, (x >> 4) & 7, x >> 7))
    print(' '.join(out))
if sys.argv[1] == 'build':
    base = bytearray(open(sys.argv[2], 'rb').read())
    a = tuple(int(v) for v in sys.argv[4].split(','))
    b = tuple(int(v) for v in sys.argv[5].split(','))
    base[0x800:0x820] = build(sys.argv[3], a, b)
    open(sys.argv[6], 'wb').write(base)
else:
    show(sys.argv[2])
PY
./gen misc 0 1048576 > orig.misc
bcb() { python3 -c "
import sys
b = bytearray(0x800); b[0:13] = b'boot-recovery'
if sys.argv[1] == 'fastboot': b[0x40:0x40 + 20] = b'recovery\n--fastboot\n'
sys.stdout.buffer.write(b)" "$1"; }
bcb recovery > bcb_recovery; bcb fastboot > bcb_fastboot
REC=$(sha256sum bcb_recovery | awk '{print $1}')
misc_writes() { grep -cE '^SEQ 01 len=(7[6-9]|8[0-9]) 6d0069007300630000' "$1"; }
export -f misc_writes

# ---- H3 + MOCK_SLOT=b: reboot-recovery keeps slot b, whole misc RMW ----------
MOCK_SLOT=b ./gen misc 0 1048576 > orig_b.misc
MOCK_SLOT=b sh recb --confirm-token="$REC" parts pt.txt reboot-recovery; rc=$?
check "H3 slot b: reboot-recovery rc $rc, misc[0:0x800] = BCB, slot b block and the rest untouched" \
	bash -c "[ $rc = 0 ] && cmp -s <(head -c 2048 sh_recb.misc) bcb_recovery && cmp -s <(tail -c +2049 sh_recb.misc) <(tail -c +2049 orig_b.misc)"
check "H3: the BCB goes out as ONE whole-misc write (no 2048-byte MIDST)" \
		bash -c "[ \$(misc_writes sh_recb.seq) = 1 ] && ! grep -q '^SEQ 02 len=2048 ' sh_recb.seq"
check "M5 slot b: boot_b and vbmeta_b are the ones checked (and called empty here)" \
	bash -c "grep -q 'WARNING: boot_b has no ANDROID!/VNDRBOOT magic' sh_recb.log && grep -q 'WARNING: vbmeta_b has no AVB0 magic' sh_recb.log && ! grep -q 'boot_a has' sh_recb.log"
MOCK_SLOT=b MOCK_IMAGES=boot_b,vbmeta_b sh recb2 --confirm-token="$REC" parts pt.txt reboot-recovery; rc=$?
check "M5 slot b: real magics -> no warning (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'check: boot_b has its boot image magic' sh_recb2.log && grep -q 'check: vbmeta_b has its AVB0 magic' sh_recb2.log && ! grep -q WARNING sh_recb2.log"

# ---- H3: a loader that programs misc in 4 KiB units -----------------------------
MOCK_MISC_BLOCK=4096 sd blk4k reboot-recovery
python3 abc.py show sd_blk4k.misc > sd_blk4k.abc
MOCK_MISC_BLOCK=4096 sh blk4k --confirm-token="$REC" parts pt.txt reboot-recovery; rc=$?
check "H3 4K-unit loader: spd_dump's bare 2048-byte BCB write zeroes the slot block (the bug)" \
	bash -c "cmp -s <(head -c 2048 sd_blk4k.misc) bcb_recovery && cmp -s <(dd if=sd_blk4k.misc bs=1 skip=2048 count=2048 status=none) <(head -c 2048 /dev/zero)"
check "H3 4K-unit loader: spdhost's whole-misc write keeps the slot block (rc $rc)" \
	bash -c "[ $rc = 0 ] && cmp -s <(tail -c +2049 sh_blk4k.misc) <(tail -c +2049 orig.misc) && grep -q 'misc-verify: OK (1048576' sh_blk4k.log"
printf 'X%.0s' $(seq 2048) > wipe2k.bin
WS=$(sha256sum wipe2k.bin | awk '{print $1}')
MOCK_MISC_BLOCK=4096 sh blk4kw --confirm-token="$WS" parts pt.txt write-part misc wipe2k.bin reset; rc=$?
check "H3 4K-unit loader: write-part misc <2048-byte file> is RMW too (rc $rc)" \
	bash -c "[ $rc = 0 ] && cmp -s <(head -c 2048 sh_blk4kw.misc) wipe2k.bin && cmp -s <(tail -c +2049 sh_blk4kw.misc) <(tail -c +2049 orig.misc)"

# ---- H1: lost reset ack ------------------------------------------------------------
MOCK_RESET_GONE=1 sh gone --confirm-token="$REC" parts pt.txt reboot-recovery; rc=$?
check "H1: ack lost after misc-verify OK -> success, 'device left the bus on reset (expected)' (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'misc-verify: OK' sh_gone.log && grep -q 'device left the bus on reset (expected)' sh_gone.log"
check "H1: status file reports misc-verify=ok and reset=left-bus separately" \
	bash -c "grep -qx 'misc-verify=ok' sh_gone.st && grep -qx 'reset=left-bus' sh_gone.st"

# B2-7.1: PIPE (stall) must NOT count as left-bus success.
MOCK_RESET_PIPE=1 sh pipe --confirm-token="$REC" parts pt.txt reboot-recovery; rc=$?
check "B2-7.1: PIPE on reset ack -> failure, not left-bus (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -qE 'stall; device still on the bus|usb-error|FAILED: USB error' sh_pipe.log &&
		! grep -q 'device left the bus on reset \(expected\)' sh_pipe.log"
MOCK_RESET_SILENT=1 sh silent --confirm-token="$REC" parts pt.txt reboot-recovery; rc=$?
check "H1: a reset TIMEOUT is still a failure, misc-verify still reported ok (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'timeout waiting for the ack' sh_silent.log && grep -qx 'misc-verify=ok' sh_silent.st && grep -qx 'reset=timeout' sh_silent.st"
for c in reset power-off; do
	MOCK_RESET_GONE=1 sh gone_$c --yes "$c"; rc=$?
	check "H1: bare $c with the device leaving the bus -> rc 0 ($rc)" \
		bash -c "[ $rc = 0 ] && grep -q 'device left the bus on' sh_gone_$c.log"
done
# The menu prints the two results apart.
cat > runner <<R
#!/usr/bin/env bash
MOCK_LOG=$tmp/m\${M:-1}.seq MOCK_MISC_OUT=$tmp/m\${M:-1}.misc exec "$tmp/sh" --usb-fd 7 "\$@" 7</dev/null 2>>$tmp/m\${M:-1}.err
R
chmod +x runner
cat > menu_env.sh <<M
export SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=$tmp/runner SPDHOST_MENU_CONFIG=$tmp/none.conf
export SPDHOST_EXEC_ADDR=0x65015f08 SPDHOST_TIMEOUT=1000 SPDHOST_BIN=$tmp/sh TMPDIR=$tmp
source "$root/scripts/menu.sh"
FDL1=$tmp/fdl1-dl.bin FDL1_ADDR=0x65000800 FDL2=$tmp/fdl2-dl.bin FDL2_ADDR=0x9efffe00 DUMP_DIR=$tmp/mdump MISC_DIR=$root/misc SOC=ums9230
cls() { :; }; pause() { :; }; ready() { :; }
M
out=$(export M=1 MOCK_RESET_SILENT=1; source ./menu_env.sh; MISC_CONFIRM_TOKEN=$REC guarded_misc_session reboot-recovery reboot-recovery 2>&1)
check "H1 menu: misc verify OK and the reset failure are reported separately" \
	bash -c '[[ $1 == *"misc verify: OK"* && $1 == *"reset into recovery: FAILED -- no ack"* && $1 == *"misc WAS written and verified; only the reset into recovery did not complete"* ]]' _ "$out"
out=$(export M=2 MOCK_RESET_GONE=1; source ./menu_env.sh; MISC_CONFIRM_TOKEN=$REC guarded_misc_session reboot-recovery reboot-recovery 2>&1)
check "H1 menu: lost ack -> 'device left the bus on reset (expected)', session OK" \
	bash -c '[[ $1 == *"misc verify: OK"* && $1 == *"device left the bus on reset (expected)"* && $1 == *"misc written, read back and verified"* ]]' _ "$out"

# ---- H2 + M1: set-active b --bcb recovery, ONE session ------------------------------
# misc says slot a is active and good; slot b once booted fine and has 2 tries.
python3 abc.py build orig.misc a 15,5,1 14,2,1 live_a.misc
TOK=$(printf 'spdhost-set-active b %s\n' "$REC" | sha256sum | awk '{print $1}')
MOCK_MISC_IN=$tmp/live_a.misc sh sab --confirm-token="$TOK" parts pt.txt set-active b --bcb recovery; rc=$?
python3 abc.py show sh_sab.misc > sab.abc
check "H2: set-active b --bcb recovery in ONE session: rc $rc, one misc write, reset last" \
	bash -c "[ $rc = 0 ] && [ \$(misc_writes sh_sab.seq) = 1 ] && tail -1 sh_sab.seq | grep -q '^SEQ 05 ' && grep -q 'confirm-token matches' sh_sab.log"
check "H2: BCB at 0, slot b active; M1: slot a keeps tries 5 + successful, drops to prio 14 [$(cat sab.abc)]" \
	bash -c "cmp -s <(head -c 2048 sh_sab.misc) bcb_recovery && grep -qx '_b magic=BCAB crc=ok a:p14,t5,s1 b:p15,t6,s0' sab.abc && cmp -s <(tail -c +$((0x820 + 1)) sh_sab.misc) <(tail -c +$((0x820 + 1)) live_a.misc)"
check "H2: the token is the patch, not the image: the image sha would be refused" \
	bash -c "MOCK_MISC_IN=$tmp/live_a.misc MOCK_LOG=x.seq timeout 30 ./sh --usb-fd 7 --confirm-token $(sha256sum live_a.misc | awk '{print $1}') ${EX[*]} ${LOAD[*]} parts pt.txt set-active b 7</dev/null </dev/null >x.log 2>&1; [ \$? != 0 ] && grep -q 'confirm-token mismatch' x.log && [ \$(misc_writes x.seq) = 0 ]"
MOCK_MISC_IN=$tmp/live_a.misc sh sabc --yes --spd-dump-slot parts pt.txt set-active b; rc=$?
python3 abc.py show sh_sabc.misc > sabc.abc
check "M1: --spd-dump-slot writes spd_dump's exact block (a: prio 14, tries 1, successful 0) [$(cat sabc.abc)]" \
	bash -c "[ $rc = 0 ] && [ \$(dd if=sh_sabc.misc bs=1 skip=2048 count=32 status=none | od -An -tx1 | tr -d ' \n') = 5f62000042434142010200001e006f000000000000000000000000009ee21070 ]"
check "M6: super present -> slot b system may be empty, said before the write" \
	bash -c "grep -q \"slot b's system/vendor may be EMPTY\" sh_sab.log"

# ---- the slot block changes between two reads ----------------------------------------
# Session 1 reads misc (slot a: tries 5). The bootloader then counts a try down
# (tries 4) before session 2. The old two-session flow (misc-backup-expect +
# a pre-built image) refuses; the one-session set-active builds on what it
# reads and keeps tries 4.
MOCK_MISC_IN=$tmp/live_a.misc sh read1 --yes parts pt.txt misc-backup read1.img; r1=$?
python3 abc.py build orig.misc a 15,4,1 14,2,1 live_a2.misc
python3 abc.py build read1.img b 14,5,1 15,6,0 prebuilt.misc
PS=$(sha256sum prebuilt.misc | awk '{print $1}')
MOCK_MISC_IN=$tmp/live_a2.misc sh old2 --confirm-token="$PS" parts pt.txt misc-backup-expect old2.img "$(sha256sum read1.img | awk '{print $1}')" write-part misc prebuilt.misc reset; rc=$?
check "changed between reads: the old read-then-expect flow stops before writing (rc $r1/$rc)" \
	bash -c "[ $r1 = 0 ] && [ $rc != 0 ] && grep -q 'CHANGED' sh_old2.log && [ \$(misc_writes sh_old2.seq) = 0 ]"
TOKN=$(printf 'spdhost-set-active b none\n' | sha256sum | awk '{print $1}')
MOCK_MISC_IN=$tmp/live_a2.misc sh new2 --confirm-token="$TOKN" parts pt.txt set-active b reset; rc=$?
python3 abc.py show sh_new2.misc > new2.abc
check "changed between reads: one-session set-active keeps the NEW tries 4 [$(cat new2.abc)] (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -qx '_b magic=BCAB crc=ok a:p14,t4,s1 b:p15,t6,s0' new2.abc"

# ---- M6: not A/B ---------------------------------------------------------------------------
MOCK_PTABLE=$tmp/ptn MOCK_SLOT= sh nab --confirm-token="$TOKN" parts ptn.txt set-active b reset; rc=$?
check "M6: set-active refused on a table without uboot_a/uboot_b, nothing written (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'not A/B; nothing written' sh_nab.log && [ \$(misc_writes sh_nab.seq) = 0 ] && ! grep -q '^SEQ 05 ' sh_nab.seq"
MOCK_PTABLE=$tmp/ptn MOCK_SLOT= MOCK_IMAGES=boot,recovery,vbmeta sh nabrec --confirm-token="$REC" parts ptn.txt reboot-recovery; rc=$?
check "M5 non-A/B: boot, recovery and vbmeta are checked (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'check: boot has' sh_nabrec.log && grep -q 'check: recovery has' sh_nabrec.log && grep -q 'check: vbmeta has' sh_nabrec.log"

# ---- L4: misc rows other than 1 MiB -------------------------------------------------------
sed 's/^misc 1024$/misc 2048/' pt > pt2m
MOCK_PTABLE=$tmp/pt2m ./gen misc 0 2097152 > orig2m.misc 2>/dev/null || true
MOCK_PTABLE=$tmp/pt2m sh m2m --confirm-token="$REC" parts pt.txt reboot-recovery; rc=$?
check "2 MiB misc: whole 2 MiB written and verified, rest untouched (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(stat -c %s sh_m2m.misc) = 2097152 ] && grep -q 'misc-verify: OK (2097152' sh_m2m.log && cmp -s <(head -c 2048 sh_m2m.misc) bcb_recovery"
mkdir -p pm; MOCK_PTABLE=$tmp/pt2m sh m2mpm --yes parts pt.txt dump preset_modem pm; rc=$?
check "L4: preset_modem saves misc at the live 2 MiB (rc $rc)" \
	bash -c "[ -f pm/misc.img ] && [ \$(stat -c %s pm/misc.img) = 2097152 ]"
sed 's/^misc 1024$/misc 512/' pt > pt512
MOCK_PTABLE=$tmp/pt512 sh m512 --yes parts pt.txt; rc=$?
check "L1: a 512 KiB row lowers the divisor: warned, and a check_partition probe shows the doubled sizes (rc $rc)" \
	bash -c "grep -q 'not 10' sh_m512.log && grep -qE 'WARNING: uboot_a is 2097152 bytes by the table but the device answers 1048576' sh_m512.log"
sh m1m --yes parts pt.txt; rc=$?
check "L1: a divisor-10 table is not probed (no extra frames)" bash -c "! grep -q 'not 10' sh_m1m.log"

# ---- M4: ums512 / sc9863a end to end, and the mismatch ------------------------------------
e2e() { local soc=$1 brand=$2 f1=$3 ea=$4 L=$5
	cp "$root/fdl/$soc/$brand/fdl1-dl.bin" "f1_$soc.bin"; cp "$root/fdl/$soc/$brand/fdl2-dl.bin" "f2_$soc.bin"
	MOCK_LOG=sh_$L.seq MOCK_MISC_OUT=$tmp/sh_$L.misc timeout 30 ./sh --usb-fd 7 --confirm-token="$REC" exec_addr "$ea" "$root/fdl/$soc/custom_exec_no_verify_${ea#0x}.bin" \
		fdl "f1_$soc.bin" "$f1" fdl "f2_$soc.bin" 0x9efffe00 parts pt.txt reboot-recovery 7</dev/null </dev/null >sh_$L.log 2>&1; }
e2e ums512 infinix 0x5500 0x3ee8 u512; rc=$?
check "ums512 end to end: stub 0x3ee8 + FDL1 0x5500, highspeed step, recovery BCB written (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'exec_addr: 0x00003ee8' sh_u512.log && grep -q '^SEQ 02 len=63488 ' sh_u512.seq && cmp -s <(head -c 2048 sh_u512.misc) bcb_recovery && tail -1 sh_u512.seq | grep -q '^SEQ 05 '"
e2e sc9863a realme 0x5000 0x4ee8 s9863; rc=$?
check "sc9863a end to end: stub 0x4ee8 + FDL1 0x5000, recovery BCB written (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'exec_addr: 0x00004ee8' sh_s9863.log && cmp -s <(head -c 2048 sh_s9863.misc) bcb_recovery"
MOCK_LOG=mm.seq timeout 30 ./sh --usb-fd 7 --yes exec_addr 0x3ee8 "$root/fdl/ums512/custom_exec_no_verify_3ee8.bin" \
	fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00 parts pt.txt 7</dev/null </dev/null >mm.log 2>&1; rc=$?
check "M4: ums512 stub with ums9230's FDL1 address refused before any frame (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'is the ums512 stub, which goes with FDL1 at 0x5500' mm.log && ! grep -qs '^SEQ' mm.seq"
mkdir -p stray && cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" stray/custom_exec_no_verify_4ee8.bin
( cd stray && MOCK_LOG=st.seq timeout 30 ../sh --usb-fd 7 exec_addr 0x4ee8 fdl ../fdl1-dl.bin 0x5000 7</dev/null </dev/null >st.log 2>&1 ); rc=$?
check "L6: a stub in the working directory is not a default (fdl/<chip>/ only) (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'not found' stray/st.log"

# ---- menu: L2 endings, L6 default, L5 uboot pick ---------------------------------------
out=$(source ./menu_env.sh; BOOT_AFTER=reboot-recovery; RUNNER=(echo); fetch_parts_table 2>&1)
check "L2: fetch_parts_table ends with power-off when the ending writes misc" \
	bash -c '[[ $1 == *"misc-slotinfo.img power-off"* ]]' _ "$out"
# G1: the probe's answer is the table's own number << 10, so spdhost corrects the
# shift and the menu says so instead of calling the unit a guess.
out=$(export M=3 MOCK_PTABLE=$tmp/pt512; source ./menu_env.sh; BOOT_AFTER=reset; fetch_parts_table 2>&1)
check "L1/G1 menu: a shift-11 table the probe answers at << 10 is reported corrected to shift 10" \
	bash -c '[[ $1 == *"spdhost corrected"*"shift 10"* && $1 != *"unit is a guess"* ]] && grep -q "WARNING: uboot_a is 2097152 bytes by the table" m3.err' _ "$out"
# The probe row will not be sized: the unit stays a guess, and the menu says so.
out=$(export M=3 MOCK_PTABLE=$tmp/pt512 MOCK_NOPROBE=uboot_a; source ./menu_env.sh; BOOT_AFTER=reset; fetch_parts_table 2>&1)
check "L1 menu: a shift-11 table the device will not confirm is called a guess after the table fetch" \
	bash -c '[[ $1 == *"WARNING: this table'"'"'s unit is a guess the device did not confirm (shift 11"* ]]' _ "$out"
out=$(source ./menu_env.sh; BOOT_AFTER=reset; RUNNER=(echo); chip_uid_action 2>&1)
check "L2: chip-uid ends with the configured reset" bash -c '[[ $1 == *"chip-uid reset"* ]]' _ "$out"
out=$(unset SPDHOST_EXEC_ADDR; source ./menu_env.sh; unset SPDHOST_EXEC_ADDR; SOC= EXEC_ADDR=; exec_addr_value; echo "[end]")
check "L6: SOC unset -> no exec stub (not 0x65015f08)" test "$out" = "[end]"
mkdir -p ub && printf a > ub/uboot_a.img && printf b > ub/uboot_b.img
out=$(source ./menu_env.sh; ACTIVE_SLOT=b; unlock_pick_uboot "$tmp/ub")
check "L5: unlock_pick_uboot prefers uboot_<ACTIVE_SLOT>.img" test "$out" = "$tmp/ub/uboot_b.img"
printf 'ok uboot_a x\nok uboot_b x\n' > ub/dump-manifest.txt
out=$(source ./menu_env.sh; ACTIVE_SLOT=a; unlock_pick_uboot "$tmp/ub")
check "L5: with a manifest naming both, the active slot's copy wins" test "$out" = "$tmp/ub/uboot_a.img"

echo "compat-fixes-seq: $pass passed, $fail failed"
(( fail == 0 ))
