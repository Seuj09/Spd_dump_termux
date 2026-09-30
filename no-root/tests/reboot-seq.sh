#!/usr/bin/env bash
# Reboot paths: spdhost vs vendored spd_dump on tests/mock_fdl2.c, plus the
# misc-backup / read-back guard. Frames after FDL2 is up are compared
# byte-for-byte (FNV of each framed packet):
#   spd_dump: frames after its partition-list read (SEQ 2d) = the command itself
#   spdhost : frames after EXEC FDL2 (SEQ 04)
# Usage (from no-root/): tests/reboot-seq.sh
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
gcc -O2 -w -std=c11 -D_GNU_SOURCE -I"$root/tests" "$root/src/main.c" "$root/src/usb.c" "$root/src/proto.c" \
	"$root/src/dumpcmd.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
gcc -O2 -w -I"$root/tests" "$root/tests/gen_expected.c" -o "$tmp/gen" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
# A/B eMMC table (KiB), like the ums9230 Infinix target.
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' > pt
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a
LOAD=(fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
sd() { local L=$1; shift; MOCK_LOG=sd_$L.seq TERMUX_USB_FD=7 timeout 30 ./sd exec_addr 0x65015f08 "${LOAD[@]}" exec "$@" 7</dev/null </dev/null >sd_$L.log 2>&1; }
# --yes only inside this test (no TTY here). The menu never passes --yes.
sh() { local L=$1 o=(); shift; while [[ ${1:-} == --* ]]; do o+=("$1"); shift; done
	MOCK_LOG=sh_$L.seq timeout 30 ./sh --usb-fd 7 --yes "${o[@]}" exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin "${LOAD[@]}" "$@" 7</dev/null </dev/null >sh_$L.log 2>&1; }
sd_tail() { awk '/^SEQ 2d /{buf=""; on=1; next} on{buf=buf $0 "\n"} END{printf "%s", buf}' "$1"; }
sh_tail() { awk '/^SEQ 04 /{buf=""; on=1; next} on{buf=buf $0 "\n"} END{printf "%s", buf}' "$1"; }
short() { sed -E 's/^SEQ ([0-9a-f]+) len=([0-9]+).*/\1:\2/' "$1" | tr '\n' ' '; }

for pair in "reset reset" "poweroff power-off" "reboot-recovery reboot-recovery" "reboot-fastboot reboot-fastboot"; do
	set -- $pair
	rm -f misc.out; MOCK_MISC_OUT=$tmp/misc_sd_$1.bin sd "$1" "$1"; sdrc=$?
	MOCK_MISC_OUT=$tmp/misc_sh_$1.bin sh "$1" "$2"; shrc=$?
	sd_tail sd_$1.seq > a_$1; sh_tail sh_$1.seq > b_$1
	check "$1: frames identical to spd_dump [$(short b_$1)] rc $sdrc/$shrc" \
		bash -c "[ -s a_$1 ] && diff -q a_$1 b_$1 >/dev/null && [ $sdrc = 0 ] && [ $shrc = 0 ]"
done
# BCB bytes: what each tool left in misc, vs the documented layout and the shipped files.
python3 - "$root/misc" <<'PY' > bcb.txt
import sys
d = sys.argv[1]
b = bytearray(0x800); b[0:13] = b'boot-recovery'
f = bytearray(b); f[0x40:0x40 + 20] = b'recovery\n--fastboot\n'
w = bytearray(b); w[0x40:0x40 + 21] = b'recovery\n--wipe_data\n'
open('bcb_recovery', 'wb').write(b); open('bcb_fastboot', 'wb').write(f)
for n, x in (('recovery', b), ('fastbootd', f), ('wipe', w)):
    print(n, open(f'{d}/misc-{n}.bin', 'rb').read() == bytes(x))
PY
check "shipped misc/*.bin == spd_dump BCB layout (recovery, fastbootd, wipe)" bash -c "! grep -q False bcb.txt"
for k in recovery fastboot; do
	check "reboot-$k: misc[0:0x800] == BCB, rest untouched (spd_dump and spdhost)" bash -c "
		./gen misc 0 1048576 > orig
		for t in sd sh; do f=misc_\${t}_reboot-$k.bin
			cmp -s <(head -c 2048 \$f) bcb_$k || exit 1
			cmp -s <(tail -c +2049 \$f) <(tail -c +2049 orig) || exit 1
		done"
done

# ---- misc guard: backup + verify in one session ----
sh guard_ok parts pt.txt misc-backup before.img reboot-fastboot; rc=$?
./gen misc 0 1048576 > orig
check "guard: backup is 1048576 bytes == misc before the write" cmp -s before.img orig
check "guard: spdhost verified misc read-back, then reset (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'misc-verify: OK' sh_guard_ok.log && tail -1 sh_guard_ok.seq | grep -q '^SEQ 05 '"
MOCK_MISC_DROPWRITE=1 sh guard_bad parts pt.txt misc-backup before2.img reboot-recovery; rc=$?
check "guard: write not stored -> read-back mismatch, NO reset (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'misc read-back mismatch' sh_guard_bad.log && ! grep -q '^SEQ 05 ' sh_guard_bad.seq"
MOCK_FAIL_MID=misc sh guard_fail parts pt.txt misc-backup before3.img reboot-recovery; rc=$?
check "guard: failed backup read -> session stops, no misc write, no reset (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'misc-backup FAILED' sh_guard_fail.log && ! grep -qE '^SEQ (01 len=7[6-9]|02 len=2048|05 )' sh_guard_fail.seq && [ ! -s before3.img ]"
MOCK_FAIL_MID=misc sh guard_fail_kg --keep-going parts pt.txt misc-backup before4.img reboot-recovery; rc=$?
check "guard: --keep-going does not skip past a failed backup (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qE '^SEQ (02 len=2048|05 )' sh_guard_fail_kg.seq"
# restore path: write-part misc FILE with the guard
cp orig restore.img; printf 'X' | dd of=restore.img bs=1 seek=100 conv=notrunc status=none
MOCK_MISC_OUT=$tmp/misc_restore.bin sh restore parts pt.txt misc-backup before5.img write-part misc restore.img reset; rc=$?
check "guard: write-part misc FULL image verified (rc $rc) and stored" \
	bash -c "[ $rc = 0 ] && grep -q 'misc-verify: OK (1048576' sh_restore.log && cmp -s misc_restore.bin restore.img"
check "reset/reboot end the command list (like spd_dump break)" \
	bash -c "MOCK_LOG=x.seq timeout 30 ./sh --usb-fd 7 exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin ${LOAD[*]} reset parts p2.txt 7</dev/null 2>x.log; [ ! -e p2.txt ] && grep -q 'ignored after reset' x.log"

echo "reboot-seq: $pass passed, $fail failed"
(( fail == 0 ))
