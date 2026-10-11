#!/usr/bin/env bash
# P0-4: `spdhost plan <argv>` + `--confirm-plan SHA` on tests/mock_fdl2.c.
#
# The plan is made offline (no USB), binds the op, partition, slot,
# offset/size, every image's full sha256, the core version, the target (chip
# + loader files) and the sha256 of the partition table the last real `parts`
# saved. The run rebuilds it before USB opens, refuses any difference, and
# consumes the plan's nonce (O_CREAT|O_EXCL in the state dir) before the
# first device write. E3 cases: no op without a valid plan; single use (also
# across processes, and two processes racing); op + image bound; cancel runs
# nothing; expired; future-dated; crash after the nonce was consumed; table
# and target mismatch; image modified after the plan (staged copy and
# fd-stream fallback); multi-step ops with no second prompt; nothing outside
# the plan; no --yes anywhere.
# Usage (from no-root/): tests/confirm-plan.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
cc=${CC:-cc}
srcs=("$root"/src/{main,plan,usb,usb_list,proto,events,dumpcmd,writecmd,sha256,dhtb,pac}.c)
$cc -O2 -w -std=c11 -D_GNU_SOURCE -I"$root/tests" "${srcs[@]}" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
wraps=-Wl,--wrap=libusb_init,--wrap=libusb_init_context,--wrap=libusb_wrap_sys_device,--wrap=libusb_open_device_with_vid_pid
$cc -O1 -w -std=c11 -D_FILE_OFFSET_BITS=64 $(pkg-config --cflags libusb-1.0 2>/dev/null) -o "$tmp/trapped" "${srcs[@]}" \
	"$root/tests/libusb_trap.c" "$wraps" $(pkg-config --libs libusb-1.0 2>/dev/null || echo -lusb-1.0) || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' 'vbmeta_a 1024' 'vbmeta_b 1024' \
	'persist 1024' 'userdata 8192' > pt
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 8192' 'boot_b 4096' 'vbmeta_a 1024' 'vbmeta_b 1024' \
	'persist 1024' 'userdata 8192' > pt2
mkdir -p store
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a MOCK_STORE=$tmp/store SPDHOST_STATE_DIR=$tmp/state MOCK_IMAGES=vbmeta_a
unset SPDHOST_PLAN_NOW SPDHOST_PLAN_TTL SPDHOST_PLAN_STAGE SPDHOST_FRP_PART
L=(exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
head -c 300000 /dev/urandom > boot.img; cp boot.img boot.orig
head -c 200000 /dev/urandom > other.img
# run LABEL [spdhost args]: mock session, no tty at all (setsid, stdin /dev/null).
run() { local l=$1; shift; MOCK_LOG=$tmp/$l.seq MOCK_MISC_OUT=$tmp/$l.misc setsid timeout 60 ./sh --usb-fd 7 "$@" 7</dev/null </dev/null >$l.out 2>$l.log; }
# Write frames after FDL2 exec (START with a name, MIDST, END) or reset.
nowrite() { [[ -f $1.seq ]] || return 0; ! awk '/^SEQ 04 /{on=1; next} on' "$1.seq" | grep -qE '^SEQ (01 len=7[6-9]|01 len=8[0-8]|02 |03 |05 )'; }
nousb() { [[ ! -e $1.seq ]]; }
export -f nowrite nousb
plan() { local l=$1; shift; ./sh plan "$@" >$l.plan 2>$l.perr; }
sha_of() { sed -n 's/^plan-sha256=//p' "$1.plan"; }
C=("${L[@]}" parts pt.txt write-part boot_a boot.img reset)

echo "== table cache, state dir =="
run p0 "${L[@]}" parts pt.txt; rc=$?
check "a real parts session saves the table to the state dir (rc $rc)" \
	bash -c "[ $rc = 0 ] && head -1 state/table-last | grep -qx '# spdhost-table 1 rows 9' && grep -qx 'boot_a 4194304' state/table-last"
check "state dir and its pending/used/staging are 0700, the table 0600" \
	bash -c '[ "$(stat -c %a state state/pending state/used state/staging | sort -u)" = 700 ] && [ "$(stat -c %a state/table-last)" = 600 ]'
./sh --dry-run "${L[@]}" parts dry.txt >/dev/null 2>&1
check "a --dry-run parts does not touch the saved table" grep -qx 'boot_a 4194304' state/table-last

echo "== plan: offline, canonical, stored =="
"$tmp/trapped" plan "${C[@]}" >trap.plan 2>trap.err; rc=$?
check "plan opens no USB (every libusb entry trapped) and exits 0 (rc $rc)" bash -c "[ $rc = 0 ] && ! grep -q TRAP trap.err"
plan a "${C[@]}"; rc=$?
S=$(sha_of a)
check "plan prints spdhost-plan 1 ... end, then plan-sha256=<64 hex> (rc $rc)" \
	bash -c "[ $rc = 0 ] && head -1 a.plan | grep -qx 'spdhost-plan 1' && tail -2 a.plan | head -1 | grep -qx end && [[ '$S' =~ ^[0-9a-f]{64}$ ]]"
check "plan-sha256 is the sha256 of every line before it" \
	bash -c "[ \"\$(sed '\$d' a.plan | sha256sum | cut -c1-64)\" = '$S' ]"
check "the plan binds version, nonce, times, target, table, argv, image sha256, step" bash -c "
	grep -qE '^build_sha=' a.plan && grep -qx protocol=1 a.plan && grep -qE '^nonce=[0-9a-f]{32}$' a.plan &&
	grep -qE '^issued-at=[0-9]+$' a.plan && grep -qE '^expires-at=[0-9]+$' a.plan &&
	grep -qE '^target chip=ums9230 exec=0x65015f08:[0-9a-f]{64} loader1=0x65000800:[0-9a-f]{64} loader2=0x9efffe00:[0-9a-f]{64}$' a.plan &&
	grep -qx \"table-sha256=\$(sha256sum < state/table-last | cut -c1-64)\" a.plan &&
	grep -qx 'arg 12 boot_a' a.plan &&
	grep -qx \"image arg=13 path=boot.img size=300000 sha256=\$(sha256sum < boot.img | cut -c1-64)\" a.plan &&
	grep -qx 'step 1 argi=11 class=yes op=write-part part=boot_a slot=a offset=0 size=300000 data-sha256=- verb=write' a.plan &&
	grep -qx gate=yes a.plan"
check "expiry is 10 minutes by default" bash -c "[ \$(( \$(sed -n 's/^expires-at=//p' a.plan) - \$(sed -n 's/^issued-at=//p' a.plan) )) = 600 ]"
check "the plan is stored as pending/<sha>.plan (0600), byte-identical to stdout" \
	bash -c "cmp -s a.plan state/pending/$S.plan && [ \$(stat -c %a state/pending/$S.plan) = 600 ]"
plan a2 "${C[@]}"
check "two plans of the same argv differ (fresh nonce each)" bash -c "[ '$(sha_of a2)' != '$S' ] && [ -n '$(sha_of a2)' ]"
check "plan with --dry-run, --usb-fd, --verbose in front: same plan body except nonce/times" \
	bash -c "./sh --usb-fd 9 --verbose plan ${C[*]} 2>/dev/null 9</dev/null | grep -vE '^(nonce|issued-at|expires-at|plan-sha256)=' > x.body; grep -vE '^(nonce|issued-at|expires-at|plan-sha256)=' a.plan | cmp -s - x.body"

echo "== plan refusals (offline) =="
./sh --yes plan "${C[@]}" >/dev/null 2>r1.log; r1=$?
./sh --dangerous plan "${C[@]}" >/dev/null 2>r2.log; r2=$?
./sh --confirm-token "$(printf x | sha256sum | cut -c1-64)" plan "${C[@]}" >/dev/null 2>r3.log; r3=$?
check "plan refuses --yes / --dangerous / --confirm-token (exit 2 each)" bash -c "[ $r1$r2$r3 = 222 ] && grep -q 'cannot be combined' r1.log"
plan r4 "${L[@]}" write-part boot_a boot.img parts reset; rc=$?
check "plan refuses a gate before parts (rc $rc)" bash -c "[ $rc = 1 ] && grep -q '\`parts\` must come before the first gated step' r4.perr"
plan r5 "${L[@]}" parts pt.txt read-part boot_a 0 4096 b.bin reset; rc=$?
check "plan refuses commands that reach no gate (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'reach no confirm gate' r5.perr"
plan r6 "${L[@]}" parts pt.txt wof misc 0 boot.img; rc=$?
check "plan refuses wof misc (device-derived bytes) (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'wof misc is not plannable' r6.perr"
plan r7 "${L[@]}" parts pt.txt write-part boot_a missing.img; rc=$?
check "plan refuses an image it cannot read (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'cannot read missing.img' r7.perr"
SPDHOST_STATE_DIR=$tmp/empty ./sh plan "${C[@]}" >/dev/null 2>r8.log; rc=$?
check "plan refuses without a saved table (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'no saved partition table' r8.log"
plan r9 "${L[@]}" parts pt.txt frobnicate; rc=$?
check "plan refuses an unknown command (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'unknown or unplannable command: frobnicate' r9.perr"

echo "== execute =="
run x1 --confirm-plan "$S" "${C[@]}"; rc=$?
check "confirm-plan run: no tty, no --yes, no prompt; step authorized; written; reset (rc $rc)" bash -c "
	[ $rc = 0 ] && ! grep -q 'type yes' x1.log && grep -q 'nonce consumed (single use)' x1.log &&
	grep -q \"confirm-plan: step 1 authorized: write 'boot_a'\" x1.log && cmp -s store/boot_a boot.orig &&
	tail -1 x1.seq | grep -q '^SEQ 05 '"
check "the write streamed from the private staged copy, hashed while sent" \
	bash -c "grep -q 'write boot_a: 300000 bytes from $tmp/state/staging/' x1.log && grep -q 'the 300000 bytes sent hash to the planned sha256' x1.log"
check "boot read back after the write and matched" grep -q 'read-back of boot_a matches (300000 bytes' x1.log
N=$(sed -n 's/^nonce=//p' a.plan)
check "nonce marker used/<nonce> (0600) exists; pending plan removed; staging cleaned" \
	bash -c "[ -f state/used/$N ] && [ \$(stat -c %a state/used/$N) = 600 ] && [ ! -e state/pending/$S.plan ] && [ -z \"\$(ls state/staging)\" ]"
run x2 --confirm-plan "$S" "${C[@]}"; rc=$?
check "replay in a new process: refused before USB (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'no pending plan' x2.log && nousb x2"
cp a.plan state/pending/$S.plan; chmod 600 state/pending/$S.plan
run x3 --confirm-plan "$S" "${C[@]}"; rc=$?
check "replay with the plan record put back: the used nonce still refuses, before USB (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -q 'nonce was already used' x3.log && nousb x3"
rm -f state/pending/$S.plan
run x4 --confirm-plan "$(printf nope | sha256sum | cut -c1-64)" "${C[@]}"; rc=$?
check "no op without a valid plan: unknown sha refused before USB (rc $rc)" bash -c "[ $rc = 1 ] && nousb x4"
./sh --usb-fd 7 --confirm-plan XYZ "${C[@]}" 7</dev/null 2>x5.log; rc=$?
check "malformed --confirm-plan is a usage error (exit 2)" bash -c "[ $rc = 2 ] && grep -q 'bad --confirm-plan' x5.log"
plan b "${C[@]}"; SB=$(sha_of b)
run x6 --yes --confirm-plan "$SB" "${C[@]}"; r6=$?
run x7 --dangerous --confirm-plan "$SB" "${C[@]}"; r7=$?
run x8 --dry-run --confirm-plan "$SB" "${C[@]}"; r8=$?
check "--confirm-plan with --yes / --dangerous / --dry-run: usage error, nothing run" \
	bash -c "[ $r6$r7$r8 = 222 ] && nousb x6 && nousb x7 && [ -f state/pending/$SB.plan ]"
CB=("${L[@]}" parts pt.txt write-part boot_b boot.img reset)
run x9 --confirm-plan "$SB" "${CB[@]}"; rc=$?
check "op-bound: the plan for boot_a does not run write-part boot_b; refused before USB, diff shown (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -q 'is not the confirmed plan' x9.log && grep -q 'now:     arg 12 boot_b' x9.log && nousb x9"
run x10 --confirm-plan "$SB" "${C[@]}" power-off; rc=$?
check "anything outside the plan (an extra command): refused before USB (rc $rc)" bash -c "[ $rc = 1 ] && nousb x10"
check "a refused mismatch does not consume the nonce (the plan is still pending)" test -f "state/pending/$SB.plan"
printf X | dd of=boot.img bs=1 seek=100 conv=notrunc 2>/dev/null
run x11 --confirm-plan "$SB" "${C[@]}"; rc=$?
check "image modified after the plan: refused before USB, the image line differs (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -q 'planned: image arg=13 path=boot.img size=300000' x11.log && nousb x11"
cp boot.orig boot.img
check "cancel: a plan that is never confirmed runs nothing (pending only, no session)" \
	bash -c "[ -f state/pending/$SB.plan ] && [ ! -e b.seq ]"

echo "== time =="
now=$(date +%s)
SPDHOST_PLAN_NOW=$((now - 700)) ./sh plan "${C[@]}" > e.plan 2>/dev/null
run t1 --confirm-plan "$(sha_of e)" "${C[@]}"; rc=$?
check "expired plan (issued 700 s ago, 600 s TTL): refused before USB (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -qE 'the plan expired|no pending plan' t1.log && nousb t1"
SPDHOST_PLAN_NOW=$((now + 3600)) ./sh plan "${C[@]}" > f.plan 2>/dev/null
run t2 --confirm-plan "$(sha_of f)" "${C[@]}"; rc=$?
check "future-dated plan: refused before USB (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'future-dated' t2.log && nousb t2"
SPDHOST_PLAN_TTL=1 ./sh plan "${C[@]}" > g.plan 2>/dev/null; sleep 2
run t3 --confirm-plan "$(sha_of g)" "${C[@]}"; rc=$?
check "SPDHOST_PLAN_TTL=1, run 2 s later: expired (rc $rc)" bash -c "[ $rc = 1 ] && nousb t3"
SPDHOST_PLAN_TTL=99999 ./sh plan "${C[@]}" > h.plan 2>h.err
check "SPDHOST_PLAN_TTL can only shorten (99999 ignored, 600 used)" \
	bash -c "grep -q 'ignored' h.err && [ \$(( \$(sed -n 's/^expires-at=//p' h.plan) - \$(sed -n 's/^issued-at=//p' h.plan) )) = 600 ]"
check "expired pending plans are pruned on the next plan/run" bash -c "[ ! -e state/pending/$(sha_of e).plan ] && [ ! -e state/pending/$(sha_of g).plan ]"
mkdir -p state/staging/deadbeef && : > state/staging/deadbeef/.lock && : > state/staging/deadbeef/junk.img
./sh plan "${C[@]}" > /dev/null 2>&1
check "a staging dir no run holds (crashed run) is pruned" test ! -e state/staging/deadbeef

echo "== race, crash =="
plan r "${C[@]}"; SR=$(sha_of r)
for k in 1 2 3 4; do run race$k --confirm-plan "$SR" "${C[@]}" & done; wait
wins=0; for k in 1 2 3 4; do grep -q 'nonce consumed' race$k.log && wins=$((wins + 1)); done
sent=0; for k in 1 2 3 4; do [[ -e race$k.seq ]] && sent=$((sent + 1)); done
check "four processes race one plan: exactly one consumes it and opens USB ($wins won, $sent opened USB)" \
	bash -c "[ $wins = 1 ] && [ $sent = 1 ]"
plan k "${C[@]}"; SK=$(sha_of k); NK=$(sed -n 's/^nonce=//p' k.plan)
( MOCK_ON_WRITE='boot_a:kill -9 $PPID' run k1 --confirm-plan "$SK" "${C[@]}" ) 2>/dev/null; rc=$?
check "crash mid-write (SIGKILL at START_DATA): the nonce was already consumed (rc $rc)" \
	bash -c "[ $rc != 0 ] && [ -f state/used/$NK ] && ! grep -q 'reset: acknowledged' k1.log"
run k2 --confirm-plan "$SK" "${C[@]}"; rc=$?
check "after the crash the plan cannot be replayed (rc $rc)" bash -c "[ $rc = 1 ] && nousb k2"

echo "== table / target mismatch =="
plan m "${C[@]}"; SM=$(sha_of m)
MOCK_PTABLE=$tmp/pt2 run m1 --confirm-plan "$SM" "${C[@]}"; rc=$?
check "another phone (live table differs): refused at the first gate, zero write frames (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -q 'the live partition table (sha256 [0-9a-f]*) is not the one the plan was made against' m1.log && nowrite m1"
run m0 "${L[@]}" parts pt.txt >/dev/null 2>&1
plan m2p "${C[@]}"; SM2=$(sha_of m2p)
MOCK_PTABLE=$tmp/pt2 run m2s "${L[@]}" parts pt.txt
run m2 --confirm-plan "$SM2" "${C[@]}"; rc=$?
check "a different table saved since the plan (another phone's parts): refused before USB (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -q 'planned: table-sha256=' m2.log && nousb m2"
run m3s "${L[@]}" parts pt.txt
plan m3p "${C[@]}"; SM3=$(sha_of m3p)
cp fdl2-dl.bin fdl2.orig; printf Z >> fdl2-dl.bin
run m3 --confirm-plan "$SM3" "${C[@]}"; rc=$?
check "a different loader file (target identity): refused before USB (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -q 'planned: target chip=ums9230' m3.log && nousb m3"
cp fdl2.orig fdl2-dl.bin
run m4 --confirm-plan "$SM3" "${C[@]}"; rc=$?
check "same plan with the loader restored still runs (the refusal did not consume it) (rc $rc)" test "$rc" = 0

echo "== image integrity: staged copy vs fd stream =="
MOD='boot_a:printf QQQQ | dd of='$tmp'/boot.img bs=1 seek=4096 conv=notrunc 2>/dev/null'
plan s1 "${C[@]}"
MOCK_ON_WRITE=$MOD run s1 --confirm-plan "$(sha_of s1)" "${C[@]}"; rc=$?
check "staged: the original changed mid-write; the staged copy (the planned bytes) was written, run ok (rc $rc)" \
	bash -c "[ $rc = 0 ] && cmp -s store/boot_a boot.orig && ! cmp -s boot.img boot.orig && grep -q 'image.* staged' s1.log"
cp boot.orig boot.img
plan s2 "${C[@]}"
SPDHOST_PLAN_STAGE=stream run s2 --confirm-plan "$(sha_of s2)" "${C[@]}"; rc=$?
check "fd stream (no staging space): unchanged image written from the held fd, verified, reset (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q '0 images staged, 1 streamed' s2.log && grep -q 'write boot_a: 300000 bytes from boot.img' s2.log && cmp -s store/boot_a boot.orig && tail -1 s2.seq | grep -q '^SEQ 05 '"
plan s3 "${C[@]}"
SPDHOST_PLAN_STAGE=stream MOCK_ON_WRITE=$MOD run s3 --confirm-plan "$(sha_of s3)" "${C[@]}"; rc=$?
check "fd stream, image changed mid-write: SUSPECT reported, stopped before the session end (no reset frame) (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -q 'confirm-plan: SUSPECT boot_a: the bytes sent' s3.log && ! grep -q '^SEQ 05 ' s3.seq"
cp boot.orig boot.img
plan s4 "${C[@]}"
MOCK_STORE_FLIP=boot_a run s4 --confirm-plan "$(sha_of s4)" "${C[@]}"; rc=$?
check "post-write read-back differs: SUSPECT, stopped before the reset (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -q 'SUSPECT boot_a: read-back sha256' s4.log && ! grep -q '^SEQ 05 ' s4.seq"

echo "== multi-step ops, one plan, no second prompt =="
plan u1 "${L[@]}" parts pt.txt misc-backup mb.img reboot-recovery
run u1 --confirm-plan "$(sha_of u1)" "${L[@]}" parts pt.txt misc-backup mb.img reboot-recovery; rc=$?
check "reboot-recovery: backup -> BCB write -> verify -> reset under one plan, BCB bytes bound (rc $rc)" bash -c "
	[ $rc = 0 ] && grep -q \"data-sha256=\$(sha256sum < '$root/misc/misc-recovery.bin' | cut -c1-64) verb=reboot-recovery%20via\" u1.plan &&
	grep -q 'misc-verify: OK' u1.log && cmp -s <(head -c 2048 u1.misc) '$root/misc/misc-recovery.bin' && tail -1 u1.seq | grep -q '^SEQ 05 ' && ! grep -q 'type yes' u1.log"
TOKFB=$(printf 'spdhost-set-active b %s\n' "$(sha256sum < "$root/misc/misc-fastbootd.bin" | cut -c1-64)" | sha256sum | cut -c1-64)
plan u2 "${L[@]}" parts pt.txt set-active b --bcb fastboot
run u2 --confirm-plan "$(sha_of u2)" "${L[@]}" parts pt.txt set-active b --bcb fastboot; rc=$?
check "set-active b --bcb fastboot: the patch line is bound; misc RMW + verify + reset, one plan (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'data-sha256=$TOKFB verb=set-active' u2.plan && grep -q 'misc-verify: OK' u2.log && tail -1 u2.seq | grep -q '^SEQ 05 '"
mkdir -p rdir; head -c 100000 /dev/urandom > rdir/boot_a.img; head -c 50000 /dev/urandom > rdir/uboot_a.img
: > rdir/notes.txt; head -c 10 /dev/urandom > rdir/misc-before-1.img
plan u3 "${L[@]}" parts pt.txt write-parts rdir reset
check "write-parts DIR binds exactly the images it may pick (2 of 4 files)" bash -c "grep -qx 'dir arg=12 path=rdir images=2' u3.plan && [ \$(grep -c '^image arg=12 file=' u3.plan) = 2 ]"
run u3 --confirm-plan "$(sha_of u3)" "${L[@]}" parts pt.txt write-parts rdir reset; rc=$?
check "write-parts: every image written from staging, boot read back, slot logic unchanged, reset (rc $rc)" \
	bash -c "[ $rc = 0 ] && cmp -s store/boot_a rdir/boot_a.img && cmp -s store/uboot_a rdir/uboot_a.img && grep -q 'read-back of boot_a matches' u3.log && tail -1 u3.seq | grep -q '^SEQ 05 '"
plan u4 "${L[@]}" parts pt.txt write-parts rdir reset
head -c 100 /dev/urandom > rdir/boot_b.img
run u4 --confirm-plan "$(sha_of u4)" "${L[@]}" parts pt.txt write-parts rdir reset; rc=$?
check "write-parts: a new image in DIR after the plan: refused before USB (rc $rc)" bash -c "[ $rc = 1 ] && nousb u4"
rm -f rdir/boot_b.img
{ printf 'AVB0\0\0\0\0'; head -c 4088 /dev/urandom; } > vb.img  # mock reads of vbmeta_a carry the AVB0 magic
plan u5 "${L[@]}" parts pt.txt write-part vbmeta_a vb.img verity 0 reset
check "a plan with verity is gate=dangerous (the highest class wins)" \
	bash -c "grep -qx gate=dangerous u5.plan && grep -q 'class=dangerous op=verity-disable' u5.plan && grep -q 'class=yes op=write-part part=vbmeta_a' u5.plan"
run u5 --confirm-plan "$(sha_of u5)" "${L[@]}" parts pt.txt write-part vbmeta_a vb.img verity 0 reset; rc=$?
check "write vbmeta (read back) then verity 0 (dangerous) in one run, no typed word, no --dangerous (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'read-back of vbmeta_a matches' u5.log && grep -q \"step 2 authorized: disable verity (vbmeta byte 0x7b) 'disable verity (vbmeta byte 0x7b)' (dangerous)\" u5.log && ! grep -q 'type dangerous' u5.log && tail -1 u5.seq | grep -q '^SEQ 05 '"
plan u6 "${L[@]}" parts pt.txt read-part userdata 0 4096 u.bin reset
run u6 --confirm-plan "$(sha_of u6)" "${L[@]}" parts pt.txt read-part userdata 0 4096 u.bin reset; rc=$?
check "confirmed read (read-part userdata) under a plan: no prompt, read done (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q \"authorized: read 'userdata'\" u6.log && [ \$(stat -c %s u.bin) = 4096 ]"
plan u7 "${L[@]}" parts pt.txt erase-part boot_b erase_flash 0x1000 0x1000 reset
run u7 --confirm-plan "$(sha_of u7)" "${L[@]}" parts pt.txt erase-part boot_b erase_flash 0x1000 0x1000 reset; rc=$?
check "erase-part + erase_flash: two steps, each taken once (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q \"step 1 authorized: erase 'boot_b'\" u7.log && grep -q \"step 2 authorized: erase flash at '0x1000'\" u7.log"
plan u8 "${L[@]}" parts pt.txt danger-erase persist
SPDHOST_FRP_PART=persist ./sh plan "${L[@]}" parts pt.txt frp-reset frp.bak > u8b.plan 2>/dev/null
check "danger-erase / frp-reset plans are dangerous; frp-reset binds SPDHOST_FRP_PART" \
	bash -c "grep -qx gate=dangerous u8.plan && grep -qx 'env SPDHOST_FRP_PART=persist' u8b.plan"
run u8 --confirm-plan "$(sha_of u8)" "${L[@]}" parts pt.txt danger-erase persist; rc=$?
check "danger-erase persist under its plan: no typed word (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'DANGEROUS erase: persist' u8.log && ! grep -q 'type dangerous' u8.log"
run u9 --confirm-plan "$(sha_of u8b)" "${L[@]}" parts pt.txt frp-reset frp.bak; rc=$?
check "frp-reset plan made with SPDHOST_FRP_PART=persist does not run without it (rc $rc)" bash -c "[ $rc = 1 ] && nousb u9"

echo "== P0-4b: unsuffixed names on an A/B table need the suffix =="
np=$(ls state/pending | wc -l)
plan ab1 "${L[@]}" parts pt.txt write-part boot boot.img reset; rc=$?
check "A/B table (boot_a + boot_b): plan write-part boot exits 1, asks for the suffix, stores nothing (rc $rc)" \
	bash -c "[ $rc = 1 ] && grep -q \"plan: 'boot' is an A/B pair on the saved table (boot_a and boot_b): use boot_a or boot_b on this A/B table; nothing stored\" ab1.perr && ! grep -q plan-sha256 ab1.plan && [ \$(ls state/pending | wc -l) = $np ]"
plan ab2 "${L[@]}" parts pt.txt erase-part vbmeta; r2=$?
plan ab3 "${L[@]}" parts pt.txt read-part userdata 0 4096 u.bin write-part-plain boot boot.img; r3=$?
check "same refusal for erase-part vbmeta and for an unsuffixed write after another step (rc $r2 $r3)" \
	bash -c "[ $r2$r3 = 11 ] && grep -q \"'vbmeta' is an A/B pair\" ab2.perr && grep -q \"'boot' is an A/B pair\" ab3.perr"
plan ab4 "${L[@]}" parts pt.txt write-part boot_a boot.img reset; rc=$?
check "write-part boot_a still plans, slot=a; argv is not rewritten (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'op=write-part part=boot_a slot=a ' ab4.plan && grep -qx 'arg 12 boot_a' ab4.plan"
printf '%s\n' 'misc 1024' 'boot 4096' 'recovery_a 1024' 'vbmeta 1024' 'userdata 8192' > ptn
(export MOCK_PTABLE=$tmp/ptn MOCK_SLOT= SPDHOST_STATE_DIR=$tmp/stn MOCK_IMAGES=vbmeta
 run n0 "${L[@]}" parts pt.txt
 plan n1 "${L[@]}" parts pt.txt write-part boot boot.img reset
 plan n2 "${L[@]}" parts pt.txt write-part recovery boot.img
 run n1 --confirm-plan "$(sha_of n1)" "${L[@]}" parts pt.txt write-part boot boot.img reset; echo $? > n1.rc)
check "non-A/B table (only boot): plan write-part boot keeps slot=active" \
	bash -c "grep -q 'op=write-part part=boot slot=active ' n1.plan"
check "one twin only (recovery_a, no recovery_b): unsuffixed recovery still plans with slot=active" \
	grep -q 'op=write-part part=recovery slot=active ' n2.plan
check "non-A/B: the slot=active plan runs and writes boot (rc $(cat n1.rc))" \
	bash -c "[ \$(cat n1.rc) = 0 ] && grep -q \"step 1 authorized: write 'boot'\" n1.log && cmp -s store/boot boot.orig"
(export MOCK_PTABLE=$tmp/ptn MOCK_SLOT= SPDHOST_STATE_DIR=$tmp/stn MOCK_IMAGES=vbmeta
 plan n3 "${L[@]}" parts pt.txt write-part boot boot.img reset)
SN3=$(sha_of n3)
cp state/table-last stn/table-last
(export SPDHOST_STATE_DIR=$tmp/stn
 run n3 --confirm-plan "$SN3" "${L[@]}" parts pt.txt write-part boot boot.img reset; echo $? > n3.rc)
check "stale pending plan with unsuffixed boot, table now A/B: execute refused before USB, nonce not consumed (rc $(cat n3.rc))" \
	bash -c "[ \$(cat n3.rc) = 1 ] && grep -q \"confirm-plan: refusing 'boot': this A/B table has both boot_a and boot_b\" n3.log && nousb n3 && [ -f stn/pending/$SN3.plan ] && [ ! -e stn/used/$(sed -n "s/^nonce=//p" n3.plan) ]"

echo "== CLI default unchanged, no --yes path, caps =="
run d1 "${L[@]}" parts pt.txt write-part boot_a boot.img reset; rc=$?
check "without --confirm-plan and no tty: still the typed-confirm refusal, nothing written (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q \"spdhost: refusing write 'boot_a' without --yes/--confirm-token\" d1.log && nowrite d1"
check "the plan code never sets --yes or --dangerous (no assignment to yes/dangerous_ok under plan_mode)" \
	bash -c "! sed -n '/---- P0-4 confirm-plan/,/^static int spdhost_main(int argc, char \*\*argv);/p' '$root/src/main.c' | grep -qE '(^|[^_])yes = 1|dangerous_ok = 1'"
check "caps lists cap=confirm-plan" bash -c "./sh caps | grep -qx cap=confirm-plan"
check "--help documents plan and --confirm-plan" bash -c "./sh --help 2>&1 | grep -q -- '--confirm-plan SHA' && ./sh --help 2>&1 | grep -q '^  plan '"
(unset SPDHOST_STATE_DIR; export HOME=$tmp/home XDG_STATE_HOME=; mkdir -p "$HOME"; ./sh plan "${C[@]}" >/dev/null 2>hs.log; true)
check "default state dir is \$HOME/.local/state/spdhost (0700) when SPDHOST_STATE_DIR is unset" \
	bash -c "[ \$(stat -c %a home/.local/state/spdhost) = 700 ] && [ -d home/.local/state/spdhost/pending ]"
(unset SPDHOST_STATE_DIR; export HOME=$tmp/home XDG_STATE_HOME=$tmp/xdg; ./sh plan "${C[@]}" >/dev/null 2>&1; true)
check "XDG_STATE_HOME/spdhost is used when set" test -d xdg/spdhost/pending
mkdir -p open && chmod 777 open
SPDHOST_STATE_DIR=$tmp/open ./sh plan "${C[@]}" >/dev/null 2>o.log; rc=$?
check "a group/world-writable state dir is refused (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'not a directory owned by this user' o.log"

echo "confirm-plan: $pass passed, $fail failed"
(( fail == 0 ))
