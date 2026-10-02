#!/usr/bin/env bash
# Where the flash and dump folders live.
#
# On a phone the images a user has are on shared storage (/sdcard), and Termux
# cannot see any of it until termux-setup-storage has been run and allowed. So
# the menu picks the folders from SPDHOST_* overrides first, then STORAGE=
# (package / shared / auto), then the package's own input/ and backup/. The
# failure this guards is a menu that silently writes dumps somewhere the user
# cannot open with a file manager, or that points at /sdcard when the
# permission was never granted and then cannot write at all.
#
# No phone is needed: every case is a directory the test creates, and
# SPDHOST_SHARED_DIR names the only path the probe is allowed to consider --
# pointing it at a path that does not exist is how a case says "this phone has
# no shared storage".
#
# Usage (from no-root/): tests/menu-storage.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
# line_eq NAME OUTPUT LINE EXPECTED -- one line of the probe's output.
line_eq() { local d=$1 o=$2 n=$3 e=$4; check "$d" test "$(sed -n "${n}p" <<<"$o")" = "$e"; }

drive=$root/tests/pty_drive.py
share=$tmp/share
pkg=$tmp/pkg
bin=$tmp/bin
mkdir -p "$share" "$pkg" "$bin" "$tmp/home"
cp "$root/scripts/menu.sh" "$root/scripts/spdhost-usb" "$bin/"

# Probe the resolution the menu does at startup, in a fresh shell, and print
# three lines: INPUT_DIR, DUMP_DIR, storage_describe.
probe() {
	# SPDHOST_MENU_RUNNER: sourcing under `bash -c` leaves $0 as "_", so the
	# menu would look for the wrapper in the cwd. This probe only asks about
	# paths, and the hook is the documented way to skip the USB layer.
	env HOME="$tmp/home" SPDHOST_MENU_CONFIG="$tmp/conf" SPDHOST_MENU_LIB=1 \
		SPDHOST_MENU_RUNNER=/bin/true "$@" \
		bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
			load_config; apply_storage_mode
			printf "%s\n%s\n%s\n" "$INPUT_DIR" "$DUMP_DIR" "$(storage_describe)"' _ "$root"
}

# ---------------------------------------------------------------- resolution
echo "== which layout each setting picks =="
out=$(cd "$pkg" && probe SPDHOST_SHARED_DIR="$share")
line_eq "shared storage visible -> input under <share>/spdhost" "$out" 1 "$share/spdhost/input"
line_eq "shared storage visible -> dump under <share>/spdhost" "$out" 2 "$share/spdhost/backup"
line_eq "the header says which layout is in use" "$out" 3 "shared storage ($share/spdhost)"

out=$(cd "$pkg" && probe SPDHOST_SHARED_DIR=/nonexistent)
line_eq "no shared storage -> package input/" "$out" 1 "$pkg/input"
line_eq "no shared storage -> package backup/" "$out" 2 "$pkg/backup"

out=$(cd "$pkg" && probe SPDHOST_SHARED_DIR="$share" SPDHOST_STORAGE=package)
line_eq "STORAGE=package stays in the package even with shared storage there" "$out" 1 "$pkg/input"
line_eq "STORAGE=package is named in the header" "$out" 3 "package folders (STORAGE=package)"

out=$(cd "$pkg" && probe SPDHOST_SHARED_DIR="$share" SPDHOST_INPUT_DIR="$tmp/mine")
line_eq "SPDHOST_INPUT_DIR overrides shared storage" "$out" 1 "$tmp/mine"
line_eq "with an override the header says so" "$out" 3 "set by SPDHOST_INPUT_DIR / SPDHOST_DUMP_DIR"

# STORAGE=shared is the "call me out" mode: the folders fall back, and the
# reason has to reach the user or they will wonder where the files went.
note=$(cd "$pkg" && probe SPDHOST_SHARED_DIR=/nonexistent SPDHOST_STORAGE=shared 2>&1 >/dev/null)
out=$(cd "$pkg" && probe SPDHOST_SHARED_DIR=/nonexistent SPDHOST_STORAGE=shared 2>/dev/null)
line_eq "STORAGE=shared with none visible falls back to the package" "$out" 1 "$pkg/input"
check "STORAGE=shared says shared storage is not visible" bash -c '[[ $1 == *"cannot see shared storage"* ]]' _ "$note"
check "STORAGE=shared tells the user to run termux-setup-storage" bash -c '[[ $1 == *"termux-setup-storage"* ]]' _ "$note"
check "the header keeps the STORAGE=shared request visible" bash -c '[[ $1 == *"STORAGE=shared"* ]]' _ "$(sed -n 3p <<<"$out")"

# A saved config picks the layout; a nonsense value is ignored, not obeyed.
printf 'STORAGE=package\n' >"$tmp/conf"
out=$(cd "$pkg" && probe SPDHOST_SHARED_DIR="$share")
line_eq "STORAGE=package from the config is honoured" "$out" 1 "$pkg/input"
printf 'STORAGE=/etc\n' >"$tmp/conf"
out=$(cd "$pkg" && probe SPDHOST_SHARED_DIR="$share")
line_eq "an unknown STORAGE value is ignored (not used as a path)" "$out" 1 "$share/spdhost/input"
printf 'STORAGE=auto\n' >"$tmp/conf"
out=$(cd "$pkg" && probe SPDHOST_STORAGE=package SPDHOST_SHARED_DIR="$share")
line_eq "SPDHOST_STORAGE wins over the saved config" "$out" 1 "$pkg/input"
rm -f "$tmp/conf"

# The folders have to exist by the time the first prompt is drawn, or a dump
# fails at the first write. This runs the real menu, not the sourced library.
cd "$pkg" || exit 1
env HOME="$tmp/home" SPDHOST_MENU_CONFIG="$tmp/conf" SPDHOST_SHARED_DIR="$share" \
	bash "$bin/menu.sh" </dev/null >"$tmp/menu.out" 2>&1
check "starting the menu creates <share>/spdhost/input" test -d "$share/spdhost/input"
check "starting the menu creates <share>/spdhost/backup" test -d "$share/spdhost/backup"
check "the menu header names the folder layout" bash -c '[[ $1 == *"Folders: shared storage"* ]]' _ "$(cat "$tmp/menu.out")"
check "the menu header names the flash folder it will read" bash -c '[[ $1 == *"Flash input: $2/spdhost/input"* ]]' _ "$(cat "$tmp/menu.out")" "$share"

# ------------------------------------------------------------- extra [15]
# The switch has to change the paths in this session and record the choice.
rm -f "$tmp/conf"
run_switch() {
	local reply=$1
	cat >"$tmp/fn.sh" <<R
#!/usr/bin/env bash
source "$root/scripts/menu.sh" >/dev/null 2>&1
load_config
apply_storage_mode
storage_switch_menu
R
	chmod +x "$tmp/fn.sh"
	env HOME="$tmp/home" SPDHOST_MENU_CONFIG="$tmp/conf" SPDHOST_SHARED_DIR="$share" \
		SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true \
		python3 "$drive" "$tmp/switch.pty" "Choice: " "$reply" -- \
		"bash $tmp/fn.sh" </dev/null
	cat "$tmp/switch.pty"
}

out=$(run_switch '2\r')
check "[15] switching to the package folders saves STORAGE=package" grep -q '^STORAGE=package$' "$tmp/conf"
check "[15] the switch prints the new flash folder" bash -c '[[ $1 == *"Flash folder: $2/input"* ]]' _ "$out" "$pkg"
check "[15] the switch prints the new dump folder" bash -c '[[ $1 == *"Dump folder:  $2/backup"* ]]' _ "$out" "$pkg"
check "[15] the switch created the package folders" test -d "$pkg/input"

out=$(run_switch '1\r')
check "[15] switching back to shared storage saves STORAGE=shared" grep -q '^STORAGE=shared$' "$tmp/conf"
check "[15] the switch prints the shared flash folder" bash -c '[[ $1 == *"Flash folder: $2/spdhost/input"* ]]' _ "$out" "$share"

# On a phone with no storage permission, [1] must say what to run, not offer
# a folder that cannot be created.
out=$(run_switch '1\r')   # run_switch always uses $share; this one is the note path
cat >"$tmp/fn2.sh" <<R
#!/usr/bin/env bash
source "$root/scripts/menu.sh" >/dev/null 2>&1
load_config
apply_storage_mode
storage_switch_menu
R
chmod +x "$tmp/fn2.sh"
env HOME="$tmp/home" SPDHOST_MENU_CONFIG="$tmp/conf" SPDHOST_SHARED_DIR=/nonexistent \
	SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true \
	python3 "$drive" "$tmp/switch2.pty" "Choice: " '1\r' -- \
	"bash $tmp/fn2.sh" </dev/null
out=$(cat "$tmp/switch2.pty")
check "[15] with no shared storage it says to run termux-setup-storage" bash -c '[[ $1 == *"termux-setup-storage"* ]]' _ "$out"

echo
echo "menu-storage: $pass passed, $fail failed"
(( fail == 0 ))
