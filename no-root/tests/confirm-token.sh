#!/usr/bin/env bash
# spdhost confirm() / --confirm-token on tests/mock_fdl2.c, run the way
# termux-usb -e runs it: stderr goes to a file (termux-usb buffers it until
# exit), stdin is a pipe or a pty (python pty = a Termux terminal).
# Usage (from no-root/): tests/confirm-token.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
gcc -O2 -w -std=c11 -D_GNU_SOURCE -I"$root/tests" "$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" \
	"$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
gcc -O2 -w -I"$root/tests" "$root/tests/gen_expected.c" -o "$tmp/gen_expected" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
# menu set_slot_menu shells out to `spdhost pack-slot`, and resolve_spdhost_bin
# prefers SPDHOST_BIN, so the menu uses the binary built here and not a stale
# ./spdhost from an older `make`.
cp "$tmp/sh" "$tmp/spdhost"
drive=$root/tests/pty_drive.py
cd "$tmp"
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' > pt
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a
REC=$(sha256sum "$root/misc/misc-recovery.bin" | awk '{print $1}')
FB=$(sha256sum "$root/misc/misc-fastbootd.bin" | awk '{print $1}')
WIPE=$(sha256sum "$root/misc/misc-wipe.bin" | awk '{print $1}')
# Command line (no redirections): L = log label, rest = spdhost args.
cl() { local L=$1; shift; printf 'MOCK_LOG=%q/%q.seq MOCK_MISC_OUT=%q/%q.misc timeout --foreground 60 ./sh --usb-fd 7' "$tmp" "$L" "$tmp" "$L"
	while [[ ${1:-} == --* ]]; do printf ' %q' "$1"; shift; [[ ${1:-} =~ ^[0-9a-fA-FX]{3,}$ ]] && { printf ' %q' "$1"; shift; }; done
	printf ' %q' exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00 "$@"; }
# No controlling tty at all (setsid), stdin = pipe with DATA.
nopty() { local L=$1 data=$2; shift 2; printf '%b' "$data" | setsid bash -c "$(cl "$L" "$@") 7</dev/null >$L.out 2>$L.log"; }
# Frames that write: write start/data/end (01 76+ = start with a name, 02, 03) after FDL2 exec, or reset (05).
nowrite() { ! awk '/^SEQ 04 /{on=1; next} on' "$1.seq" | grep -qE '^SEQ (01 len=7[6-9]|02 |03 |05 )'; }
export -f nowrite
G=(parts pt.txt misc-backup)

# 1: pty, cooked (ICRNL): typed "yes\r\n", stderr buffered in a file. Prompt must be ON the pty.
python3 "$drive" t1.pty "type yes" 'yes\r\n' -- "$(cl t1 "${G[@]}" b1.img reboot-recovery) 7</dev/null 2>t1.log"; rc=$?
check "pty cooked: 'yes\\r\\n' accepted, prompt shown on the tty, BCB written+verified (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q \"spdhost: type yes to reboot-recovery via 'misc'\" t1.pty && grep -q 'misc-verify: OK' t1.log && cmp -s <(head -c 2048 t1.misc) '$root/misc/misc-recovery.bin'"
# 2: pty raw (-icrnl): the CR really arrives -> stripped.
python3 "$drive" t2.pty --raw "type yes" 'yes\r\n' -- "$(cl t2 "${G[@]}" b2.img reboot-fastboot) 7</dev/null 2>t2.log"; rc=$?
check "pty raw: literal 'yes\\r\\n' accepted (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'spdhost: confirmed' t2.log && cmp -s <(head -c 2048 t2.misc) '$root/misc/misc-fastbootd.bin'"
# 3: stdin is a pipe (like termux-usb -e) but a tty exists: prompt+answer via /dev/tty.
python3 "$drive" t3.pty "type yes" 'yes \r\n' -- "$(cl t3 "${G[@]}" b3.img reboot-recovery) 7</dev/null </dev/null 2>t3.log"; rc=$?
check "stdin unusable -> /dev/tty prompt + answer 'yes \\r\\n' accepted (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'type yes' t3.pty && grep -q 'misc-verify: OK' t3.log"
# 4: pty EOF (Ctrl-D) / empty line / "no" -> refused, distinct message, no write.
python3 "$drive" t4.pty "type yes" '\x04' -- "$(cl t4 "${G[@]}" b4.img reboot-recovery) 7</dev/null 2>t4.log"; rc=$?
check "pty EOF: 'spdhost: not confirmed (read: EOF)', zero write frames (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'spdhost: not confirmed (read: EOF)' t4.log && nowrite t4"
python3 "$drive" t5.pty --raw "type yes" '\r\n' -- "$(cl t5 "${G[@]}" b5.img reboot-recovery) 7</dev/null 2>t5.log"; rc=$?
check "pty empty line: 'spdhost: not confirmed (read: 0d 0a)', zero write frames (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'spdhost: not confirmed (read: 0d 0a)' t5.log && nowrite t5"
# 5: no tty anywhere, piped "yes" or EOF: refuse (a pipe is not a typed confirm).
nopty t6 'yes\r\n' "${G[@]}" b6.img reboot-recovery; rc=$?
check "no tty, piped yes: 'spdhost: refusing ... without --yes/--confirm-token', no write (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'spdhost: refusing reboot-recovery via .misc. without --yes/--confirm-token' t6.log && nowrite t6"
nopty t7 '' "${G[@]}" b7.img reboot-recovery; rc=$?
check "no tty, EOF: refused, no write (rc $rc)" bash -c "[ $rc != 0 ] && grep -q 'spdhost: refusing' t7.log && nowrite t7"
# 6: tokens. Right token: no prompt at all, no tty needed.
nopty t8 '' --confirm-token "$REC" "${G[@]}" b8.img reboot-recovery; rc=$?
check "right token (recovery): proceeds with no prompt, verified, reset (rc $rc)" \
	bash -c "[ $rc = 0 ] && ! grep -q 'type yes' t8.log && grep -q 'confirm-token matches' t8.log && grep -q 'misc-verify: OK' t8.log && tail -1 t8.seq | grep -q '^SEQ 05 ' && cmp -s <(head -c 2048 t8.misc) '$root/misc/misc-recovery.bin'"
nopty t9 '' --confirm-token="$FB" "${G[@]}" b9.img reboot-fastboot; rc=$?
check "right token (fastbootd, --confirm-token=): proceeds (rc $rc)" bash -c "[ $rc = 0 ] && cmp -s <(head -c 2048 t9.misc) '$root/misc/misc-fastbootd.bin'"
nopty t10 '' --confirm-token "$WIPE" "${G[@]}" b10.img write-part misc "$root/misc/misc-wipe.bin" reset; rc=$?
check "right token (wipe bin): proceeds (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'misc-verify: OK' t10.log && cmp -s <(head -c 2048 t10.misc) '$root/misc/misc-wipe.bin'"
head -c 1048576 /dev/zero | tr '\0' 'R' > restore.img; RS=$(sha256sum restore.img | awk '{print $1}')
nopty t11 '' --confirm-token "$RS" "${G[@]}" b11.img write-part misc restore.img reset; rc=$?
check "right token (restore image 1 MiB): proceeds, misc == image (rc $rc)" bash -c "[ $rc = 0 ] && cmp -s t11.misc restore.img"
# Wrong tokens: recovery token on fastboot, fastboot token on recovery, typo, restore of another file.
nopty t12 '' --confirm-token "$REC" "${G[@]}" b12.img reboot-fastboot; rc=$?
check "wrong token: 'spdhost: confirm-token mismatch (expected $REC, got $FB)', zero write frames (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'spdhost: confirm-token mismatch (expected $REC, got $FB)' t12.log && nowrite t12"
nopty t13 '' --confirm-token "${REC%?}0" "${G[@]}" b13.img reboot-recovery; rc=$?
check "token off by one hex digit: mismatch, zero write frames (rc $rc)" bash -c "[ $rc != 0 ] && grep -q 'confirm-token mismatch' t13.log && nowrite t13"
nopty t14 '' --confirm-token "$WIPE" "${G[@]}" b14.img write-part misc restore.img reset; rc=$?
check "wipe token on another file: mismatch, zero write frames (rc $rc)" bash -c "[ $rc != 0 ] && grep -q 'confirm-token mismatch' t14.log && nowrite t14"
# Scope: token never authorizes a non-misc write, nor a second misc write.
nopty t15 '' --confirm-token "$REC" parts pt.txt write-part boot_a "$root/misc/misc-recovery.bin"; rc=$?
check "token does not authorize write-part boot_a (falls back to confirm -> refused, no write) (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'only authorizes a misc write' t15.log && grep -q 'spdhost: refusing' t15.log && nowrite t15"
nopty t16 '' --confirm-token "$WIPE" "${G[@]}" b16.img write-part misc "$root/misc/misc-wipe.bin" write-part misc "$root/misc/misc-wipe.bin" reset; rc=$?
check "token authorizes ONE misc write per session (second refused, no reset) (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'refusing a second misc write' t16.log && ! grep -q '^SEQ 05 ' t16.seq"
check "bad token syntax rejected before USB" bash -c "! ./sh --usb-fd 7 --confirm-token XYZ reset 7</dev/null 2>t17.log && grep -q 'bad --confirm-token' t17.log"

# 7: menu [2] -> [2] recovery on a pty: typed yes (raw CR) -> --confirm-token, never --yes, no spdhost prompt.
cat > runner <<R
#!/usr/bin/env bash
MOCK_LOG=$tmp/m\${M:-1}.seq MOCK_MISC_OUT=$tmp/m\${M:-1}.misc exec "$tmp/sh" --usb-fd 7 "\$@" 7</dev/null 2>>$tmp/m\${M:-1}.err
R
chmod +x runner
cat > menu_env.sh <<M
export SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=$tmp/runner SPDHOST_MENU_CONFIG=$tmp/none.conf
export SPDHOST_EXEC_ADDR=0x65015f08 SPDHOST_TIMEOUT=1000
export SPDHOST_BIN=$tmp/spdhost TMPDIR=$tmp
source "$root/scripts/menu.sh"
FDL1=$tmp/fdl1-dl.bin FDL1_ADDR=0x65000800 FDL2=$tmp/fdl2-dl.bin FDL2_ADDR=0x9efffe00 DUMP_DIR=$tmp/mdump MISC_DIR=$root/misc
cls() { :; }; pause() { :; }; ready() { :; }
M
python3 "$drive" m1.pty --raw "Choice:" '2\n' "y = continue" 'y\n' "type yes to continue" 'yes\r\n' -- "export M=1; source $tmp/menu_env.sh; reboot_mode"; rc=$?
check "menu [2]: prints BCB sha256 $REC, passes --confirm-token=<it>, never --yes (rc $rc)" \
	bash -c "grep -q 'BCB sha256: $REC' m1.pty && grep '^+ ' m1.pty | grep -q -- '--confirm-token=$REC' && ! grep '^+ ' m1.pty | grep -q -- '--yes'"
check "menu [2]: spdhost never prompted, BCB written, verified, reset" \
	bash -c "! grep -q 'type yes to reboot' m1.pty m1.err && grep -q 'confirm-token matches' m1.err && grep -q 'misc-verify: OK' m1.err && cmp -s <(head -c 2048 m1.misc) '$root/misc/misc-recovery.bin' && tail -1 m1.seq | grep -q '^SEQ 05 '"
python3 "$drive" m2.pty "Choice:" '2\n' "y = continue" 'y\n' "type yes to continue" 'no\n' -- "export M=2; source $tmp/menu_env.sh; reboot_mode"; rc=$?
check "menu [2] typed 'no': 'menu: not confirmed', spdhost not run" bash -c "grep -q 'menu: not confirmed' m2.pty && [ ! -e m2.seq ]"
python3 "$drive" m3.pty "Choice:" '3\n' "y = continue" 'y\n' "type yes to continue" 'yes\n' -- "export M=3; source $tmp/menu_env.sh; reboot_mode"; rc=$?
check "menu [3] fastbootd: token = fastbootd BCB sha, written" bash -c "grep -q -- '--confirm-token=$FB' m3.pty && cmp -s <(head -c 2048 m3.misc) '$root/misc/misc-fastbootd.bin'"
python3 "$drive" m5.pty "Choice:" '5\n' "y = continue" 'y\n' "erase userdata" 'yes\n' -- "export M=5; source $tmp/menu_env.sh; reboot_mode"; rc=$?
check "menu [5] wipe: token = misc-wipe.bin sha, written" bash -c "grep -q -- '--confirm-token=$WIPE' m5.pty && grep -q 'misc-verify: OK' m5.err"
b=$(ls -1t mdump/misc-before-*.img | head -1); BS=$(sha256sum "$b" | awk '{print $1}')
python3 "$drive" m6.pty "Choice:" '6\n' "y = continue" 'y\n' "Restore which" '\n' "type yes to write misc" 'yes\n' -- "export M=6; source $tmp/menu_env.sh; reboot_mode"; rc=$?
check "menu [6] restore: token = backup image sha, misc == backup" bash -c "grep -q -- '--confirm-token=$BS' m6.pty && cmp -s m6.misc '$b'"

# 8: menu [3] -> [2] set the active slot. This used to be the one misc write
# that skipped the token (menu passed spdhost `set-active`, which hashed the
# image only after patching it, so no token could be precomputed). The menu now
# reads misc, builds the image itself and hashes THAT, so the write is guarded
# like every other one. SLOTB is spdhost's set-active slot_b (--self-test pins
# those 32 bytes against spd_dump's).
"$tmp/gen_expected" misc 0 1048576 > misc.raw
TOKB=$(python3 - misc.raw "$tmp" <<'PY'
import hashlib, sys
raw = open(sys.argv[1], "rb").read()
slot = bytes([0x5f,0x62,0,0,0x42,0x43,0x41,0x42,1,2,0,0,0x1e,0,0x6f,0] + [0] * 12 + [0x9e,0xe2,0x10,0x70])
exp = raw[:0x800] + slot + raw[0x820:]
open(sys.argv[2] + "/misc.slotB.exp", "wb").write(exp)
print(hashlib.sha256(exp).hexdigest())
PY
)
python3 "$drive" m8.pty --raw "Choice:" '2\n' "y = continue" 'y\n' "type yes to set the active slot" 'yes\r\n' -- "export M=8; source $tmp/menu_env.sh; set_slot_menu"; rc=$?
check "menu [3]->[2] slot b: token = sha256 of the patched image, write-part misc, no --yes (rc $rc)" \
	bash -c "grep -q 'misc image sha256: $TOKB' m8.pty && grep '^+ ' m8.pty | grep -q -- '--confirm-token=$TOKB' && grep '^+ ' m8.pty | grep -q 'write-part misc' && ! grep '^+ ' m8.pty | grep -q -- '--yes'"
check "menu [3]->[2] slot b: whole misc written byte-for-byte (slot_b at 0x800), read back, reset" \
	bash -c "grep -q 'confirm-token matches' m8.err && grep -q 'misc-verify: OK' m8.err && tail -1 m8.seq | grep -q '^SEQ 05 ' && cmp -s m8.misc misc.slotB.exp"
python3 "$drive" m9.pty --raw "Choice:" '2\n' "y = continue" 'y\n' "type yes to set the active slot" 'no\r\n' -- "export M=9; source $tmp/menu_env.sh; set_slot_menu"; rc=$?
check "menu slot b, typed 'no': 'menu: not confirmed', no token, zero write frames" \
	bash -c "grep -q 'menu: not confirmed' m9.pty && ! grep '^+ ' m9.pty | grep -q -- '--confirm-token' && nowrite m9"

# 9: with a recovery/fastbootd ending the BCB is folded INTO the slot write.
# reboot-recovery would be a second misc write, and one --confirm-token
# authorizes exactly one, so the two are merged into a single image and a single
# session (no re-plug after the reset). Everything below the 2048-byte BCB --
# the slot at 0x800 included -- comes from the live misc.
TOKFB=$(python3 - misc.slotB.exp "$root/misc/misc-fastbootd.bin" "$tmp" <<'PY'
import hashlib, sys
base = open(sys.argv[1], "rb").read()
bcb = open(sys.argv[2], "rb").read()
assert len(bcb) == 2048
exp = bcb + base[2048:]
open(sys.argv[3] + "/misc.slotB.fb.exp", "wb").write(exp)
print(hashlib.sha256(exp).hexdigest())
PY
)
python3 "$drive" m10.pty --raw "Choice:" '2\n' "y = continue" 'y\n' "type yes to set the active slot" 'yes\r\n' -- \
	"export M=10 MOCK_MISC_IN=$tmp/misc.slotB.exp; source $tmp/menu_env.sh; BOOT_AFTER=reboot-fastboot; set_slot_menu"; rc=$?
check "menu slot b + fastbootd ending: BCB folded in, ONE --confirm-token for the merged image (rc $rc)" \
	bash -c "grep -q 'Ending is reboot-fastboot: its 2048-byte BCB is part of this write' m10.pty && grep -q 'misc image sha256: $TOKFB' m10.pty && grep '^+ ' m10.pty | grep -q -- '--confirm-token=$TOKFB' && [ \$(grep -o -- '--confirm-token=[0-9a-f]\{64\}' m10.pty | sort -u | wc -l) = 1 ] && ! grep '^+ ' m10.pty | grep -q -- '--yes'"
check "menu slot b + fastbootd: written misc = BCB at 0, live bytes (slot_b at 0x800) after it, reset" \
	bash -c "cmp -s m10.misc misc.slotB.fb.exp && tail -1 m10.seq | grep -q '^SEQ 05 '"

check "menu: no command line ever has --yes" bash -c "! grep -h '^+ ' m*.pty | grep -q -- '--yes'"
check "menu: guarded_misc_session without a token refuses, spdhost not run" \
	bash -c "export M=7; source $tmp/menu_env.sh; guarded_misc_session reboot-recovery reboot-recovery >m7.out 2>&1; [ \$? != 0 ] && grep -q 'menu: not confirmed' m7.out && [ ! -e m7.seq ]"

echo "confirm-token: $pass passed, $fail failed"
(( fail == 0 ))
