#!/usr/bin/env bash
# Menu [unlock bootloader] recovery-path fixes (feature-audit/REPORT.md):
#   U1  a fresh splloader/uboot backup every run, in its own folder; an older
#       backup_spl/ is never reused or restored
#   U2  splloader_bak is erased before splloader
#   U4  the uboot backup is restored to the row it was dumped from
#   U6  fdl2-cboot.bin / spl-unlock.bin come only from the model's own folder
#   G2  non-A/B, an unverified table or an oversized cboot is refused before the
#       erase; cboot goes to uboot only; the restore reports its two writes apart
#   G5  an spl-unlock.bin with 0 signature sites patched stops before the erase
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
# G2: every session that names `parts FILE` gets a table written there (A/B by
# default; SLOTFILE=uboot gives a non-A/B one with a uboot_bak twin; VERIFIED=0
# marks the unit unconfirmed; UBOOT_KIB sizes the uboot rows). Each
# write-part-plain NAME logs write-NAME=ok to SPDHOST_STATUS_FILE, except
# FAIL_WRITE=NAME, which logs failed and ends the session like spdhost does.
cat > run <<'R'
#!/bin/bash
printf '%s\n' "$*" >> "$REC"
if [[ -n ${FAIL_ON:-} && "$*" == $FAIL_ON ]]; then exit 3; fi
prev=; for a in "$@"; do
  if [[ $prev == parts ]]; then
    { if [[ -z ${NOHEADER:-} ]]; then echo "# spdhost-parts shift 10 verified ${VERIFIED:-1}"; fi
      if [[ ${SLOTFILE:-uboot_a} == uboot ]]; then echo "uboot ${UBOOT_KIB:-1024}"; echo "uboot_bak ${UBOOT_KIB:-1024}"
      else echo "uboot_a ${UBOOT_KIB:-1024}"; echo "uboot_b ${UBOOT_KIB:-1024}"; fi
      echo "misc 1024"; echo "miscdata 1024"; } > "$a"
  fi
  prev=$a
done
prev=; for a in "$@"; do
  if [[ $prev == write-part-plain || $prev == write-part ]]; then
    if [[ $a == "${FAIL_WRITE:-}" ]]; then
      [[ -n ${SPDHOST_STATUS_FILE:-} ]] && echo "write-$a=failed" >> "$SPDHOST_STATUS_FILE"; exit 1
    fi
    [[ -n ${SPDHOST_STATUS_FILE:-} ]] && echo "write-$a=ok" >> "$SPDHOST_STATUS_FILE"
  fi
  prev=$a
done
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
M=fdl/ums9230/testphone
mkdir -p $M && printf c > $M/fdl2-cboot.bin && printf u > $M/spl-unlock.bin && printf 1 > $M/fdl1.bin && printf 2 > $M/fdl2.bin
B=fdl/ums9230/bigphone
mkdir -p $B && head -c 2048 /dev/zero > $B/fdl2-cboot.bin && printf u > $B/spl-unlock.bin && printf 1 > $B/fdl1.bin && printf 2 > $B/fdl2.bin
unlock_run() { # LABEL [VAR=value ...]: one unlock_bootloader_menu run in a fresh shell
	local L=$1; shift
	: > "rec_$L"
	env "$@" REC="$tmp/rec_$L" SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER="$tmp/run" SPDHOST_MENU_CONFIG="$tmp/none.conf" \
		bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
		MD=${MODEL:-testphone}
		FDL1=$2/fdl/ums9230/$MD/fdl1.bin FDL1_ADDR=0x65000800 FDL2=$2/fdl/ums9230/$MD/fdl2.bin FDL2_ADDR=0x9efffe00 SOC=ums9230 DEVICE=$MD
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

# ---- G2 ---------------------------------------------------------------------------------
check "G2: cboot goes to uboot only (write-part-plain), never a twin write-part" \
	bash -c "grep -q 'write-part-plain uboot .*fdl2-cboot.bin' rec_u1 && ! grep -qE 'write-part uboot([[:space:]]|$)' rec_u1"
unlock_run g2nab SLOTFILE=uboot
check "G2: non-A/B (uboot + uboot_bak, no uboot_a/_b) is refused after the backup, before any erase or write" \
	bash -c "grep -q 'UNLOCK REFUSED: this phone is not A/B' out_g2nab && grep -q 'rc=1' out_g2nab &&
		grep -q 'read-part splloader 0 262144' rec_g2nab && ! grep -q 'danger-erase\|write-part\|spl-unlock.bin' rec_g2nab"
unlock_run g2unv VERIFIED=0
check "G2: a table whose unit is unverified is refused before the erase" \
	bash -c "grep -q 'UNLOCK REFUSED: this table.s size unit is a guess' out_g2unv && ! grep -q 'danger-erase\|write-part' rec_g2unv"
unlock_run g2big MODEL=bigphone UBOOT_KIB=1
check "G2: a cboot bigger than the uboot row is refused before the erase, not after" \
	bash -c "grep -q 'UNLOCK REFUSED: fdl2-cboot.bin is 2048 bytes and uboot_a is 1024 bytes' out_g2big && ! grep -q 'danger-erase\|write-part' rec_g2big"
unlock_run g2ub FAIL_WRITE=uboot_a
check "G2: restore reports splloader and uboot apart: splloader RESTORED, uboot_a not" \
	bash -c "grep -q 'splloader: RESTORED' out_g2ub && grep -q 'uboot_a: NOT restored (the write was refused or failed)' out_g2ub &&
		grep -q 'uboot_a may still hold fdl2-cboot.bin' out_g2ub && grep -q 'RESTORE INCOMPLETE' out_g2ub &&
		! grep -q 'splloader is still erased' out_g2ub && grep -q 'rc=1' out_g2ub"
unlock_run g2ok
check "G2: a clean restore says both were written" \
	bash -c "grep -q 'Restore: splloader written, uboot_a written.' out_g2ok && grep -q 'rc=0' out_g2ok"
# N1: headerless table (pre-G1 spdhost) must refuse before erase.
unlock_run n1skew NOHEADER=1
check "N1: a headerless parts table is refused before erase (version skew)" \
	bash -c "grep -q 'UNLOCK REFUSED: the partition table has no spdhost-parts header' out_n1skew &&
		grep -q 'rc=1' out_n1skew && grep -q 'read-part splloader 0 262144' rec_n1skew &&
		! grep -q 'danger-erase\|write-part' rec_n1skew"
# N1: A/B restore uses write-part (not write-part-plain); printed command too.
check "N1: restore session uses write-part for splloader and uboot_a" \
	bash -c "grep -qE 'write-part splloader .* write-part uboot_a' rec_g2ok &&
		! grep -qE 'write-part-plain splloader' rec_g2ok"
# N6: both writes ok, reset fails -> say both written, only ending failed.
cat > run_resetfail <<'R'
#!/bin/bash
printf '%s\n' "$*" >> "$REC"
prev=; for a in "$@"; do
  if [[ $prev == parts ]]; then
    { echo "# spdhost-parts shift 10 verified 1"
      echo "uboot_a 1024"; echo "uboot_b 1024"; echo "misc 1024"; echo "miscdata 1024"; } > "$a"
  fi
  if [[ $prev == write-part || $prev == write-part-plain ]]; then
    [[ -n ${SPDHOST_STATUS_FILE:-} ]] && echo "write-$a=ok" >> "$SPDHOST_STATUS_FILE"
  fi
  prev=$a
done
case "$*" in
  *"read-part splloader 0 262144 "*)
    prev=; spl=; for a in "$@"; do [[ $prev == 262144 ]] && spl=$a; prev=$a; done
    d=$(dirname "$spl")
    printf 'FRESH-SPL' > "$spl"; head -c $((262144 - 9)) /dev/zero >> "$spl"
    printf 'FRESH-UB' > "$d/uboot_a.img"
    printf 'ok uboot_a x\n' > "$d/dump-manifest.txt"
    ;;
esac
[[ "$*" == *"write-part splloader"* ]] && { echo "reset: no ack (timeout)" >&2; exit 1; }
exit 0
R
chmod +x run_resetfail
cp run run_full_n6; cp run_resetfail run
unlock_run n6reset
cp run_full_n6 run
check "N6: both writes ok and only reset fails: say both written, ending failed" \
	bash -c "grep -q 'RESTORE: both writes succeeded' out_n6reset &&
		grep -q 'only the ending' out_n6reset &&
		! grep -q 'RESTORE INCOMPLETE: only uboot_a is left' out_n6reset &&
		! grep -q 'splloader is still erased' out_n6reset && grep -q 'rc=1' out_n6reset"
out=$(SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
	unlock_uboot_row /x/uboot_a.img; unlock_uboot_row /x/uboot_b.img; unlock_uboot_row /x/uboot.img; unlock_uboot_row /x/other.img' _ "$root" | tr '\n' ' ')
check "U4: unlock_uboot_row maps file names to rows [$out]" test "$out" = "uboot_a uboot_b uboot uboot "

# ---- U6 ---------------------------------------------------------------------------------
# A release-like tree: the package root and ums9230/infinix both carry an
# fdl2-cboot.bin (the one the old ../../ hop and the no-model fallback found).
P=$tmp/pkg
mkdir -p $P/fdl/ums9230/infinix $P/fdl/ums512/tecno $P/fdl/ums9230/realme/alternatif/c53 $P/ums9230/infinix $P/manual
for d in $P/fdl/ums9230/infinix $P/fdl/ums512/tecno $P/fdl/ums9230/realme/alternatif/c53 $P/manual; do
	printf 1 > $d/fdl1-dl.bin; printf 2 > $d/fdl2-dl.bin; done
printf ROOT > $P/fdl2-cboot.bin; printf ROOT > $P/fdl/fdl2-cboot.bin
printf INFX > $P/fdl/ums9230/infinix/fdl2-cboot.bin; printf INFX > $P/ums9230/infinix/fdl2-cboot.bin
printf C53 > $P/fdl/ums9230/realme/alternatif/c53/fdl2-cboot.bin
fm() { # SOC DEVICE FDL1 -> what find_model_file answers (run from $P)
	(cd $P && SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
		SOC=$2 DEVICE=$3 FDL1=$4; find_model_file fdl2-cboot.bin || echo NONE' _ "$root" "$@"); }
check "U6: the model's own folder answers (ums9230/infinix)" \
	test "$(fm ums9230 infinix $P/fdl/ums9230/infinix/fdl1-dl.bin)" = "$P/fdl/ums9230/infinix/fdl2-cboot.bin"
check "U6: an alternatif model finds its own copy" \
	test "$(fm ums9230 realme/c53 $P/fdl/ums9230/realme/alternatif/c53/fdl1-dl.bin)" = "$P/fdl/ums9230/realme/alternatif/c53/fdl2-cboot.bin"
check "U6: a model with no copy gets nothing -- not ../../ (package root), not infinix's" \
	test "$(fm ums512 tecno $P/fdl/ums512/tecno/fdl1-dl.bin)" = NONE
check "U6: no model picked, loaders elsewhere: no cross-chip ums9230/infinix or \$PWD fallback" \
	test "$(fm ums512 '' $P/manual/fdl1-dl.bin)" = NONE
check "U6: a model whose FDL1 is not in that model's folder gets nothing" \
	test "$(fm ums9230 tecno $P/fdl/ums9230/infinix/fdl1-dl.bin)" = NONE
check "U6: no FDL1 at all gets nothing" test "$(fm ums9230 '' '')" = NONE
printf MAN > $P/manual/fdl2-cboot.bin
check "U6: hand-configured loaders (no model): the copy beside that FDL1 is the explicit choice" \
	test "$(fm ums512 '' $P/manual/fdl1-dl.bin)" = "$P/manual/fdl2-cboot.bin"
# And the menu refuses the unlock when the lookup answers nothing.
out=$(cd $P && SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/echo bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
	SOC=ums512 DEVICE=tecno FDL1=$2/fdl/ums512/tecno/fdl1-dl.bin FDL2=$2/fdl/ums512/tecno/fdl2-dl.bin
	unlock_bootloader_menu </dev/null' _ "$root" "$P" 2>&1)
check "U6: unlock with no model copy sends nothing and says where it looked" \
	bash -c '[[ $1 == *"Missing fdl2-cboot.bin"* && $1 == *"nothing sent"* && $1 != *danger-erase* ]]' _ "$out"

# ---- G5 ---------------------------------------------------------------------------------
# A fake image-tools spdhost whose patchers match nothing (LEGACY=1: the legacy
# one patches a site). Lists image-tools in `caps` so spdhost_has_image_tools
# is true (P0-2: the menu asks caps, not the usage line).
cat > fakespd <<'R'
#!/bin/bash
[[ $1 == --dry-run ]] && shift
case $1 in
  caps) printf 'caps_format=1\nbuild_sha=unknown\nprotocol=1\ncap=image-tools\nend\n'; exit 0 ;;
  gen-spl-unlock|gen-spl-unlock-legacy)
    if (( $# < 3 )); then echo "usage: spdhost $1 IN OUT" >&2; echo "gen-spl-unlock IN OUT" >&2; exit 1; fi
    cp "$2" "$3"
    if [[ $1 == gen-spl-unlock-legacy && -n ${LEGACY:-} ]]; then echo "$1: patched 2 signature site(s)" >&2
    else echo "$1: patched 0 signature site(s)" >&2; fi
    exit 0 ;;
esac
exit 1
R
chmod +x fakespd
mk5() { # LABEL ANSWER [VAR=value ...]: unlock_make_spl_unlock on a dump
	local L=$1 a=$2; shift 2
	mkdir -p "w5_$L"; head -c 4096 /dev/zero > "w5_$L/splloader.img"
	printf '%s\n' "$a" | env "$@" SPDHOST_BIN="$tmp/fakespd" SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true \
		SPDHOST_MENU_CONFIG="$tmp/none.conf" bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
		unlock_make_spl_unlock "$2" "$2/splloader.img"; echo "rc=$?"' _ "$root" "$tmp/w5_$L" > "out5_$L" 2>&1
}
mk5 none n
check "G5: 0 sites patched (legacy declined) stops before the erase, no spl-unlock.bin left" \
	bash -c "grep -q 'Neither pattern matched' out5_none && grep -q 'rc=1' out5_none && [ ! -e w5_none/spl-unlock.bin ]"
mk5 both0 y
check "G5: legacy tried and it matches nothing either: stops too" \
	bash -c "grep -q 'legacy pattern matched nothing either' out5_both0 && grep -q 'rc=1' out5_both0 && [ ! -e w5_both0/spl-unlock.bin ]"
mk5 legacy y LEGACY=1
check "G5: legacy patched sites: its result is used (rc 0)" \
	bash -c "grep -q 'Using the legacy result' out5_legacy && grep -q 'rc=0' out5_legacy && [ -s w5_legacy/spl-unlock.bin ]"
mk5 force n SPDHOST_UNLOCK_FORCE_UNPATCHED=1
check "G5: SPDHOST_UNLOCK_FORCE_UNPATCHED=1 is the explicit expert override" \
	bash -c "grep -q 'SPDHOST_UNLOCK_FORCE_UNPATCHED=1: continuing' out5_force && grep -q 'rc=0' out5_force"
# And end to end: no erase session after a 0-site build.
rm -f fdl/ums9230/testphone/spl-unlock.bin
unlock_run g5e2e SPDHOST_BIN="$tmp/fakespd" </dev/null
check "G5: the unlock never reaches danger-erase with an unpatched SPL" \
	bash -c "grep -q 'Neither pattern matched' out_g5e2e && grep -q 'rc=1' out_g5e2e && ! grep -q 'danger-erase' rec_g5e2e"
printf u > fdl/ums9230/testphone/spl-unlock.bin

echo "menu-unlock: $pass passed, $fail failed"
(( fail == 0 ))
