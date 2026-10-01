#!/usr/bin/env bash
# spdhost-usb must see every path termux-usb -l prints, including two
# devices on one JSON line. A comma-stripping parser glues those into one
# fake path and then opens the wrong node.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/spdhost" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/spdhost"

# $1 mode: new | many | pretty
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
	esac
	exit 0
fi
# -r -E -e launcher DEVICE
echo "${@: -1}" > "$USB_PICK"
exit 0
EOF
chmod +x "$tmp/termux-usb"

run_mode() {
	local mode=$1
	rm -f "$tmp/log" "$tmp/n" "$tmp/pick"
	: > "$tmp/log"
	USB_LOG=$tmp/log USB_N=$tmp/n USB_PICK=$tmp/pick USB_MODE=$mode \
	TMPDIR=$tmp PATH="$tmp:$PATH" SPD_USB_WAIT=3 SPD_USB_LIST_TIMEOUT=2 \
	SPD_USB_NOTIFY=0 SPD_WAKE_LOCK=0 \
		"$root/scripts/spdhost-usb" ping >"$tmp/out" 2>"$tmp/err" || true
}

run_mode new
if grep -qx '/dev/bus/usb/001/003' "$tmp/pick" 2>/dev/null; then
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

run_mode many
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

run_mode pretty
if grep -qx '/dev/bus/usb/001/004' "$tmp/pick" 2>/dev/null; then
	ok "pretty-printed single device is still opened"
else
	bad "pretty-printed single device is still opened"
	echo "  pick=$(cat "$tmp/pick" 2>/dev/null)"
	tail -20 "$tmp/err"
fi

echo "usb-detect: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
