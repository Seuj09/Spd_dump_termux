#!/usr/bin/env bash
# B1-1: flash/restore refuse unverified / headerless parts.
# B1-2: free-space preflight refuses when df is short.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
cd "$tmp"
mkdir -p fdl/ums9230/t backup/meta input
printf 1 > fdl/ums9230/t/fdl1.bin; printf 2 > fdl/ums9230/t/fdl2.bin
printf boot > input/boot.img
cat > run <<'R'
#!/bin/bash
printf '%s\n' "$*" >> "$REC"; exit 0
R
chmod +x run

run_flash() {
	local L=$1
	: > "rec_$L"
	env REC="$tmp/rec_$L" SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER="$tmp/run" \
		SPDHOST_MENU_CONFIG="$tmp/none.conf" DUMP_DIR="$tmp/backup" INPUT_DIR="$tmp/input" \
		bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
		FDL1=$2/fdl/ums9230/t/fdl1.bin FDL1_ADDR=0x65000800
		FDL2=$2/fdl/ums9230/t/fdl2.bin FDL2_ADDR=0x9efffe00 SOC=ums9230 DEVICE=t
		confirm_action() { return 0; }; pause() { return 0; }; ready() { echo READY; return 0; }; cls() { :; }
		need_loaders() { return 0; }; exec_addr_value() { return 1; }
		flash_input_menu; echo "rc=$?"' _ "$root" "$tmp" > "out_$L" 2>&1
}

printf '%s\n' 'boot_a 4096' 'misc 1024' > backup/meta/partition_list.txt
run_flash hless
check "B1-1: flash refuses headerless parts table" \
	bash -c "grep -q 'REFUSED: the partition table has no spdhost-parts header' out_hless && grep -q 'rc=1' out_hless && ! grep -q READY out_hless"

printf '%s\n' '# spdhost-parts shift 10 verified 0' 'boot_a 4096' 'misc 1024' > backup/meta/partition_list.txt
run_flash unv
check "B1-1: flash refuses verified 0" \
	bash -c "grep -q 'REFUSED: this table.s size unit is a guess' out_unv && grep -q 'rc=1' out_unv && ! grep -q READY out_unv"

out=$(SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
	DUMP_DIR=$2/backup; require_free_space "$DUMP_DIR" 999999999999999 64 "dump test"; echo rc=$?' _ "$root" "$tmp" 2>&1)
check "B1-2: require_free_space refuses when need exceeds avail" \
	bash -c '[[ $1 == *REFUSED:\ not\ enough\ free\ space* && $1 == *rc=1* ]]' _ "$out"

out=$(SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
	DUMP_DIR=$2/backup; require_free_space "$DUMP_DIR" 1 0 "tiny"; echo rc=$?' _ "$root" "$tmp" 2>&1)
check "B1-2: require_free_space allows a tiny need" \
	bash -c '[[ $1 == *rc=0* && $1 != *REFUSED* ]]' _ "$out"

# C13 (audit6): the flash stage is symlinks, which need no space, so there is
# no staging check at all; only a file that cannot be linked is copied, and
# that copy is checked first against the source's REAL size (stat -L).
printf '%s\n' '# spdhost-parts shift 10 verified 1' 'boot_a 4096' 'misc 1024' > backup/meta/partition_list.txt
truncate -s 3G input/boot.img
run_flash_c13() { # L EXTRA-SNIPPET
	local L=$1
	: > "rec_$L"
	env REC="$tmp/rec_$L" SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER="$tmp/run" \
		SPDHOST_MENU_CONFIG="$tmp/none.conf" DUMP_DIR="$tmp/backup" INPUT_DIR="$tmp/input" \
		bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
		FDL1=$2/fdl/ums9230/t/fdl1.bin FDL1_ADDR=0x65000800
		FDL2=$2/fdl/ums9230/t/fdl2.bin FDL2_ADDR=0x9efffe00 SOC=ums9230 DEVICE=t
		confirm_action() { return 0; }; pause() { return 0; }; ready() { echo READY; return 0; }; cls() { :; }
		need_loaders() { return 0; }; exec_addr_value() { return 1; }
		require_free_space() { echo "RFS need=$2 label=$4"; return 1; }
		cp() { echo "CP $*"; command cp "$@"; }
		eval "$3"
		flash_input_menu; echo "rc=$?"' _ "$root" "$tmp" "${2:-}" > "out_$L" 2>&1
}
run_flash_c13 c13link
check "C13: a symlink stage is not size-checked and the flash runs" \
	bash -c "! grep -q RFS out_c13link && ! grep -q '^CP ' out_c13link && grep -q READY out_c13link && grep -q 'write-files' rec_c13link"
run_flash_c13 c13cp 'ln() { return 1; }'
check "C13: a copied stage is checked BEFORE the copy, with the real size (3 GiB)" \
	bash -c "grep -q 'RFS need=3221225472 label=flash staging copy of boot.img' out_c13cp && ! grep -q '^CP ' out_c13cp && ! grep -q READY out_c13cp && [ ! -s rec_c13cp ] && grep -q 'rc=1' out_c13cp"
rm -f input/boot.img; printf boot > input/boot.img

echo "menu-flash-gate: $pass passed, $fail failed"
(( fail == 0 ))
