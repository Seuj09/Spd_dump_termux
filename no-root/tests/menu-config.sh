#!/usr/bin/env bash
# Menu config consistency (chip vs addresses) and the bounded-probe watchdog.
#
# Three defects this covers, all in scripts/menu.sh:
#
#  1. The saved config keeps SOC and the loader/exec addresses as independent
#     fields, but those addresses are a pure function of the chip. A file left
#     over from another chip -- ums9230 Infinix loaders with sc9863a's
#     0x5000/0x4ee8, the exact mix seen on this box -- used to load clean and
#     reach a session. config_chip_check() now refuses that (the loader *path*
#     is the evidence) and repairs addresses that are merely stale, and
#     need_loaders() is what stops every option until option 3 fixes it.
#  2. `[Enter]` at the manual loader prompt used to keep the previous chip's
#     SOC, which is how the mix above got written in the first place.
#  3. bounded()'s fallback: with `timeout` absent, `command -v timeout &&
#     timeout 5 cmd || cmd` runs the *unbounded* cmd -- an unbounded hang in a
#     diagnostic probe. The tests below run with `timeout` removed from PATH.
#
# Usage (from no-root/): tests/menu-config.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }
# "rc=N elapsed=S" must carry an elapsed and be within LIM seconds. The
# presence test matters: an empty or truncated capture must fail, not pass by
# comparing nothing.
within() { # OUT LIM
	local e
	[[ $1 == *elapsed=* ]] || return 1
	e=${1##*elapsed=}
	[[ $e =~ ^[0-9]+$ ]] && (( e <= $2 ))
}

# Real files with chip-naming paths: load_config only accepts paths that exist.
mkdir -p "$tmp/fdl/sc9863a/itel" "$tmp/fdl/ums9230/infinix" "$tmp/plain"
: >"$tmp/fdl/sc9863a/itel/fdl1-dl.bin"
: >"$tmp/fdl/sc9863a/itel/fdl2-dl.bin"
: >"$tmp/fdl/ums9230/infinix/fdl1-dl.bin"
: >"$tmp/fdl/ums9230/infinix/fdl2-dl.bin"
: >"$tmp/plain/fdl1.bin"
: >"$tmp/plain/fdl2.bin"
SC1=$tmp/fdl/sc9863a/itel/fdl1-dl.bin
SC2=$tmp/fdl/sc9863a/itel/fdl2-dl.bin

# Source the menu (functions only) against one config, then run the snippet.
# The snippet's stdout/stderr are the caller's to capture.
menu_run() { # CONFFILE FN [ARGS...]
	local conf=$1; shift
	(
		export SPDHOST_MENU_LIB=1 SPDHOST_MENU_CONFIG=$conf
		export SPDHOST_INPUT_DIR=$tmp/input SPDHOST_DUMP_DIR=$tmp/dump
		export SPDHOST_MENU_RUNNER=$tmp/runner
		# MENU_SH moves the menu to another tree, which is how the exec-stub
		# lookup is tested against a package that ships only one stub: that
		# lookup starts at the menu's own directory.
		# shellcheck source=/dev/null
		source "${MENU_SH:-$root/scripts/menu.sh}" >/dev/null 2>&1
		load_config
		"$@"
	)
}

# Snippets (defined here, so the subshell inherits them).
show_chip_error() { printf 'CHIPERR=%s\n' "${CONFIG_CHIP_ERROR:-}"; }
show_addrs() {
	printf 'F1=%s F2=%s EX=%s SOC=%s\n' "${FDL1_ADDR:-}" "${FDL2_ADDR:-}" "${EXEC_ADDR:-}" "${SOC:-}"
}
hex_probe() { hex_mode_menu; show_addrs; }
manual_probe() {
	configure_loaders_manual
	printf 'RESULT SOC=%s EXEC_ADDR=%s\n' "$SOC" "$EXEC_ADDR"
}
backfill_probe() {
	apply_ums9230_infinix_defaults
	show_addrs
}

cat >"$tmp/runner" <<R
#!/usr/bin/env bash
echo "SESSION" >>"$tmp/ran"
exit 0
R
chmod +x "$tmp/runner"

# ------------------------------------------------- the reproduced stale mix
# SOC says ums9230, the loaders are sc9863a's, the addresses are sc9863a's.
cat >"$tmp/stale.conf" <<EOF
FDL1=$SC1
FDL1_ADDR=0x5000
FDL2=$SC2
FDL2_ADDR=0x9efffe00
EXEC_ADDR=0x4ee8
SOC=ums9230
EOF

out=$(menu_run "$tmp/stale.conf" show_chip_error 2>&1)
check "stale mix: config_chip_check records an error" has "$out" "CHIPERR=SOC=ums9230 but the loaders are sc9863a"

out=$(menu_run "$tmp/stale.conf" need_loaders 2>&1); rc=$?
check "stale mix: need_loaders refuses (rc 1)" test "$rc" = 1
check "stale mix: refusal explains itself" has "$out" "Refusing: SOC=ums9230 but the loaders are sc9863a"
check "stale mix: refusal points at option 3" has "$out" "Option 3 re-picks the loaders"
check "stale mix: refusal names both paths" has "$out" "$SC1"

# ...and the refusal must actually stop a session, not just print.
: >"$tmp/ran"
out=$(menu_run "$tmp/stale.conf" list_partitions_menu 2>&1); rc=$?
check "stale mix: list_partitions_menu returns non-zero" test "$rc" != 0
check "stale mix: no spdhost session was started" test ! -s "$tmp/ran"
check "stale mix: the user is told why" has "$out" "Refusing:"

# The loader path is the evidence, so either path naming the wrong chip refuses.
for side in FDL1 FDL2; do
	sed "s|^$side=.*|$side=$SC1|" "$tmp/stale.conf" >"$tmp/stale2.conf"
	out=$(menu_run "$tmp/stale2.conf" show_chip_error 2>&1)
	check "stale mix: $side alone disagreeing with SOC is refused" \
		has "$out" "CHIPERR=SOC=ums9230 but the loaders are sc9863a"
done

# No chip at all in the config and no chip in the paths: nothing is refused
# and nothing is derived, because there is nothing to derive from. Hand-made
# loaders the menu knows nothing about must keep working.
cat >"$tmp/nochip.conf" <<EOF
FDL1=$tmp/plain/fdl1.bin
FDL1_ADDR=0x5000
FDL2=$tmp/plain/fdl2.bin
FDL2_ADDR=0x1234
EXEC_ADDR=0x4ee8
SOC=
EOF
out=$(menu_run "$tmp/nochip.conf" show_chip_error 2>&1)
check "no chip anywhere: config_chip_check stays silent" has "$out" "CHIPERR="
out=$(menu_run "$tmp/nochip.conf" show_addrs 2>&1)
check "no chip anywhere: the typed values stand untouched" \
	has "$out" "F1=0x5000 F2=0x1234 EX=0x4ee8 SOC="

# Two loaders from two different chips: refused, with or without an SOC.
cat >"$tmp/pairmix.conf" <<EOF
FDL1=$SC1
FDL1_ADDR=0x5000
FDL2=$tmp/fdl/ums9230/infinix/fdl2-dl.bin
FDL2_ADDR=0x9efffe00
EXEC_ADDR=0x4ee8
SOC=
EOF
out=$(menu_run "$tmp/pairmix.conf" show_chip_error 2>&1)
check "mixed pair: refused even with no SOC" \
	has "$out" "CHIPERR=FDL1 is sc9863a's and FDL2 is ums9230's"
out=$(menu_run "$tmp/pairmix.conf" need_loaders 2>&1)
check "mixed pair: need_loaders refuses" has "$out" "Refusing: FDL1 is sc9863a's and FDL2 is ums9230's"

# No SOC but a chip-named path: the path supplies the chip and the addresses
# are reconciled against it, so leaving SOC empty is not a way around the check.
cat >"$tmp/adopt.conf" <<EOF
FDL1=$SC1
FDL1_ADDR=0x65000800
FDL2=$SC2
FDL2_ADDR=0x9efffe00
EXEC_ADDR=0x65015f08
SOC=
EOF
out=$(menu_run "$tmp/adopt.conf" show_chip_error 2>&1)
check "no SOC + chip path: not an error, the path is adopted" has "$out" "CHIPERR="
out=$(menu_run "$tmp/adopt.conf" show_addrs 2>&1)
check "no SOC + chip path: ums9230's addresses become sc9863a's" \
	has "$out" "F1=0x5000 F2=0x9efffe00 EX=0x4ee8 SOC=sc9863a"
out=$(menu_run "$tmp/adopt.conf" config_chip_check 2>&1)
check "no SOC + chip path: the adoption is announced" \
	has "$out" "the loader path says these are sc9863a's, so that is the chip now"

# ------------------------------------------------------- stale addresses only
# Paths that name no chip: SOC decides, and each wrong field is replaced.
cat >"$tmp/wrongaddr.conf" <<EOF
FDL1=$tmp/plain/fdl1.bin
FDL1_ADDR=0x5000
FDL2=$tmp/plain/fdl2.bin
FDL2_ADDR=0x1234
EXEC_ADDR=0x4ee8
SOC=ums9230
EOF

out=$(menu_run "$tmp/wrongaddr.conf" show_chip_error 2>&1)
check "stale addrs: not an error, a repair" has "$out" "CHIPERR="
out=$(menu_run "$tmp/wrongaddr.conf" show_addrs 2>&1)
check "stale addrs: all three repaired to ums9230's" \
	has "$out" "F1=0x65000800 F2=0x9efffe00 EX=0x65015f08 SOC=ums9230"
out=$(menu_run "$tmp/wrongaddr.conf" config_chip_check 2>&1)
check "stale addrs: FDL1_ADDR note names the chip's value" has "$out" "is not ums9230's 0x65000800"
check "stale addrs: FDL2_ADDR note names the chip's value" has "$out" "is not ums9230's 0x9efffe00"
check "stale addrs: EXEC_ADDR note names the chip's value" has "$out" "is not ums9230's 0x65015f08"

# The alternate exec stub is this chip's too, so it must survive.
sed 's/^EXEC_ADDR=.*/EXEC_ADDR=0x65015f48/' "$tmp/wrongaddr.conf" >"$tmp/alt.conf"
out=$(menu_run "$tmp/alt.conf" show_addrs 2>&1)
check "stale addrs: the chip's alternate exec stub is kept" \
	has "$out" "EX=0x65015f48 SOC=ums9230"

# 0 / off is a deliberate "no exec stub", not a stale address.
for off in 0 off; do
	sed "s/^EXEC_ADDR=.*/EXEC_ADDR=$off/" "$tmp/wrongaddr.conf" >"$tmp/off.conf"
	out=$(menu_run "$tmp/off.conf" show_addrs 2>&1)
	check "stale addrs: EXEC_ADDR=$off stays a deliberate no-stub" \
		has "$out" "EX=$off SOC=ums9230"
done

# ------------------------------------------------- [Enter] at the chip prompt
# Previous state: ums9230 with its exec stub. Then the user types sc9863a
# loader paths and presses Enter for the chip.
cat >"$tmp/ums.conf" <<EOF
FDL1=$tmp/fdl/ums9230/infinix/fdl1-dl.bin
FDL1_ADDR=0x65000800
FDL2=$tmp/fdl/ums9230/infinix/fdl2-dl.bin
FDL2_ADDR=0x9efffe00
EXEC_ADDR=0x65015f08
SOC=ums9230
EOF

out=$(printf '%s\n' "$SC1" 0x5000 "$SC2" 0x9efffe00 "" |
	menu_run "$tmp/ums.conf" manual_probe 2>&1)
check "manual [Enter]: the chip is left unset, not carried over" has "$out" "RESULT SOC= EXEC_ADDR=0x65015f08"
check "manual [Enter]: the mixed stub is called out" has "$out" "is ums9230's stub but the loaders are sc9863a's"
soc=$(menu_run "$tmp/ums.conf" show_chip_error 2>&1) # fresh load, unaffected
check "manual [Enter]: the pre-existing config is not modified" has "$soc" "CHIPERR="
saved=$(sed -n 's/^SOC=//p' "$tmp/ums.conf")
check "manual [Enter]: the saved config carries an empty SOC (got '$saved')" test -z "$saved"
saved=$(sed -n 's/^EXEC_ADDR=//p' "$tmp/ums.conf")
check "manual [Enter]: the pinned exec stub was written (got '$saved')" test "$saved" = 0x65015f08

# And that saved config reloads clean: the path names sc9863a, so the chip is
# adopted and the ums9230 exec stub the user pinned is reconciled away. The mix
# is therefore not survivable across a reload either.
out=$(menu_run "$tmp/ums.conf" show_addrs 2>&1)
check "manual [Enter]: reload adopts the path's chip and fixes the stub" \
	has "$out" "F1=0x5000 F2=0x9efffe00 EX=0x4ee8 SOC=sc9863a"
menu_run "$tmp/ums.conf" need_loaders >/dev/null 2>&1
check "manual [Enter]: reload is usable, not refused" test $? = 0

# Choosing a chip explicitly still pins that chip's addresses.
out=$(printf '%s\n' "$SC1" 0x5000 "$SC2" 0x9efffe00 2 |
	menu_run "$tmp/ums.conf" manual_probe 2>&1)
check "manual [2]: sc9863a's own addresses are written" \
	has "$out" "RESULT SOC=sc9863a EXEC_ADDR=0x4ee8"
check "manual [2]: no cross-chip warning for a matching pair" \
	lacks "$out" "is ums9230's stub"

# Path-vs-pick disagreement is spoken, and the picked chip wins the addresses.
out=$(printf '%s\n' 1 "$SC1" 0x5000 "$SC2" 0x9efffe00 3 |
	menu_run "$tmp/ums.conf" manual_probe 2>&1)
check "manual [3]: a path/chip disagreement warns" has "$out" "the loaders are sc9863a's but you picked ums512"
check "manual [3]: the picked chip's addresses are written" \
	has "$out" "RESULT SOC=ums512 EXEC_ADDR=0x3ee8"

# ----------------------------------------- ums9230 back-fill sets a whole chip
# With no loaders set, the shipped pair is applied: chip, both addresses and
# the exec stub follow together, so a foreign chip cannot be left half-set.
cat >"$tmp/empty.conf" <<EOF
FDL1=
FDL1_ADDR=
FDL2=
FDL2_ADDR=
EXEC_ADDR=0
SOC=sc9863a
EOF

out=$(SPDHOST_ALLOW_DEFAULT_FDL=1 menu_run "$tmp/empty.conf" backfill_probe 2>&1)
check "back-fill: applies the ums9230 pair and its chip together" \
	has "$out" "F1=0x65000800 F2=0x9efffe00 EX=0x65015f08 SOC=ums9230"

# A loader already set for another chip is refused, not kept beside the pair.
cat >"$tmp/foreign.conf" <<EOF
FDL1=$SC1
FDL1_ADDR=
FDL2=$SC2
FDL2_ADDR=
EXEC_ADDR=0x4ee8
SOC=sc9863a
EOF

out=$(SPDHOST_ALLOW_DEFAULT_FDL=1 menu_run "$tmp/foreign.conf" backfill_probe 2>&1)
check "back-fill: foreign loaders are refused" has "$out" "are sc9863a loaders, not ums9230 ones"
check "back-fill: nothing was overwritten" \
	has "$out" "F1= F2= EX=0x4ee8 SOC=sc9863a"

# ---------------------------------------------------------------- bounded()
# Same test under both worlds: with `timeout` on PATH, and with it removed.
# The remove-PATH world is the one that used to hang.
mkdir -p "$tmp/nb"
for d in /usr/bin /bin; do
	[[ -d $d ]] || continue
	for f in "$d"/*; do
		b=${f##*/}
		[[ $b == timeout ]] && continue
		[[ -e $tmp/nb/$b ]] && continue
		ln -s "$f" "$tmp/nb/$b" 2>/dev/null || true
	done
done
cat >"$tmp/nb/termux-usb" <<'EOF'
#!/usr/bin/env bash
# A termux-usb that never answers, the way it does when Termux:API is missing
# or was killed by battery optimisation. exec, so the watchdog's SIGTERM to the
# pid actually reaches the sleep.
exec sleep 300
EOF
cat >"$tmp/nb/spdhost" <<'EOF'
#!/usr/bin/env bash
[[ $1 == --self-test ]] && echo "self-test ok"
exit 0
EOF
chmod +x "$tmp/nb/termux-usb" "$tmp/nb/spdhost"

# Result of one bounded() call as "rc=N elapsed=S".
bounded_probe() { # PATHVALUE T SECONDS CMD...
	local pv=$1 t=$2; shift 2
	(
		PATH=$pv
		export PATH SPDHOST_MENU_LIB=1 SPDHOST_MENU_CONFIG=$tmp/none.conf
		# shellcheck source=/dev/null
		source "$root/scripts/menu.sh" >/dev/null 2>&1
		local s=$SECONDS rc
		bounded "$t" "$@" >/dev/null 2>&1
		rc=$?
		printf 'rc=%d elapsed=%d\n' "$rc" "$((SECONDS - s))"
	)
}

for world in with without; do
	# "with" keeps the real tools plus the hanging stub; "without" is the stub
	# directory alone, so `command -v timeout` genuinely fails there.
	if [[ $world == with ]]; then pv=$tmp/nb:/usr/bin:/bin; else pv=$tmp/nb; fi
	if [[ $world == without ]] && PATH=$pv command -v timeout >/dev/null 2>&1; then
		bad "bounded/$world: \`timeout\` is still on PATH — the test proves nothing"
		continue
	fi
	# The command that used to hang: a probe that never answers.
	out=$(bounded_probe "$pv" 2 termux-usb -l)
	check "bounded/$world: a never-answering probe is killed ($out)" \
		bash -c '[[ $1 == rc=* && $1 != rc=0* ]]' _ "$out"
	check "bounded/$world: ...within the limit ($out)" within "$out" 6
	# A *failing* bounded call must not fall through to an unbounded one: with
	# `cmd || cmd` this was rc=0 after the full 30s instead of rc=1 after 2s.
	out=$(bounded_probe "$pv" 2 false)
	check "bounded/$world: a failing command keeps its rc=1 ($out)" has "$out" "rc=1"
	check "bounded/$world: ...and is not retried unbounded ($out)" within "$out" 6
	out=$(bounded_probe "$pv" 2 true)
	check "bounded/$world: a succeeding command keeps rc=0 ($out)" has "$out" "rc=0"
done

# The probe that used this pattern end to end: smoke_test, with no `timeout`.
out=$(
	PATH=$tmp/nb
	export PATH SPDHOST_MENU_LIB=1 SPDHOST_MENU_CONFIG=$tmp/none.conf
	export SPDHOST_BIN=$tmp/nb/spdhost TMPDIR=$tmp
	# shellcheck source=/dev/null
	source "$root/scripts/menu.sh" >/dev/null 2>&1
	s=$SECONDS
	smoke_test </dev/null 2>&1
	echo "elapsed=$((SECONDS - s))"
)
check "smoke_test without timeout: terminates (elapsed ${out##*elapsed=}s)" \
	has "$out" "elapsed="
check "smoke_test without timeout: bounded at 3 tries of 5s" within "$out" 30
check "smoke_test without timeout: says why it stopped" \
	has "$out" "did not answer within 5s (stopped after 3 tries)"
check "smoke_test without timeout: still reaches its summary" \
	has "$out" "Smoke test:"

# ------------------------------------------- hex mode (extra menu [9])
# The release menu's "ganti hex mode": flip exec_addr between the chip's two
# exec stubs. Both ship in this tree, so the flip works; the branch that matters
# is the one where the second stub is NOT there, because a saved alt address
# with no file behind it would fail every later session. The stub lookup starts
# at the menu's own directory, so that branch needs a package that ships one.
UMK1=$root/fdl/ums9230/infinix/fdl1-dl.bin
UMK2=$root/fdl/ums9230/infinix/fdl2-dl.bin
mkconf() { # FILE EXEC_ADDR FDL1 FDL2
	cat >"$1" <<EOF
FDL1=$3
FDL1_ADDR=0x65000800
FDL2=$4
FDL2_ADDR=0x9efffe00
EXEC_ADDR=$2
SOC=ums9230
EOF
}

mkconf "$tmp/hex-both.conf" 0x65015f08 "$UMK1" "$UMK2"
out=$(cd "$tmp" && menu_run "$tmp/hex-both.conf" hex_probe)
check "hex mode: both stubs on disk, the flip selects the second and saves it" \
	bash -c '[[ $1 == *"EX=0x65015f48"* ]] && grep -q "^EXEC_ADDR=0x65015f48$" "$2"' _ "$out" "$tmp/hex-both.conf"
out=$(cd "$tmp" && menu_run "$tmp/hex-both.conf" hex_probe)
check "hex mode: flipping again goes back to the primary and saves that" \
	bash -c '[[ $1 == *"EX=0x65015f08"* ]] && grep -q "^EXEC_ADDR=0x65015f08$" "$2"' _ "$out" "$tmp/hex-both.conf"

# A package that ships only the primary stub, loaders included, so nothing in
# the search path can turn up the second one.
mkdir -p "$tmp/pkg/scripts" "$tmp/pkg/fdl/ums9230"
cp "$root/scripts/menu.sh" "$tmp/pkg/scripts/"
cp "$UMK1" "$UMK2" "$tmp/pkg/fdl/ums9230/"
: >"$tmp/pkg/fdl/ums9230/custom_exec_no_verify_65015f08.bin"
P1=$tmp/pkg/fdl/ums9230/fdl1-dl.bin
P2=$tmp/pkg/fdl/ums9230/fdl2-dl.bin

mkconf "$tmp/hex-noalt.conf" 0x65015f08 "$P1" "$P2"
# 2>/dev/null: exec_stub_present's "missing <file>" on stderr is the expected
# refusal here, not a test failure.
out=$(cd "$tmp/pkg" && MENU_SH=$tmp/pkg/scripts/menu.sh menu_run "$tmp/hex-noalt.conf" hex_probe 2>/dev/null)
check "hex mode: no second stub in the package, the flip is refused" \
	bash -c '[[ $1 == *"Second stub is not on disk"* && $1 == *"EX=0x65015f08"* ]]' _ "$out"

mkconf "$tmp/hex-savedalt.conf" 0x65015f48 "$P1" "$P2"
out=$(cd "$tmp/pkg" && MENU_SH=$tmp/pkg/scripts/menu.sh menu_run "$tmp/hex-savedalt.conf" hex_probe 2>/dev/null)
check "hex mode: a saved alt address with no stub behind it is repaired to the primary" \
	bash -c '[[ $1 == *"Saved exec_addr 0x65015f08"* && $1 == *"EX=0x65015f08"* ]] &&
		grep -q "^EXEC_ADDR=0x65015f08$" "$2"' _ "$out" "$tmp/hex-savedalt.conf"

echo
echo "menu-config: $pass passed, $fail failed"
(( fail == 0 ))
