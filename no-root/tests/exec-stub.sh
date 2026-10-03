#!/usr/bin/env bash
# Every BootROM session must reach spdhost with the exec stub's own path.
#
# The stub is named after its address, and each chip ships its own
# (fdl/<soc>/custom_exec_no_verify_<hex>.bin). spdhost's default lookup knew
# only fdl/ums9230/, so a session that named the address alone -- which is
# what run_session used to send -- died with
#   exec_addr 0x4ee8: custom_exec_no_verify_4ee8.bin not found
# rc=1 before it opened the device, on sc9863a and ums512 only. The menu's own
# pre-check searched all three chips and passed, so nothing caught it.
#
# This drives run_session with the real spdhost in --dry-run (no USB, but the
# argument parsing and the lookup are the real ones) and requires rc=0 and the
# correct per-chip path in argv, then checks the same for a hand-typed line
# that names only the address.
#
# Usage (from no-root/): tests/exec-stub.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

gcc -O2 -w -std=c11 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" \
	"$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" \
	"$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" \
	-o "$tmp/spdhost" || exit 1

mkdir -p "$tmp/in" "$tmp/dump"

# drive SOC -> prints run_session's transcript; rc is run_session's.
drive() {
	local soc=$1 brand
	case $soc in
		ums9230) brand=infinix ;;
		*) brand=realme ;;
	esac
	(
		export SPDHOST_MENU_LIB=1
		export SPDHOST_INPUT_DIR=$tmp/in SPDHOST_DUMP_DIR=$tmp/dump
		unset SPDHOST_EXEC_ADDR
		# shellcheck source=/dev/null
		source "$root/scripts/menu.sh" >/dev/null 2>&1
		soc_profile "$soc"
		SOC=$soc
		EXEC_ADDR=$EXEC_ADDR_DEFAULT
		# load_config's job in a real run; soc_profile only sets the SOC_* copies.
		FDL1_ADDR=$SOC_FDL1_ADDR
		FDL2_ADDR=$SOC_FDL2_ADDR
		FDL1=$root/fdl/$soc/$brand/fdl1-dl.bin
		FDL2=$root/fdl/$soc/$brand/fdl2-dl.bin
		RUNNER=("$tmp/spdhost" --dry-run)
		run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" reset
	) 2>&1
}

# out=$(drive SOC) has to keep the subshell's status, and its stderr, so the
# failure text is assertable. $(...) alone drops stderr and $? reports the
# assignment, so both are captured inside the helper.
driving() { # SOC -> sets out, rc
	out=$(drive "$1" 2>&1)
	rc=$?
}

# ------------------------------------------------- a session per chip
for soc in ums9230 ums512 sc9863a; do
	case $soc in
		ums9230) hex=65015f08 ;;
		ums512) hex=3ee8 ;;
		sc9863a) hex=4ee8 ;;
	esac
	driving "$soc"
	check "$soc: the session reaches spdhost (rc 0)" test "$rc" = 0
	check "$soc: argv names the chip's own stub, not just the address" \
		bash -c '[[ $1 == *"exec_addr 0x$2 "*"fdl/$3/custom_exec_no_verify_$2.bin "* ]]' \
		_ "$out" "$hex" "$soc"
	check "$soc: no chip is served another chip's stub" \
		bash -c 'for s in ums9230 ums512 sc9863a; do
			[ "$s" = "$2" ] && continue
			[[ $1 == *"fdl/$s/"* ]] && exit 1
		done
		exit 0' _ "$out" "$soc"
	check "$soc: that stub is on disk" test -f "$root/fdl/$soc/custom_exec_no_verify_$hex.bin"
done

# The ums9230 path is the one that always worked; keep it honest.
driving ums9230
check "ums9230: still the ums9230 stub (no regression from the general fix)" \
	bash -c '[[ $1 == *"fdl/ums9230/custom_exec_no_verify_65015f08.bin"* ]]' _ "$out"

# ------------------------------------ the stub the session needs is missing
# A chip whose stub is not on disk must fail in the menu, before the plug-in
# wait, and must not run a session at all.
out=$(
	export SPDHOST_MENU_LIB=1 SPDHOST_INPUT_DIR=$tmp/in SPDHOST_DUMP_DIR=$tmp/dump
	# shellcheck source=/dev/null
	source "$root/scripts/menu.sh" >/dev/null 2>&1
	SOC=ums9230
	EXEC_ADDR=0x1234
	RUNNER=(echo SHOULD-NOT-RUN)
	run_session fdl "$root/fdl/ums9230/infinix/fdl1-dl.bin" 0x65000800 reset 2>&1
)
rc=$?
check "a missing stub stops the session before anything runs (rc $rc)" test "$rc" != 0
check "a missing stub runs no command" bash -c '[[ $1 != *SHOULD-NOT-RUN* ]]' _ "$out"
check "a missing stub says which file and how to disable it" \
	bash -c '[[ $1 == *custom_exec_no_verify_1234.bin* && $1 == *SPDHOST_EXEC_ADDR=0* ]]' _ "$out"

# ------------------------------------------- a hand-typed line, address only
# Not the menu's own path: this is the fallback in find_exec_file, which has
# to find the stub for the chip the address belongs to. It looks next to the
# binary first, so the binary has to sit in a package-shaped tree -- a copy in
# a bare temp dir is a different (and correctly unsupported) layout.
mkdir -p "$tmp/pkg/elsewhere"
cp "$tmp/spdhost" "$tmp/pkg/spdhost"
ln -s "$root/fdl" "$tmp/pkg/fdl"
for pair in 0x65015f08:ums9230 0x3ee8:ums512 0x4ee8:sc9863a; do
	addr=${pair%%:*}; soc=${pair##*:}
	(cd "$tmp/pkg/elsewhere" && "$tmp/pkg/spdhost" --dry-run exec_addr "$addr" ping) >/dev/null 2>&1
	check "CLI: exec_addr $addr alone finds the $soc stub from another directory" test $? = 0
done
(cd "$tmp/pkg/elsewhere" && "$tmp/pkg/spdhost" --dry-run exec_addr 0xdead ping) >/dev/null 2>&1
check "CLI: an address with no stub anywhere is still refused" test $? != 0

echo
echo "exec-stub: $pass passed, $fail failed"
(( fail == 0 ))
