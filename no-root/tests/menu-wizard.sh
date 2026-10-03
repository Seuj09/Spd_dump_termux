#!/usr/bin/env bash
# The first-run setup wizard: phone details and FDLs, asked once.
#
# The menu used to have no first run at all -- it just refused the shipped
# ums9230 Infinix loaders until you went to option [3] on your own. The wizard
# puts that question at the top, with the generic ums9230 set offered as
# "universal" for a phone whose model is not known.
#
# What this file pins is the guard rails around it, because every one of them
# is a way the prompt could break something that works today:
#   - a saved, complete config is never re-asked (nobody wants a prompt on
#     every launch);
#   - a non-terminal stdin never blocks: `menu.sh </dev/null` must still reach
#     the menu and exit on "Input closed" (write-seq.sh covers that path end to
#     end; this checks the wizard itself is the one that stays quiet);
#   - SPDHOST_ALLOW_DEFAULT_FDL=1 still applies the shipped ums9230 Infinix
#     pair without a prompt, exactly as it did before the wizard existed;
#   - [1] changes nothing until the typed `yes`, and [0] changes nothing at all.
#
# Usage (from no-root/): tests/menu-wizard.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
# got NAME FILE KEY EXPECTED -- one KEY=VALUE line from the wizard's report.
got() { local d=$1 f=$2 k=$3 e=$4; check "$d" test "$(sed -n "s/^$k=//p" "$f")" = "$e"; }

drive=$root/tests/pty_drive.py
uni=$root/fdl/ums9230/universal
inf=$root/fdl/ums9230/infinix
mkdir -p "$tmp/home"

# The wizard, run in a fresh shell, then one KEY=VALUE line per field into $1.
# SPDHOST_MENU_LIB=1 is what stops the source from starting the whole menu.
cat >"$tmp/wiz.sh" <<R
#!/usr/bin/env bash
source "$root/scripts/menu.sh" >/dev/null 2>&1
load_config
setup_wizard
{
	printf 'SOC=%s\n' "\${SOC:-}"
	printf 'DEVICE=%s\n' "\${DEVICE:-}"
	printf 'FDL1=%s\n' "\${FDL1:-}"
	printf 'FDL1_ADDR=%s\n' "\${FDL1_ADDR:-}"
	printf 'FDL2=%s\n' "\${FDL2:-}"
	printf 'FDL2_ADDR=%s\n' "\${FDL2_ADDR:-}"
	printf 'EXEC_ADDR=%s\n' "\${EXEC_ADDR:-}"
} > "\$1"
R
chmod +x "$tmp/wiz.sh"

# On a pty, because the wizard only asks when stdin is a terminal: EXPECT SEND
# pairs against the two prompts it draws.
wiz_pty() {
	local out=$1 res=$2; shift 2
	rm -f "$res"
	env HOME="$tmp/home" SPDHOST_MENU_CONFIG="$tmp/conf" SPDHOST_MENU_LIB=1 \
		SPDHOST_MENU_RUNNER=/bin/true \
		python3 "$drive" "$out" "$@" -- "bash $tmp/wiz.sh $res"
	cat "$out"
}

echo "== [1] universal: the whole ums9230 set moves together =="
rm -f "$tmp/conf" "$tmp/res"
out=$(wiz_pty "$tmp/w1.pty" "$tmp/res" \
	"Choice [1]: " '\r' "universal loaders: " 'yes\r')
check "[wizard] the prompt offers universal first" bash -c '[[ $1 == *"[1] universal"* ]]' _ "$out"
check "[wizard] the prompt prints the current state" bash -c '[[ $1 == *"now: no loaders set"* ]]' _ "$out"
got "[wizard] [1] sets the chip" "$tmp/res" SOC ums9230
got "[wizard] [1] names the model universal" "$tmp/res" DEVICE universal
got "[wizard] [1] points FDL1 at the shipped universal loader" "$tmp/res" FDL1 "$uni/fdl1-dl.bin"
got "[wizard] [1] points FDL2 at the shipped universal loader" "$tmp/res" FDL2 "$uni/fdl2-dl.bin"
got "[wizard] [1] sets the ums9230 FDL1 address" "$tmp/res" FDL1_ADDR 0x65000800
got "[wizard] [1] sets the ums9230 FDL2 address" "$tmp/res" FDL2_ADDR 0x9efffe00
got "[wizard] [1] sets the ums9230 exec stub" "$tmp/res" EXEC_ADDR 0x65015f08
check "[wizard] [1] saves the choice" grep -q '^DEVICE=universal$' "$tmp/conf"
check "[wizard] [1] saves the loader path" grep -q "^FDL1=$uni/fdl1-dl.bin\$" "$tmp/conf"

echo
echo "== nothing is applied without the typed yes =="
rm -f "$tmp/conf" "$tmp/res"
out=$(wiz_pty "$tmp/w2.pty" "$tmp/res" \
	"Choice [1]: " '\r' "universal loaders: " 'no\r')
check "[wizard] declining the confirm says nothing was applied" \
	bash -c '[[ $1 == *"menu: not confirmed"* ]]' _ "$out"
got "[wizard] a declined confirm leaves SOC unset" "$tmp/res" SOC ""
got "[wizard] a declined confirm leaves the loader unset" "$tmp/res" FDL1 ""
check "[wizard] a declined confirm writes no config" test ! -e "$tmp/conf"

echo
echo "== [0] skip leaves everything alone =="
rm -f "$tmp/conf" "$tmp/res"
out=$(wiz_pty "$tmp/w3.pty" "$tmp/res" "Choice [1]: " '0\r')
check "[wizard] [0] says the menu can set it later" \
	bash -c '[[ $1 == *"sets the loaders later"* ]]' _ "$out"
got "[wizard] [0] leaves SOC unset" "$tmp/res" SOC ""
check "[wizard] [0] writes no config" test ! -e "$tmp/conf"

echo
echo "== it asks once, and never on a non-terminal =="
# A complete saved config: this is every run after the first.
{
	printf 'SOC=ums9230\n'
	printf 'DEVICE=infinix\n'
	printf 'FDL1=%s\n' "$inf/fdl1-dl.bin"
	printf 'FDL1_ADDR=0x65000800\n'
	printf 'FDL2=%s\n' "$inf/fdl2-dl.bin"
	printf 'FDL2_ADDR=0x9efffe00\n'
	printf 'EXEC_ADDR=0x65015f08\n'
} >"$tmp/conf"
out=$(env HOME="$tmp/home" SPDHOST_MENU_CONFIG="$tmp/conf" SPDHOST_MENU_LIB=1 \
	SPDHOST_MENU_RUNNER=/bin/true bash "$tmp/wiz.sh" "$tmp/res" </dev/null 2>&1)
check "[wizard] a complete config draws no prompt" \
	bash -c '[[ $1 != *"Which loaders"* ]]' _ "$out"
got "[wizard] and the saved model is kept" "$tmp/res" DEVICE infinix
got "[wizard] and the saved chip is kept" "$tmp/res" SOC ums9230

# No config, no terminal: the menu has to reach its main loop and quit on EOF.
rm -f "$tmp/conf" "$tmp/res"
out=$(env HOME="$tmp/home" SPDHOST_MENU_CONFIG="$tmp/conf" SPDHOST_MENU_LIB=1 \
	SPDHOST_MENU_RUNNER=/bin/true bash "$tmp/wiz.sh" "$tmp/res" </dev/null 2>&1)
check "[wizard] no stdin at all draws no prompt" \
	bash -c '[[ $1 != *"Which loaders"* ]]' _ "$out"
got "[wizard] and sets nothing" "$tmp/res" SOC ""

echo
echo "== SPDHOST_ALLOW_DEFAULT_FDL=1 still applies the Infinix pair silently =="
rm -f "$tmp/conf" "$tmp/res"
env HOME="$tmp/home" SPDHOST_MENU_CONFIG="$tmp/conf" SPDHOST_MENU_LIB=1 \
	SPDHOST_MENU_RUNNER=/bin/true SPDHOST_ALLOW_DEFAULT_FDL=1 \
	bash "$tmp/wiz.sh" "$tmp/res" </dev/null >"$tmp/allow.out" 2>&1
check "[wizard] the default pair is announced on stderr" \
	grep -q 'SPDHOST_ALLOW_DEFAULT_FDL=1' "$tmp/allow.out"
got "[wizard] the default path picks the Infinix FDL1" "$tmp/res" FDL1 "$inf/fdl1-dl.bin"
got "[wizard] the default path picks the Infinix FDL2" "$tmp/res" FDL2 "$inf/fdl2-dl.bin"
got "[wizard] the default path keeps the ums9230 chip" "$tmp/res" SOC ums9230
got "[wizard] the default path leaves the model unset" "$tmp/res" DEVICE ""

echo
echo "menu-wizard: $pass passed, $fail failed"
(( fail == 0 ))
