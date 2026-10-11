#!/usr/bin/env bash
# P0-8: `ops misc-reboot recovery|fastboot DIR` and `ops set-active a|b DIR`
# on tests/mock_fdl2.c. One session, one misc write: backup into
# DIR/meta/misc-before-<time>.img (read back), recorded in meta/SHA256SUMS
# before the write, then the BCB / slot block, whole misc written and read
# back, then the ending. Keep/delete matrix (A4, audit6 C10), --expect,
# misc-verify vs reset reported apart, the set-active token binding, the
# confirm-plan step, no --yes, and menu.sh's switch + bash fallback.
# Usage (from no-root/): tests/ops-misc.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
cc=${CC:-cc}
srcs=("$root"/src/{main,plan,loaders,ops,usb,usb_list,proto,events,dumpcmd,writecmd,sha256,dhtb,pac}.c)
$cc -O2 -w -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I"$root/tests" "${srcs[@]}" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' 'vbmeta_a 1024' 'vbmeta_b 1024' > pt
printf '%s\n' 'misc 1024' 'uboot 1024' 'boot 4096' 'vbmeta 1024' > ptn
printf '%s\n' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' > ptm
head -c 1048576 /dev/urandom > misc.in
MISC_SHA=$(sha256sum < misc.in | cut -c1-64)
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a MOCK_MISC_IN=$tmp/misc.in SPDHOST_STATE_DIR=$tmp/state
unset SPDHOST_PART_XML_DIR SPDHOST_PLAN_NOW SPDHOST_PLAN_TTL SPDHOST_PLAN_STAGE
L=(exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
REC=$(sha256sum < "$root/misc/misc-recovery.bin" | cut -c1-64)
FB=$(sha256sum < "$root/misc/misc-fastbootd.bin" | cut -c1-64)
WIPE=$(sha256sum < "$root/misc/misc-wipe.bin" | cut -c1-64)
tok_sa() { printf 'spdhost-set-active %s %s\n' "$1" "$2" | sha256sum | cut -c1-64; }
TOKB=$(tok_sa b none) TOKA=$(tok_sa a none) TOKBR=$(tok_sa b "$REC")
# run LABEL [spdhost args]: mock session, no tty (setsid, stdin /dev/null);
# status file LABEL.st, events LABEL.ev, misc after the run LABEL.misc.
run() { local l=$1; shift; SPDHOST_STATUS_FILE=$tmp/$l.st MOCK_LOG=$tmp/$l.seq MOCK_MISC_OUT=$tmp/$l.misc \
	setsid timeout 60 ./sh --usb-fd 7 --events "$tmp/$l.ev" "$@" 7</dev/null </dev/null >$l.out 2>$l.log; }
# Write frames after FDL2 exec (START with a name, MIDST, END) or reset/power-off.
nowrite() { [[ -f $1.seq ]] || return 0; ! awk '/^SEQ 04 /{on=1; next} on' "$1.seq" | grep -qE '^SEQ (01 len=7[6-9]|01 len=8[0-8]|02 |03 |05 |17 )'; }
nreset() { grep -cE '^SEQ (05|17) ' "$1.seq"; }
st() { awk -F= -v k="$2" '$1 == k { v = $2 } END { print v }' "$1.st"; }
opev() { grep '"ev":"op"' "$1.ev" | tail -1; }
backups() { ls "$1"/meta/misc-before-*.img 2>/dev/null | wc -l; }
sums_ok() { (cd "$1" && sha256sum -c --quiet meta/SHA256SUMS); }
export -f nowrite opev st backups

echo "== usage (exit 2, nothing sent) =="
for a in "misc-reboot" "misc-reboot boot d" "misc-reboot recovery" "set-active c d" "set-active a" \
	"set-active a d --bcb x" "set-active a d --ending halt" "set-active a d --bcb recovery --ending power-off" \
	"misc-reboot recovery d --expect abc" "misc-reboot recovery d --bcb fastboot"; do
	./sh --dry-run ops $a >/dev/null 2>u.err; rc=$?
	check "ops $a: usage error, exit 2 (rc $rc)" test "$rc" = 2
done
check "the usage error names the misc ops" bash -c './sh --dry-run ops frob 2>&1 | grep -q "ops misc-reboot recovery|fastboot DIR"'
run y1 --yes "${L[@]}" parts pt.txt ops misc-reboot recovery d_y1; rc=$?
check "--yes is refused for a misc op (exit 2), nothing written, no backup (rc $rc)" \
	bash -c "[ $rc = 2 ] && grep -q 'refusing --yes' y1.log && nowrite y1 && [ ! -e d_y1/meta ]"

echo "== misc-reboot recovery, --confirm-token =="
run r1 --confirm-token "$REC" "${L[@]}" parts pt.txt ops misc-reboot recovery d_r1; rc=$?
b=$(ls d_r1/meta/misc-before-*.img 2>/dev/null | head -1)
check "rc 0, one backup at DIR/meta/misc-before-<time>.img (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ $(backups d_r1) = 1 ] && [[ '$b' =~ /meta/misc-before-[0-9]{8}-[0-9]{6}\.img$ ]]"
check "the backup is the misc as it was (byte-identical to the phone's misc before the write)" cmp -s "$b" misc.in
check "meta/SHA256SUMS records it relative to DIR and verifies" \
	bash -c "grep -qx '$MISC_SHA  meta/$(basename "$b")' d_r1/meta/SHA256SUMS && (cd d_r1 && sha256sum -c --quiet meta/SHA256SUMS)"
check "misc now = recovery BCB at 0, the rest as read (one RMW write)" \
	bash -c "cmp -s <(head -c 2048 r1.misc) '$root/misc/misc-recovery.bin' && cmp -s <(tail -c +2049 r1.misc) <(tail -c +2049 misc.in)"
check "exactly one misc write in the session, then one reset" \
	bash -c "[ \$(grep -c '^write misc:' r1.log) = 1 ] && [ $(nreset r1) = 1 ] && tail -1 r1.seq | grep -q '^SEQ 05 '"
check "status file: misc-backup (relative), misc-bytes, sha256, kept, misc-verify=ok, reset=ack" \
	bash -c "[ '$(st r1 misc-backup)' = 'meta/$(basename "$b")' ] && [ '$(st r1 misc-bytes)' = 1048576 ] && [ '$(st r1 misc-backup-sha256)' = $MISC_SHA ] && [ '$(st r1 misc-backup-state)' = kept ] && [ '$(st r1 misc-verify)' = ok ] && [ '$(st r1 reset)' = ack ]"
check "status order: backup recorded before the write's misc-verify" \
	bash -c "awk -F= '{print \$1}' r1.st | tr '\n' ' ' | grep -q 'misc-backup .*misc-backup-state .*misc-verify .*reset'"
check "events: misc-backup (file, bytes, sha256) and op ok with misc_verify + ending apart" \
	bash -c "grep '\"ev\":\"misc-backup\"' r1.ev | grep -q '\"bytes\":1048576,\"sha256\":\"$MISC_SHA\"' && opev r1 | grep -q '\"op\":\"misc-reboot\",\"target\":\"recovery\",\"state\":\"ok\",\"misc_verify\":\"ok\",\"ending\":\"ack\",.*\"backup_state\":\"kept\"'"
check "the restore line names the kept backup" grep -q "restore (typed confirm): write-part misc d_r1/meta/misc-before-" r1.log

run r2 --confirm-token "$FB" "${L[@]}" parts pt.txt ops misc-reboot fastboot d_r1; rc=$?
check "misc-reboot fastboot: fastbootd BCB, rc 0, a SECOND backup beside the first (never overwritten) (rc $rc)" \
	bash -c "[ $rc = 0 ] && cmp -s <(head -c 2048 r2.misc) '$root/misc/misc-fastbootd.bin' && [ $(backups d_r1) = 2 ] && cmp -s '$b' misc.in && [ \$(wc -l < d_r1/meta/SHA256SUMS) = 2 ] && (cd d_r1 && sha256sum -c --quiet meta/SHA256SUMS)"
run r3 --confirm-token "$REC" "${L[@]}" parts pt.txt ops misc-reboot recovery d_r3 reset; rc=$?
check "the session ends at the op's reset: a trailing reset is not run (rc $rc)" bash -c "[ $rc = 0 ] && [ $(nreset r3) = 1 ]"
run r4 --confirm-token "$FB" "${L[@]}" parts pt.txt ops misc-reboot recovery d_r4; rc=$?
check "a token for the other BCB is refused: nothing written, the backup is KEPT and recorded (rc $rc)" \
	bash -c "[ $rc != 0 ] && nowrite r4 && [ $(backups d_r4) = 1 ] && (cd d_r4 && sha256sum -c --quiet meta/SHA256SUMS) && [ '$(st r4 misc-backup-state)' = kept ]"
run r5 "${L[@]}" parts pt.txt ops misc-reboot recovery d_r5; rc=$?
check "no token, no tty: the typed confirm refuses; nothing written; backup kept (rc $rc)" \
	bash -c "[ $rc != 0 ] && nowrite r5 && [ $(backups d_r5) = 1 ] && grep -q 'refusing reboot-recovery via' r5.log"
MOCK_PTABLE=$tmp/ptm run r6 --confirm-token "$REC" "${L[@]}" parts pt.txt ops misc-reboot recovery d_r6; rc=$?
check "no misc row in the live table: refused before any read; no backup, nothing written (rc $rc)" \
	bash -c "[ $rc != 0 ] && nowrite r6 && [ ! -e d_r6/meta ] && grep -q 'run parts first' r6.log && opev r6 | grep -q '\"why\":\"no-table\"'"

echo "== keep/delete matrix (A4, C10) =="
MOCK_FAIL_MID=misc run k1 --confirm-token "$REC" "${L[@]}" parts pt.txt ops misc-reboot recovery d_k1; rc=$?
check "backup read fails: write NOT reached, no backup file left, not in SHA256SUMS, state=removed (rc $rc)" \
	bash -c "[ $rc != 0 ] && nowrite k1 && [ $(backups d_k1) = 0 ] && [ ! -s d_k1/meta/SHA256SUMS ] && [ '$(st k1 misc-backup-state)' = removed ] && [ -z '$(st k1 misc-verify)' ] && opev k1 | grep -q '\"why\":\"backup\",.*\"backup_state\":\"removed\"'"
MOCK_MISC_DROPWRITE=1 run k2 --confirm-token "$REC" "${L[@]}" parts pt.txt ops misc-reboot recovery d_k2; rc=$?
check "write reached, read-back mismatch: misc-verify=failed, NO reset, backup KEPT + recorded (rc $rc)" \
	bash -c "[ $rc != 0 ] && [ '$(st k2 misc-verify)' = failed ] && [ $(nreset k2) = 0 ] && [ $(backups d_k2) = 1 ] && (cd d_k2 && sha256sum -c --quiet meta/SHA256SUMS) && opev k2 | grep -q '\"state\":\"failed\",\"misc_verify\":\"failed\",\"ending\":\"not-run\"'"
MOCK_RESET_SILENT=1 run k3 --confirm-token "$REC" "${L[@]}" parts pt.txt ops misc-reboot recovery d_k3; rc=$?
check "verify OK + reset ack lost: misc-verify=ok and reset=timeout reported apart, exit 1, backup kept (rc $rc)" \
	bash -c "[ $rc = 1 ] && [ '$(st k3 misc-verify)' = ok ] && [ '$(st k3 reset)' = timeout ] && [ $(backups d_k3) = 1 ] && grep -q 'misc written and verified; the reset did not complete' k3.log && opev k3 | grep -q '\"misc_verify\":\"ok\",\"ending\":\"timeout\"'"
MOCK_RESET_GONE=1 run k4 --confirm-token "$REC" "${L[@]}" parts pt.txt ops misc-reboot recovery d_k4; rc=$?
check "device leaves the bus on reset: counted as done (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ '$(st k4 reset)' = left-bus ] && [ $(backups d_k4) = 1 ]"

echo "== --expect =="
run e1 --confirm-token "$REC" "${L[@]}" parts pt.txt ops misc-reboot recovery d_e1 --expect "$(printf '%064d' 0)"; rc=$?
check "misc changed since it was read: stop before the write, backup kept + recorded, op refused misc-changed (rc $rc)" \
	bash -c "[ $rc != 0 ] && nowrite e1 && grep -q 'misc CHANGED since it was read' e1.log && [ $(backups d_e1) = 1 ] && (cd d_e1 && sha256sum -c --quiet meta/SHA256SUMS) && opev e1 | grep -q '\"why\":\"misc-changed\",.*\"backup_state\":\"kept\"'"
run e2 --confirm-token "$REC" "${L[@]}" parts pt.txt ops misc-reboot recovery d_e2 --expect "$MISC_SHA"; rc=$?
check "misc unchanged: the write goes ahead (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'misc is unchanged' e2.log && [ '$(st e2 misc-verify)' = ok ]"

echo "== set-active =="
run s1 --confirm-token "$TOKB" "${L[@]}" parts pt.txt ops set-active b d_s1 --ending reset; rc=$?
check "set-active b --ending reset: token = sha256 of 'spdhost-set-active b none', rc 0, one write, one reset (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(grep -c '^write misc:' s1.log) = 1 ] && [ $(nreset s1) = 1 ] && [ '$(st s1 misc-verify)' = ok ] && [ '$(st s1 reset)' = ack ]"
check "set-active b: only the slot block at 0x800 changed; BCB area and the rest as read" \
	bash -c "cmp -s <(head -c 2048 s1.misc) <(head -c 2048 misc.in) && cmp -s <(tail -c +2081 s1.misc) <(tail -c +2081 misc.in) && ! cmp -s s1.misc misc.in"
check "set-active: backup kept + recorded; op event target b ok" \
	bash -c "[ $(backups d_s1) = 1 ] && (cd d_s1 && sha256sum -c --quiet meta/SHA256SUMS) && opev s1 | grep -q '\"op\":\"set-active\",\"target\":\"b\",\"state\":\"ok\",\"misc_verify\":\"ok\",\"ending\":\"ack\"'"
run s2 --confirm-token "$TOKA" "${L[@]}" parts pt.txt ops set-active b d_s2 --ending reset; rc=$?
check "the token binds the slot: slot a's token for set-active b is refused, nothing written (rc $rc)" \
	bash -c "[ $rc != 0 ] && nowrite s2 && [ $(backups d_s2) = 1 ]"
run s3 --confirm-token "$TOKB" "${L[@]}" parts pt.txt ops set-active b d_s3 --bcb recovery; rc=$?
check "the token binds the BCB: the no-BCB token is refused for --bcb recovery (rc $rc)" bash -c "[ $rc != 0 ] && nowrite s3"
run s4 --confirm-token "$TOKBR" "${L[@]}" parts pt.txt ops set-active b d_s4 --bcb recovery; rc=$?
check "set-active b --bcb recovery: ONE write carrying BCB + slot, then reset (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(grep -c '^write misc:' s4.log) = 1 ] && cmp -s <(head -c 2048 s4.misc) '$root/misc/misc-recovery.bin' && cmp -s <(tail -c +2049 s4.misc) <(tail -c +2049 s1.misc) && [ $(nreset s4) = 1 ]"
run s5 --confirm-token "$TOKB" "${L[@]}" parts pt.txt ops set-active b d_s5 --ending power-off; rc=$?
check "--ending power-off: power-off frame, power-off=ack (rc $rc)" \
	bash -c "[ $rc = 0 ] && tail -1 s5.seq | grep -q '^SEQ 17 ' && [ '$(st s5 power-off)' = ack ]"
run s6 --confirm-token "$TOKB" "${L[@]}" parts pt.txt ops set-active b d_s6 power-off; rc=$?
check "no --ending: the caller's next argv ends the session (rc $rc)" \
	bash -c "[ $rc = 0 ] && tail -1 s6.seq | grep -q '^SEQ 17 ' && opev s6 | grep -q '\"ending\":\"caller\"'"
MOCK_PTABLE=$tmp/ptn run s7 --confirm-token "$TOKB" "${L[@]}" parts pt.txt ops set-active b d_s7 --ending reset; rc=$?
check "not A/B (no uboot_a/uboot_b): refused before the backup and any write (rc $rc)" \
	bash -c "[ $rc != 0 ] && nowrite s7 && [ ! -e d_s7/meta ] && opev s7 | grep -q '\"why\":\"not-ab\"'"

echo "== confirm-plan =="
run p0 "${L[@]}" parts pt.txt
./sh plan "${L[@]}" parts pt.txt ops misc-reboot recovery d_p1 >p1.plan 2>p1.perr; rc=$?
S=$(sed -n 's/^plan-sha256=//p' p1.plan)
check "plan: ops misc-reboot is one step at the ops argv, BCB bound, backup dir bound (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -qx 'step 1 argi=11 class=yes op=reboot-recovery+reset part=misc slot=active offset=0 size=2048 data-sha256=$REC verb=reboot-recovery%20via' p1.plan && grep -qx 'backup-dir arg=14 d_p1' p1.plan"
run p1 --confirm-plan "$S" "${L[@]}" parts pt.txt ops misc-reboot recovery d_p1; rc=$?
check "run --confirm-plan: backup, BCB, verify, reset, no prompt (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'step 1 authorized: reboot-recovery via' p1.log && cmp -s <(head -c 2048 p1.misc) '$root/misc/misc-recovery.bin' && [ $(backups d_p1) = 1 ]"
./sh plan "${L[@]}" parts pt.txt ops misc-reboot recovery d_p2 >p2.plan 2>p2.perr
S2=$(sed -n 's/^plan-sha256=//p' p2.plan)
run p2 --confirm-plan "$S2" "${L[@]}" parts pt.txt ops misc-reboot recovery d_OTHER; rc=$?
check "another backup DIR than the plan's is refused before USB (rc $rc)" bash -c "[ $rc != 0 ] && [ ! -e p2.seq ] && [ ! -e d_OTHER ]"
./sh plan "${L[@]}" parts pt.txt ops set-active b d_p3 --ending reset >p3.plan 2>p3.perr; rc=$?
S3=$(sed -n 's/^plan-sha256=//p' p3.plan)
check "plan: ops set-active b binds the patch line's sha256 (= the token) and slot b (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -qx 'step 1 argi=11 class=yes op=set-active part=misc slot=b offset=0x800 size=32 data-sha256=$TOKB verb=set-active' p3.plan"
run p3 --confirm-plan "$S3" "${L[@]}" parts pt.txt ops set-active b d_p3 --ending reset; rc=$?
check "run: set-active b via the plan, one write, reset (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ '$(st p3 misc-verify)' = ok ] && [ '$(st p3 reset)' = ack ]"
./sh plan "${L[@]}" parts pt.txt ops misc-reboot recovery d_p4 --expect "$MISC_SHA" >p4.plan 2>p4.perr; rc=$?
check "plan binds --expect (rc $rc)" bash -c "[ $rc = 0 ] && grep -qx 'expect arg=16 sha256=$MISC_SHA' p4.plan"
check "plan: ops dump stays unplannable" \
	bash -c './sh plan "$@" parts pt.txt ops dump dd --preset all_lite 2>&1 | grep -q "unknown or unplannable command: ops dump"' _ "${L[@]}"

echo "== menu.sh: core op when caps say so, bash path otherwise =="
cat > runner <<R
#!/usr/bin/env bash
printf '%s\n' "\$*" >> $tmp/m\${M:-1}.argv
SPDHOST_STATUS_FILE=\$SPDHOST_STATUS_FILE MOCK_LOG=$tmp/m\${M:-1}.seq MOCK_MISC_OUT=$tmp/m\${M:-1}.misc exec "$tmp/sh" --usb-fd 7 "\$@" 7</dev/null 2>>$tmp/m\${M:-1}.err
R
chmod +x runner
cat > menu_env.sh <<M
export SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=$tmp/runner SPDHOST_MENU_CONFIG=$tmp/none.conf
export SPDHOST_EXEC_ADDR=0x65015f08 SPDHOST_TIMEOUT=1000 SPDHOST_BIN=$tmp/sh TMPDIR=$tmp
source "$root/scripts/menu.sh"
FDL1=$tmp/fdl1-dl.bin FDL1_ADDR=0x65000800 FDL2=$tmp/fdl2-dl.bin FDL2_ADDR=0x9efffe00 MISC_DIR=$root/misc SOC=ums9230
cls() { :; }; pause() { :; }; ready() { :; }
M
out=$(export M=1; source ./menu_env.sh; DUMP_DIR=$tmp/md1; MISC_CONFIRM_TOKEN=$REC guarded_misc_session reboot-recovery reboot-recovery 2>&1); rc=$?
check "menu with cap=ops-misc: ONE session 'parts ... ops misc-reboot recovery DUMP_DIR', no misc-backup cmd, no --yes (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(wc -l < m1.argv) = 1 ] && grep -q -- '--confirm-token=$REC .*parts .* ops misc-reboot recovery $tmp/md1\$' m1.argv && ! grep -q -- 'misc-backup\|--yes' m1.argv"
check "menu (core): reports the core's kept backup, restore line, verify and reset; SHA256SUMS by the core" \
	bash -c '[[ $1 == *"misc backup: $2/meta/misc-before-"*"(recorded in meta/SHA256SUMS; kept)"* && $1 == *"misc verify: OK"* && $1 == *"reset into recovery: acknowledged"* && $1 == *"write-part misc $2/meta/misc-before-"* ]] && (cd "$2" && sha256sum -c --quiet meta/SHA256SUMS) && [ $(ls "$2"/meta/misc-before-*.img | wc -l) = 1 ]' _ "$out" "$tmp/md1"
out=$(export M=2 MOCK_FAIL_MID=misc; source ./menu_env.sh; DUMP_DIR=$tmp/md2; MISC_CONFIRM_TOKEN=$REC guarded_misc_session reboot-recovery reboot-recovery 2>&1); rc=$?
check "menu (core): failed backup -> 'write was NOT done', nonzero, no file (rc $rc)" \
	bash -c '[ "$3" != 0 ] && [[ $1 == *"write was NOT done"* ]] && ! ls "$2"/meta/misc-before-*.img >/dev/null 2>&1' _ "$out" "$tmp/md2" "$rc"
out=$(export M=3 MOCK_RESET_SILENT=1; source ./menu_env.sh; DUMP_DIR=$tmp/md3; MISC_CONFIRM_TOKEN=$REC guarded_misc_session reboot-recovery reboot-recovery 2>&1); rc=$?
check "menu (core): verify OK + reset lost reported apart, backup kept (rc $rc)" \
	bash -c '[ "$3" != 0 ] && [[ $1 == *"misc verify: OK"* && $1 == *"reset into recovery: FAILED -- no ack"* && $1 == *"misc WAS written and verified"* && $1 == *"kept"* ]] && [ $(ls "$2"/meta/misc-before-*.img | wc -l) = 1 ]' _ "$out" "$tmp/md3" "$rc"
out=$(export M=4; source ./menu_env.sh; DUMP_DIR=$tmp/md4; MISC_CONFIRM_TOKEN=$TOKB guarded_misc_session "set-active b" set-active b reset 2>&1); rc=$?
check "menu set-active b + reset -> 'ops set-active b DUMP_DIR --ending reset' (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'ops set-active b $tmp/md4 --ending reset\$' m4.argv && [ \$(wc -l < m4.argv) = 1 ]"
out=$(export M=5; source ./menu_env.sh; DUMP_DIR=$tmp/md5; MISC_EXPECT_SHA=$MISC_SHA MISC_CONFIRM_TOKEN=$REC guarded_misc_session reboot-recovery reboot-recovery 2>&1); rc=$?
check "menu: MISC_EXPECT_SHA rides as --expect on the core op (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'ops misc-reboot recovery $tmp/md5 --expect $MISC_SHA\$' m5.argv"
out=$(export M=6; source ./menu_env.sh; DUMP_DIR=$tmp/md6; spdhost_has_cap() { [[ $1 != ops-misc ]]; }
	MISC_CONFIRM_TOKEN=$REC guarded_misc_session reboot-recovery reboot-recovery 2>&1); rc=$?
check "menu, older spdhost (no cap=ops-misc): bash path 'misc-backup FILE reboot-recovery' (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'parts .* misc-backup $tmp/md6/meta/misc-before-[0-9-]*.img reboot-recovery\$' m6.argv && ! grep -q ' ops ' m6.argv && (cd $tmp/md6 && sha256sum -c --quiet meta/SHA256SUMS)"
out=$(export M=7; source ./menu_env.sh; DUMP_DIR=$tmp/md7; MISC_CONFIRM_TOKEN=$WIPE guarded_misc_session wipe-userdata write-part misc "$root/misc/misc-wipe.bin" reset 2>&1); rc=$?
check "menu: other misc writes (wipe/restore/slot image) keep the bash path" \
	bash -c "grep -q 'misc-backup $tmp/md7/meta/misc-before-[0-9-]*.img write-part misc' m7.argv && ! grep -q ' ops ' m7.argv"

echo "ops-misc: $pass passed, $fail failed"
[ "$fail" = 0 ]
