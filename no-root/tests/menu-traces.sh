#!/usr/bin/env bash
# E2 (plan §4.1): record the argv menu.sh's run_session hands spdhost for every
# P1 op, and check it against the goldens the Kotlin argv builder is tested
# against (android/app/src/test/resources/e2/*.trace, SessionArgsE2Test).
# Paths are normalised: the no-root dir -> /R (the APK's loader root has the
# same fdl/ layout), DUMP_DIR -> /D.
# Also the fake-engine check: both argvs through the real core in --dry-run.
# Usage (from no-root/): tests/menu-traces.sh [--update]
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
gold=$root/../android/app/src/test/resources/e2
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

cat > "$tmp/runner" <<R
#!/usr/bin/env bash
{ printf 'env SPDHOST_PART_XML_DIR=%s\n' "\${SPDHOST_PART_XML_DIR-}"; printf 'arg %s\n' "\$@"; } > "\$TRACE"
exit 0
R
printf '#!/bin/sh\nprintf "caps_format=1\\ncap=ops-dump\\nend\\n"\n' > "$tmp/caps"
chmod +x "$tmp/runner" "$tmp/caps"
export SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER="$tmp/runner" SPDHOST_MENU_CONFIG="$tmp/none.conf" SPDHOST_BIN="$tmp/caps"
export SPDHOST_EXEC_ADDR=0x65015f08
unset SPDHOST_TIMEOUT SPDHOST_VERBOSE SPDHOST_STEP
# shellcheck source=/dev/null
source "$root/scripts/menu.sh" >/dev/null 2>&1 || { echo "cannot source menu.sh"; exit 1; }
cls() { :; }; pause() { :; }; ready() { :; }
FDL1=$root/fdl/ums9230/infinix/fdl1-dl.bin FDL1_ADDR=0x65000800
FDL2=$root/fdl/ums9230/infinix/fdl2-dl.bin FDL2_ADDR=0x9efffe00
mkdir -p "$gold"
gcc -O2 -w -std=c11 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/plan.c" "$root/src/loaders.c" "$root/src/ops.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/events.c" \
	"$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" \
	"$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" \
	-o "$tmp/spdhost" || exit 1

trace() { # NAME CMD...
	local name=$1; shift
	DUMP_DIR=$tmp/d; rm -rf "$DUMP_DIR"; mkdir -p "$DUMP_DIR"
	export TRACE=$tmp/$name.raw; rm -f "$TRACE"
	"$@" </dev/null >"$tmp/$name.log" 2>&1
	[[ -s $TRACE ]] || { bad "$name: menu ran no session"; tail -5 "$tmp/$name.log"; return; }
	sed -e "s#$root/scripts/\.\./#$root/#g" -e "s#$DUMP_DIR#/D#g" -e "s#$root#/R#g" "$TRACE" > "$tmp/$name.trace"
	apk_of "$tmp/$name.trace" > "$tmp/$name.apk"
	if [[ ${UPDATE:-0} == 1 ]]; then
		cp "$tmp/$name.trace" "$gold/$name.trace"; cp "$tmp/$name.apk" "$gold/$name.apk"; ok "$name: goldens updated"
	else
		if cmp -s "$tmp/$name.trace" "$gold/$name.trace"; then ok "$name: menu.sh trace == golden"
		else bad "$name: menu.sh trace differs from golden"; diff "$gold/$name.trace" "$tmp/$name.trace"; fi
		if cmp -s "$tmp/$name.apk" "$gold/$name.apk"; then ok "$name: APK argv golden == normalised menu trace"
		else bad "$name: APK argv golden differs"; diff "$gold/$name.apk" "$tmp/$name.apk"; fi
	fi
	dry_same "$name"
}

# The documented menu -> APK differences (SessionArgs.kt, SessionArgsE2Test):
#  1. the menu passes the side-file folder as env SPDHOST_PART_XML_DIR; the
#     app's env whitelist strips SPDHOST_*, so it passes --part-xml DIR right
#     after the global options (not for the bare BootROM hello);
#  2. the menu's table read also reads the 32-byte misc slot record
#     (read-part misc 0x800 32 FILE); P1 sends no read-part, so that tuple is dropped.
apk_of() { # TRACE -> one arg per line
	local x a i=0 n
	local -a args=() out=()
	x=$(sed -n 's/^env SPDHOST_PART_XML_DIR=//p' "$1")
	while IFS= read -r a; do args+=("$a"); done < <(sed -n 's/^arg //p' "$1")
	n=${#args[@]}
	while (( i < n )) && [[ ${args[i]} == --* ]]; do
		out+=("${args[i]}"); [[ ${args[i]} == --timeout ]] && { i=$((i + 1)); out+=("${args[i]}"); }
		i=$((i + 1))
	done
	[[ ${args[i]} == ping ]] || out+=(--part-xml "$x")
	while (( i < n )); do
		if [[ ${args[i]} == read-part ]]; then i=$((i + 5)); continue; fi
		out+=("${args[i]}"); i=$((i + 1))
	done
	printf '%s\n' "${out[@]}"
}

# Fake engine (plan §4.1/§4.2): the real core in --dry-run (no USB, fake
# replies, DRY packet lines on stdout) gets the menu argv+env and the APK
# argv; the packet trace and the exit code must be identical.
dry_same() { # NAME
	local name=$1 d=$tmp/dry/$1 x rcm rca
	local -a m=() a=()
	rm -rf "$d"; mkdir -p "$d/D/meta"
	x=$(sed -n 's/^env SPDHOST_PART_XML_DIR=//p' "$tmp/$name.trace" | sed "s#^/D#$d/D#")
	while IFS= read -r v; do m+=("$(fix "$v" "$d")"); done < <(sed -n 's/^arg //p' "$tmp/$name.trace")
	while IFS= read -r v; do a+=("$(fix "$v" "$d")"); done < "$tmp/$name.apk"
	SPDHOST_PART_XML_DIR=$x timeout 60 "$tmp/spdhost" --dry-run "${m[@]}" >"$d/menu.out" 2>/dev/null </dev/null; rcm=$?
	env -u SPDHOST_PART_XML_DIR timeout 60 "$tmp/spdhost" --dry-run "${a[@]}" >"$d/apk.out" 2>/dev/null </dev/null; rca=$?
	if [[ $rcm == "$rca" ]] && [[ -s $d/apk.out ]] && cmp -s "$d/menu.out" "$d/apk.out"; then
		ok "$name: --dry-run packet trace APK == menu ($(grep -c '^DRY' "$d/apk.out") packets, rc $rca)"
	else
		bad "$name: --dry-run differs (rc menu $rcm apk $rca)"; diff "$d/menu.out" "$d/apk.out" | head -5
	fi
}
fix() { local v=$1; v=${v/#\/D/$2/D}; v=${v/#\/R/$root}; printf '%s' "$v"; }
[[ ${1-} == --update ]] && UPDATE=1

trace hello run_session ping
BOOT_AFTER=reset;     trace parts-reset fetch_parts_table
BOOT_AFTER=power-off; trace parts-power-off fetch_parts_table
BOOT_AFTER=reset;     trace dump-one-reset ops_dump_session boot_a
BOOT_AFTER=power-off; trace dump-one-power-off ops_dump_session boot_a
BOOT_AFTER=reset;     trace dump-all_lite-reset ops_dump_session all_lite
BOOT_AFTER=power-off; trace dump-all-power-off ops_dump_session all

echo "menu-traces: $pass passed, $fail failed"
(( fail == 0 ))
