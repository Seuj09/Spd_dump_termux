#!/usr/bin/env bash
# spdhost-usb and spd_dump-usb must see every path termux-usb -l prints,
# including two devices on one JSON line. A comma-stripping parser glues
# those into one fake path and then opens the wrong node.
#
# Vendor 1782 (from the listing, or from a readable sysfs) may be preferred.
# A listing with no vendor keeps the path-only rules. SPD_USB_NO_SYSFS=1 is
# the default for the path-only cases so a host's real /sys cannot change them.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

# --- picker unit checks (no wait) -------------------------------------------
# shellcheck source=../scripts/usb-pick.sh
source "$root/scripts/usb-pick.sh"
SPD_USB_NO_SYSFS=1
unset USB_SYSFS_ROOT

unit_decide() {
	local base_s=$1 text=$2 grace=${3:-0}
	USB_SAW_OTHER=0
	USB_BASE=()
	USB_GRACE=$grace
	USB_START=$SECONDS
	if [[ -n $base_s ]]; then
		usb_parse_list "$base_s"
		USB_BASE=("${USB_PATHS[@]}")
	fi
	usb_parse_list "$text"
	usb_decide
}

unit_decide '' '["/dev/bus/usb/001/002","/dev/bus/usb/001/003"]'
if [[ $USB_ACTION == fail && $USB_FAIL_KIND == many_new && ${#USB_PATHS[@]} == 2 ]]; then
	ok "two new paths with no vendor still refuse"
else
	bad "two new paths with no vendor still refuse ($USB_ACTION $USB_FAIL_KIND n=${#USB_PATHS[@]})"
fi

unit_decide '["/dev/bus/usb/001/002"]' '["/dev/bus/usb/001/002","/dev/bus/usb/001/003"]'
if [[ $USB_ACTION == take && $USB_CHOSEN == /dev/bus/usb/001/003 && $USB_TAKE_WHY == new ]]; then
	ok "one new path with no vendor is taken"
else
	bad "one new path with no vendor is taken ($USB_ACTION $USB_CHOSEN $USB_TAKE_WHY)"
fi

unit_decide '["/dev/bus/usb/001/003","/dev/bus/usb/001/003"]' '["/dev/bus/usb/001/003","/dev/bus/usb/001/003"]'
if [[ ${#USB_PATHS[@]} == 1 && $USB_ACTION == take && $USB_CHOSEN == /dev/bus/usb/001/003 && $USB_TAKE_WHY == warm ]]; then
	ok "a duplicated path counts as one warm device"
else
	bad "a duplicated path counts as one warm device (n=${#USB_PATHS[@]} $USB_ACTION $USB_CHOSEN $USB_TAKE_WHY)"
fi

unit_decide '' '[{"device_name":"/dev/bus/usb/001/003","vendor_id":6018},"/dev/bus/usb/001/002"]'
if [[ $USB_ACTION == take && $USB_CHOSEN == /dev/bus/usb/001/003 && $USB_TAKE_WHY == unisoc ]]; then
	ok "one new 1782 is taken when another new path has no vendor"
else
	bad "one new 1782 is taken when another new path has no vendor ($USB_ACTION $USB_CHOSEN $USB_TAKE_WHY)"
fi

unit_decide '' '[{"device_name":"/dev/bus/usb/001/003","vendor_id":6018},{"device_name":"/dev/bus/usb/001/004","vendor_id":1133}]'
if [[ $USB_ACTION == take && $USB_CHOSEN == /dev/bus/usb/001/003 && $USB_TAKE_WHY == unisoc && ${USB_VIDS[0]} == 1782 ]]; then
	ok "decimal 6018 is the one vendor 1782"
else
	bad "decimal 6018 is the one vendor 1782 ($USB_ACTION $USB_CHOSEN $USB_TAKE_WHY vid=${USB_VIDS[0]:-})"
fi

unit_decide '' '[{"device_name":"/dev/bus/usb/001/003","vendor_id":"0x1782"},{"device_name":"/dev/bus/usb/001/004","vendor_id":"0x1782"}]'
if [[ $USB_ACTION == fail && $USB_FAIL_KIND == many_unisoc ]]; then
	ok "two vendor 1782 paths refuse"
else
	bad "two vendor 1782 paths refuse ($USB_ACTION $USB_FAIL_KIND)"
fi

unit_decide '' '[{"vendor_id":6018,"device_name":"/dev/bus/usb/001/003"},{"vendor_id":1133,"device_name":"/dev/bus/usb/001/004"}]'
if [[ -z ${USB_VIDS[0]:-} && -z ${USB_VIDS[1]:-} && $USB_ACTION == fail && $USB_FAIL_KIND == many_new ]]; then
	ok "a vendor printed before the path is not stolen from the next device"
else
	bad "a vendor printed before the path is not stolen from the next device (vid0=${USB_VIDS[0]:-} vid1=${USB_VIDS[1]:-} $USB_ACTION)"
fi

unit_decide '' '[{"device_name":"/dev/bus/usb/001/005","vendor_id":1133}]'
if [[ $USB_ACTION == wait && ${USB_SAW_OTHER:-0} == 1 ]]; then
	ok "a lone non-1782 is left waiting"
else
	bad "a lone non-1782 is left waiting ($USB_ACTION saw=${USB_SAW_OTHER:-0})"
fi

unit_decide '[{"device_name":"/dev/bus/usb/001/003","vendor_id":6018}]' \
	'[{"device_name":"/dev/bus/usb/001/003","vendor_id":6018},{"device_name":"/dev/bus/usb/001/004","vendor_id":1133}]'
if [[ $USB_ACTION == take && $USB_CHOSEN == /dev/bus/usb/001/003 && $USB_TAKE_WHY == unisoc ]]; then
	ok "a new mouse does not steal an already attached 1782"
else
	bad "a new mouse does not steal an already attached 1782 ($USB_ACTION $USB_CHOSEN $USB_TAKE_WHY)"
fi

unit_decide '["/dev/bus/usb/001/002"]' '["/dev/bus/usb/001/002"]' 1000
if [[ $USB_ACTION == wait ]]; then
	ok "grace holds a single already-attached path"
else
	bad "grace holds a single already-attached path ($USB_ACTION $USB_CHOSEN)"
fi

# Pace: a start already older than the interval must not sleep.
pace_at=$(usb_now_ms)
usb_pace_since "$((pace_at - 5000))" 300
pace_dt=$(( $(usb_now_ms) - pace_at ))
if (( pace_dt < 200 )); then
	ok "pace sleeps only the remainder"
else
	bad "pace sleeps only the remainder (${pace_dt}ms)"
fi

# Sysfs fills a missing vendor and then the warm rule can see it.
sysroot=$(mktemp -d)
mkdir -p "$sysroot/hub" "$sysroot/phone"
printf '1\n' > "$sysroot/hub/busnum"
printf '2\n' > "$sysroot/hub/devnum"
printf '1d6b\n' > "$sysroot/hub/idVendor"
printf '1\n' > "$sysroot/phone/busnum"
printf '3\n' > "$sysroot/phone/devnum"
printf '1782\n' > "$sysroot/phone/idVendor"
SPD_USB_NO_SYSFS=0
USB_SYSFS_ROOT=$sysroot
unit_decide '["/dev/bus/usb/001/002","/dev/bus/usb/001/003"]' '["/dev/bus/usb/001/002","/dev/bus/usb/001/003"]'
if [[ $USB_ACTION == take && $USB_CHOSEN == /dev/bus/usb/001/003 && $USB_TAKE_WHY == unisoc && ${USB_VIDS[1]} == 1782 ]]; then
	ok "sysfs idVendor selects the phone when the listing has no vendor"
else
	bad "sysfs idVendor selects the phone when the listing has no vendor ($USB_ACTION $USB_CHOSEN $USB_TAKE_WHY vid1=${USB_VIDS[1]:-})"
fi
SPD_USB_NO_SYSFS=1
unit_decide '["/dev/bus/usb/001/002","/dev/bus/usb/001/003"]' '["/dev/bus/usb/001/002","/dev/bus/usb/001/003"]'
if [[ $USB_ACTION == wait && -z ${USB_VIDS[0]:-} && -z ${USB_VIDS[1]:-} ]]; then
	ok "SPD_USB_NO_SYSFS keeps two path-only devices waiting"
else
	bad "SPD_USB_NO_SYSFS keeps two path-only devices waiting ($USB_ACTION vid0=${USB_VIDS[0]:-})"
fi
rm -rf "$sysroot"
unset USB_SYSFS_ROOT
SPD_USB_NO_SYSFS=1

# --- wrapper ---------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$sysroot"' EXIT
cat > "$tmp/spdhost" << 'EOF'
#!/bin/sh
exit 0
EOF
cat > "$tmp/spd_dump" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/spdhost" "$tmp/spd_dump"

# $1 mode. USB_N counts -l calls.
cat > "$tmp/termux-usb" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$USB_LOG"
if [[ ${1:-} == -h ]]; then
	echo "usage: termux-usb [ -E ] [ -l ] [ -r ] [ -e launcher ] device"
	exit 0
fi
if [[ ${1:-} == -l ]]; then
	n=0
	[[ -f $USB_N ]] && n=$(cat "$USB_N")
	echo $((n + 1)) > "$USB_N"
	case $USB_MODE in
		new)
			if (( n == 0 )); then echo '["/dev/bus/usb/001/002"]'
			else echo '["/dev/bus/usb/001/002","/dev/bus/usb/001/003"]'
			fi
			;;
		many)
			if (( n == 0 )); then echo '[]'
			else echo '["/dev/bus/usb/001/002","/dev/bus/usb/001/003"]'
			fi
			;;
		pretty)
			if (( n == 0 )); then echo '[]'
			else printf '%s\n' '[' '  "/dev/bus/usb/001/004"' ']'
			fi
			;;
		dup)
			echo '["/dev/bus/usb/001/003","/dev/bus/usb/001/003"]'
			;;
		one1782)
			echo '[{"device_name":"/dev/bus/usb/001/002","vendor_id":1133},{"device_name":"/dev/bus/usb/001/003","vendor_id":6018}]'
			;;
		two1782)
			echo '[{"device_name":"/dev/bus/usb/001/003","vendor_id":6018},{"device_name":"/dev/bus/usb/001/004","vendor_id":6018}]'
			;;
		mouse)
			if (( n == 0 )); then echo '[]'
			else echo '[{"device_name":"/dev/bus/usb/001/005","vendor_id":1133}]'
			fi
			;;
		beside)
			if (( n == 0 )); then echo '[{"device_name":"/dev/bus/usb/001/003","vendor_id":6018}]'
			else echo '[{"device_name":"/dev/bus/usb/001/003","vendor_id":6018},{"device_name":"/dev/bus/usb/001/004","vendor_id":1133}]'
			fi
			;;
		sysfs)
			echo '["/dev/bus/usb/001/002","/dev/bus/usb/001/003"]'
			;;
	esac
	exit 0
fi
# -r -E -e launcher DEVICE
echo "${@: -1}" > "$USB_PICK"
exit 0
EOF
chmod +x "$tmp/termux-usb"

run_wrap() {
	local script=$1 mode=$2
	rm -f "$tmp/log" "$tmp/n" "$tmp/pick"
	: > "$tmp/log"
	USB_LOG=$tmp/log USB_N=$tmp/n USB_PICK=$tmp/pick USB_MODE=$mode \
	TMPDIR=$tmp PATH="$tmp:$PATH" SPD_USB_WAIT=${SPD_USB_WAIT:-3} \
	SPD_USB_LIST_TIMEOUT=2 SPD_USB_NOTIFY=0 SPD_WAKE_LOCK=0 \
	SPD_USB_NO_SYSFS=${SPD_USB_NO_SYSFS:-1} \
	USB_SYSFS_ROOT=${USB_SYSFS_ROOT:-} \
		"$script" ping >"$tmp/out" 2>"$tmp/err" || true
}

picked() { grep -qx "$1" "$tmp/pick" 2>/dev/null; }

run_wrap "$root/scripts/spdhost-usb" new
if picked /dev/bus/usb/001/003; then
	ok "new device on a shared JSON line is the one opened"
else
	bad "new device on a shared JSON line is the one opened"
	echo "  pick=$(cat "$tmp/pick" 2>/dev/null)"
	tail -20 "$tmp/err"
fi
if grep -q '001/002/dev' "$tmp/pick" 2>/dev/null; then
	bad "paths were glued"
else
	ok "paths were not glued"
fi

run_wrap "$root/spd_dump/scripts/spd_dump-usb" new
if picked /dev/bus/usb/001/003; then
	ok "spd_dump-usb opens the new path on a shared JSON line"
else
	bad "spd_dump-usb opens the new path on a shared JSON line"
	echo "  pick=$(cat "$tmp/pick" 2>/dev/null)"
	tail -20 "$tmp/err"
fi
if grep -q '001/002/dev' "$tmp/pick" 2>/dev/null; then
	bad "spd_dump-usb glued paths"
else
	ok "spd_dump-usb did not glue paths"
fi

run_wrap "$root/scripts/spdhost-usb" many
if [[ -f $tmp/pick ]]; then
	bad "two new devices must not auto-open (picked $(cat "$tmp/pick"))"
else
	ok "two new devices are not auto-opened"
fi
if grep -q 'more than one new USB device' "$tmp/err"; then
	ok "two new devices are reported"
else
	bad "two new devices are reported"
	tail -20 "$tmp/err"
fi

run_wrap "$root/scripts/spdhost-usb" pretty
if picked /dev/bus/usb/001/004; then
	ok "pretty-printed single device is still opened"
else
	bad "pretty-printed single device is still opened"
	echo "  pick=$(cat "$tmp/pick" 2>/dev/null)"
	tail -20 "$tmp/err"
fi

run_wrap "$root/scripts/spdhost-usb" dup
if picked /dev/bus/usb/001/003; then
	ok "duplicate path is opened once"
else
	bad "duplicate path is opened once"
	echo "  pick=$(cat "$tmp/pick" 2>/dev/null)"
	tail -20 "$tmp/err"
fi

run_wrap "$root/scripts/spdhost-usb" one1782
if picked /dev/bus/usb/001/003 && grep -q 'vendor 1782' "$tmp/err"; then
	ok "already-attached 1782 is opened and the other node is left"
else
	bad "already-attached 1782 is opened and the other node is left"
	echo "  pick=$(cat "$tmp/pick" 2>/dev/null)"
	tail -20 "$tmp/err"
fi

run_wrap "$root/scripts/spdhost-usb" two1782
if [[ -f $tmp/pick ]]; then
	bad "two 1782 devices must not auto-open (picked $(cat "$tmp/pick"))"
else
	ok "two 1782 devices are not auto-opened"
fi
if grep -q 'more than one Unisoc device' "$tmp/err"; then
	ok "two 1782 devices are reported"
else
	bad "two 1782 devices are reported"
	tail -20 "$tmp/err"
fi

SPD_USB_WAIT=2 run_wrap "$root/scripts/spdhost-usb" mouse
if [[ -f $tmp/pick ]]; then
	bad "a mouse must not be opened (picked $(cat "$tmp/pick"))"
else
	ok "a mouse is not opened"
fi
if grep -q 'not vendor 1782' "$tmp/err"; then
	ok "a mouse wait says it is not vendor 1782"
else
	bad "a mouse wait says it is not vendor 1782"
	tail -30 "$tmp/err"
fi
unset SPD_USB_WAIT

run_wrap "$root/scripts/spdhost-usb" beside
if picked /dev/bus/usb/001/003; then
	ok "a mouse plugged beside a 1782 does not replace it"
else
	bad "a mouse plugged beside a 1782 does not replace it"
	echo "  pick=$(cat "$tmp/pick" 2>/dev/null)"
	tail -20 "$tmp/err"
fi

# Explicit path skips the wait and the vendor filter.
rm -f "$tmp/log" "$tmp/n" "$tmp/pick"
: > "$tmp/log"
USB_LOG=$tmp/log USB_N=$tmp/n USB_PICK=$tmp/pick USB_MODE=many \
TMPDIR=$tmp PATH="$tmp:$PATH" SPD_USB_WAIT=3 SPD_USB_LIST_TIMEOUT=2 \
SPD_USB_NOTIFY=0 SPD_WAKE_LOCK=0 SPD_USB_NO_SYSFS=1 \
	"$root/scripts/spdhost-usb" /dev/bus/usb/001/009 -- ping >"$tmp/out" 2>"$tmp/err" || true
if picked /dev/bus/usb/001/009; then
	ok "an explicit path is opened as given"
else
	bad "an explicit path is opened as given"
	echo "  pick=$(cat "$tmp/pick" 2>/dev/null)"
	tail -20 "$tmp/err"
fi

# Same two paths, sysfs on: the phone is chosen. Sysfs off: they are not.
sysroot=$tmp/sysfs
mkdir -p "$sysroot/hub" "$sysroot/phone"
printf '1\n' > "$sysroot/hub/busnum"
printf '2\n' > "$sysroot/hub/devnum"
printf '1d6b\n' > "$sysroot/hub/idVendor"
printf '1\n' > "$sysroot/phone/busnum"
printf '3\n' > "$sysroot/phone/devnum"
printf '1782\n' > "$sysroot/phone/idVendor"
USB_SYSFS_ROOT=$sysroot SPD_USB_NO_SYSFS=0 run_wrap "$root/scripts/spdhost-usb" sysfs
if picked /dev/bus/usb/001/003; then
	ok "wrapper sysfs opens the phone when both were already attached"
else
	bad "wrapper sysfs opens the phone when both were already attached"
	echo "  pick=$(cat "$tmp/pick" 2>/dev/null)"
	tail -20 "$tmp/err"
fi
unset USB_SYSFS_ROOT
SPD_USB_NO_SYSFS=1 run_wrap "$root/scripts/spdhost-usb" sysfs
if [[ -f $tmp/pick ]]; then
	bad "without sysfs those two paths stay unopened (picked $(cat "$tmp/pick"))"
else
	ok "without sysfs those two paths stay unopened"
fi
unset SPD_USB_NO_SYSFS

echo "usb-detect: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
