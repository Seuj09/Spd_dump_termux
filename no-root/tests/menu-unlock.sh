#!/usr/bin/env bash
# Menu [unlock bootloader] recovery-path fixes (feature-audit/REPORT.md):
#   U1  a fresh splloader/uboot backup every run, in its own folder; an older
#       backup_spl/ is never reused or restored
#   U2  splloader_bak is erased before splloader
#   U4  the uboot backup is restored to the row it was dumped from
# The runner is a fake that records each session's argv and writes the files a
# backup session would; confirm_dangerous/pause/ready are stubbed (the typed
# word is the pty tests' job, in write-seq.sh).
# Usage (from no-root/): tests/menu-unlock.sh   (KEEP=1 keeps the tmp dir)
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] && echo "tmp=$tmp" || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
cd "$tmp"
# The runner: SLOTFILE names the uboot row the "phone" dumps (uboot_a,
# uboot_b or uboot); FAIL_ON is a glob of argv that exits 3.
cat > run <<'R'
#!/bin/bash
printf '%s\n' "$*" >> "$REC"
if [[ -n ${FAIL_ON:-} && "$*" == $FAIL_ON ]]; then exit 3; fi
case "$*" in
  *"read-part splloader 0 262144 "*)
    prev=; spl=; for a in "$@"; do [[ $prev == 262144 ]] && spl=$a; prev=$a; done
    d=$(dirname "$spl")
    printf 'FRESH-SPL' > "$spl"; head -c $((262144 - 9)) /dev/zero >> "$spl"
    printf 'FRESH-UB' > "$d/${SLOTFILE:-uboot_a}.img"
    printf 'ok %s x\n' "${SLOTFILE:-uboot_a}" > "$d/dump-manifest.txt"
    ;;
esac
exit 0
R
chmod +x run
mkdir -p fdl && printf c > fdl/fdl2-cboot.bin && printf u > fdl/spl-unlock.bin && printf 1 > fdl/fdl1.bin && printf 2 > fdl/fdl2.bin
unlock_run() { # LABEL [VAR=value ...]: one unlock_bootloader_menu run in a fresh shell
	local L=$1; shift
	: > "rec_$L"
	env "$@" REC="$tmp/rec_$L" SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER="$tmp/run" SPDHOST_MENU_CONFIG="$tmp/none.conf" \
		bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
		FDL1=$2/fdl/fdl1.bin FDL1_ADDR=0x65000800 FDL2=$2/fdl/fdl2.bin FDL2_ADDR=0x9efffe00 SOC=ums9230 DEVICE=testphone
		ACTIVE_SLOT=${ACTIVE_SLOT:-a}
		confirm_dangerous() { return 0; }; pause() { return 0; }; ready() { return 0; }; cls() { :; }
		need_loaders() { return 0; }; exec_addr_value() { return 1; }
		unlock_bootloader_menu; echo "rc=$?"' _ "$root" "$tmp" > "out_$L" 2>&1
}

# ---- U1 ---------------------------------------------------------------------------------
# A complete-looking backup from an earlier run (another phone, or pre-OTA).
mkdir -p backup_spl
printf 'STALE-SPL' > backup_spl/splloader.img; head -c $((262144 - 9)) /dev/zero >> backup_spl/splloader.img
printf 'STALE-UB' > backup_spl/uboot_a.img
printf 'ok uboot_a x\n' > backup_spl/dump-manifest.txt
unlock_run u1
check "U1: the backup session runs even though backup_spl/ looks complete" \
	grep -q 'read-part splloader 0 262144 .*/backup_spl/unlock-[0-9-]*/splloader.img' rec_u1
check "U1: the restore writes this run's files, never the stale ones" \
	bash -c "grep 'write-part splloader' rec_u1 | grep -q '/backup_spl/unlock-[0-9-]*/splloader.img' && ! grep -q 'backup_spl/splloader.img\|backup_spl/uboot_a.img' rec_u1"
check "U1: the backup is dumped before the erase" \
	bash -c "awk '/read-part splloader 0 262144/{b=NR} /danger-erase/{e=NR} END{exit !(b && e && b < e)}' rec_u1"
check "U1: the stale backup is left alone" bash -c "head -c 9 backup_spl/splloader.img | grep -q STALE-SPL"
check "U1: no 'Reusing' path is left" bash -c "! grep -q Reusing out_u1 && grep -q 'rc=0' out_u1"
# A short read in the fresh session stops before the erase.
cat > run_short <<'R'
#!/bin/bash
printf '%s\n' "$*" >> "$REC"
case "$*" in
  *"read-part splloader 0 262144 "*)
    prev=; spl=; for a in "$@"; do [[ $prev == 262144 ]] && spl=$a; prev=$a; done
    printf short > "$spl"; printf u > "$(dirname "$spl")/uboot_a.img" ;;
esac
exit 0
R
chmod +x run_short
cp run run_full; cp run_short run
unlock_run u1short
cp run_full run
check "U1: a short splloader backup stops the run before any erase" \
	bash -c "grep -q 'missing or short' out_u1short && ! grep -q danger-erase rec_u1short && grep -q 'rc=1' out_u1short"
# Two runs never share a folder.
unlock_run u1b
d1=$(grep -o '/backup_spl/unlock-[0-9-]*' rec_u1 | head -1); d2=$(grep -o '/backup_spl/unlock-[0-9-]*' rec_u1b | head -1)
check "U1: each run gets its own backup folder ($d1 vs $d2)" bash -c "[ -n '$d1' ] && [ -n '$d2' ] && [ '$d1' != '$d2' ]"

# ---- U2 ---------------------------------------------------------------------------------
check "U2: the erase session names splloader_bak first, then splloader" \
	bash -c "grep -q 'danger-erase splloader_bak danger-erase splloader reset' rec_u1"
unlock_run u2fail FAIL_ON='*danger-erase*'
check "U2: a failed erase session skips cboot and the unlock loader but still restores" \
	bash -c "grep -q 'splloader was never erased' out_u2fail && ! grep -q 'fdl2-cboot.bin' rec_u2fail && ! grep -q 'spl-unlock.bin' rec_u2fail && grep -q 'write-part splloader' rec_u2fail"

# ---- U4 ---------------------------------------------------------------------------------
# The phone dumped uboot_b (slot b active at backup time); the menu's own
# ACTIVE_SLOT says a. The restore must go to uboot_b, not to the active name.
unlock_run u4 SLOTFILE=uboot_b ACTIVE_SLOT=a
check "U4: a uboot_b backup is restored to uboot_b" \
	bash -c "grep 'write-part splloader' rec_u4 | grep -q 'write-part uboot_b .*/uboot_b.img'"
unlock_run u4fail SLOTFILE=uboot_b ACTIVE_SLOT=a FAIL_ON='*write-part splloader*'
check "U4: the printed restore command also targets uboot_b" \
	bash -c "grep -q 'RESTORE FAILED' out_u4fail && grep -A30 'Restore command' out_u4fail | grep -q 'write-part uboot_b .*uboot_b.img'"
unlock_run u4nab SLOTFILE=uboot
check "U4: a non-A/B uboot.img goes back to uboot" \
	bash -c "grep 'write-part splloader' rec_u4nab | grep -q 'write-part uboot .*/uboot.img'"
out=$(SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
	unlock_uboot_row /x/uboot_a.img; unlock_uboot_row /x/uboot_b.img; unlock_uboot_row /x/uboot.img; unlock_uboot_row /x/other.img' _ "$root" | tr '\n' ' ')
check "U4: unlock_uboot_row maps file names to rows [$out]" test "$out" = "uboot_a uboot_b uboot uboot "

echo "menu-unlock: $pass passed, $fail failed"
(( fail == 0 ))
