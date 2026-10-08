#!/usr/bin/env bash
# P0-1: the fd behind libusb_wrap_sys_device() is closed by spdhost, exactly
# once, and only after libusb_close() on the handle that wraps it.
#
# libusb does not take ownership of a wrapped fd and libusb_close() leaves it
# open, so before this fix every successful Termux reacquire leaked one usbfs
# fd, and so did an adopt() failure inside the reacquire loop. The driver
# (tests/mock_usb_fdlife.c) links src/usb.c against a mock libusb and wraps
# close() (-Wl,--wrap=close) to see the order. Reacquire runs the real
# grab_termux() against a fake termux-usb on PATH that hands back a fresh
# temp-file fd each time, over the real SPDHOST_EMIT_SOCK socket.
#
# Usage (from no-root/): tests/usb-fd-close.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
has() { if grep -qx -- "$3" "$2"; then ok "$1"; else bad "$1"; echo "      want: $3"; fi; }
hasnt() { if grep -q -- "$3" "$2"; then bad "$1"; grep -- "$3" "$2" | sed 's/^/      got: /'; else ok "$1"; fi; }
# before NAME LOG A B: the first line matching A comes before the first matching B
before() {
	local a b
	a=$(grep -nx -- "$3" "$2" | head -1 | cut -d: -f1)
	b=$(grep -nx -- "$4" "$2" | head -1 | cut -d: -f1)
	if [[ -n $a && -n $b ]] && (( a < b )); then ok "$1"; else bad "$1 (lines ${a:-none} / ${b:-none})"; fi
}

cc=${CC:-cc}
if ! $cc -O1 -Wall -Wextra -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I"$root/src" \
	-o "$tmp/drive" "$root/src/usb.c" "$root/src/usb_list.c" "$root/tests/mock_usb_fdlife.c" \
	-Wl,--wrap=close 2>"$tmp/build.log"; then
	cat "$tmp/build.log"
	echo "usb-fd-close: build failed"
	exit 1
fi

# Fake termux-usb: -l lists one node, -h advertises -E, and
# `-r [-E] -e SELF DEV` runs SELF with a new temp-file fd 9 in TERMUX_USB_FD
# (what termux-api does with a fresh usbfs fd).
mkdir -p "$tmp/bin" "$tmp/fds"
cat >"$tmp/bin/termux-usb" <<'SH'
#!/usr/bin/env bash
case $1 in
-l) echo '["/dev/bus/usb/001/002"]'; exit 0 ;;
-h) echo 'Usage: termux-usb [-l | [-r] [-E] [-e command] [device | vendorId:productId]]'
    echo '  -E   pass the fd as TERMUX_USB_FD'; exit 0 ;;
esac
self=
while (($#)); do
	case $1 in -e) self=$2; shift 2 ;; *) shift ;; esac
done
f=$(mktemp "$MOCK_FD_DIR/fd.XXXXXX")
exec 9<>"$f"
TERMUX_USB_FD=9 exec "$self"
SH
chmod +x "$tmp/bin/termux-usb"

# run CASE [VAR=VALUE ...] -> $tmp/CASE.log
run() {
	local c=$1; shift
	: >"$tmp/fds/fd0"
	env -u SPDHOST_EMIT_SOCK -u TERMUX_USB_FD -u SPD_USB_FD -u SPDHOST_USB_BUS \
		-u MOCK_WRAP_FAIL -u MOCK_CLAIM_FAIL \
		PATH="$tmp/bin:$PATH" TMPDIR="$tmp" MOCK_FD_DIR="$tmp/fds" MOCK_FD0="$tmp/fds/fd0" \
		MOCK_CASE="${c%%.*}" "$@" timeout 60 "$tmp/drive" >"$tmp/$c.log" 2>"$tmp/$c.err"
	echo "  ($c: exit $?)" >>"$tmp/$c.err"
}
common() { # NAME LOG: no rule broken
	hasnt "$1: no violation (closed under a live handle, twice, or unknown)" "$2" '^viol '
}

echo "== normal close: libusb_close, then close(fd) once, then libusb_exit =="
L=$tmp/close.log; run close
has "the --usb-fd wrap is recorded in wrapped_fd" "$L" 'ev opened wrapped_fd=fd'
has "the initial fd is closed once, after its handle" "$L" 'rec 0 wrapped=1 libusb_closes=1 fd_closes=1 order_ok=1 open=0'
before "libusb_close comes before close(fd)" "$L" 'ev libusb_close rec=0' 'ev close rec=0'
before "close(fd) comes before libusb_exit" "$L" 'ev close rec=0' 'ev libusb_exit'
has "wrapped_fd is -1 after spd_usb_close" "$L" 'ev closed wrapped_fd=-1'
has "one record in all" "$L" 'summary recs=1 scan_handles=0 viol=0'
common close "$L"

echo "== reacquire: the old fd is closed before the grab, the new one adopted =="
L=$tmp/reacq.log; run reacq
has "reacquire succeeds" "$L" 'ev reacquire rc=0'
before "old handle closed, then the old fd, before the new wrap" "$L" 'ev libusb_close rec=0' 'ev close rec=0'
before "...and the old fd is closed before the new fd is wrapped" "$L" 'ev close rec=0' 'ev wrap rec=1 fd=.*'
has "after reacquire the old fd is closed" "$L" 'mid rec=0 open=0 current=0'
has "after reacquire the new fd is open and is u->wrapped_fd" "$L" 'mid rec=1 open=1 current=1'
has "old fd: closed once, after its handle" "$L" 'rec 0 wrapped=1 libusb_closes=1 fd_closes=1 order_ok=1 open=0'
has "new fd: closed once at spd_usb_close, after its handle" "$L" 'rec 1 wrapped=1 libusb_closes=1 fd_closes=1 order_ok=1 open=0'
has "two records" "$L" 'summary recs=2 scan_handles=0 viol=0'
common reacq "$L"

echo "== reacquire where the first wrap fails: that fd is closed, no handle to close =="
L=$tmp/reacq_wrapfail.log; run reacq_wrapfail MOCK_WRAP_FAIL=2
has "the failing wrap is the reacquired fd" "$L" 'ev wrap rec=1 fd=[0-9]* FAIL'
has "reacquire still succeeds on the next fd" "$L" 'ev reacquire rc=0'
has "the failed-wrap fd: no handle, closed once" "$L" 'rec 1 wrapped=0 libusb_closes=0 fd_closes=1 order_ok=1 open=0'
has "the next fd is current after reacquire" "$L" 'mid rec=2 open=1 current=1'
has "the initial fd is still closed once, after its handle" "$L" 'rec 0 wrapped=1 libusb_closes=1 fd_closes=1 order_ok=1 open=0'
has "the adopted fd is closed once at spd_usb_close" "$L" 'rec 2 wrapped=1 libusb_closes=1 fd_closes=1 order_ok=1 open=0'
has "three records" "$L" 'summary recs=3 scan_handles=0 viol=0'
common reacq_wrapfail "$L"

echo "== reacquire where adopt() fails on the new fd: that fd is closed after its handle =="
L=$tmp/reacq_adoptfail.log; run reacq_adoptfail MOCK_CLAIM_FAIL=2
has "adopt fails on the first reacquired fd (claim)" "$L" 'ev claim FAIL'
before "the failed adopt drops the handle, then its fd" "$L" 'ev libusb_close rec=1' 'ev close rec=1'
before "...before the next fd is wrapped" "$L" 'ev close rec=1' 'ev wrap rec=2 fd=.*'
has "reacquire succeeds on the next fd" "$L" 'ev reacquire rc=0'
has "the adopt-failed fd: closed once, after its handle" "$L" 'rec 1 wrapped=1 libusb_closes=1 fd_closes=1 order_ok=1 open=0'
has "the adopted fd is current after reacquire" "$L" 'mid rec=2 open=1 current=1'
has "the adopted fd is closed once at spd_usb_close" "$L" 'rec 2 wrapped=1 libusb_closes=1 fd_closes=1 order_ok=1 open=0'
has "three records" "$L" 'summary recs=3 scan_handles=0 viol=0'
common reacq_adoptfail "$L"

echo "== scan path (vid:pid): libusb owns the fd, spdhost closes none =="
L=$tmp/scan.log; run scan
has "open and reacquire use scan handles" "$L" 'ev open scan=1'
has "reacquire succeeds" "$L" 'ev reacquire rc=0'
has "both scan handles are libusb_close()d" "$L" 'ev libusb_close scan=1'
hasnt "no fd is wrapped" "$L" '^ev wrap rec='
hasnt "no close() on any tracked fd" "$L" '^ev close rec='
has "libusb_exit still runs" "$L" 'ev libusb_exit'
has "wrapped_fd stays -1" "$L" 'ev wrapped_fd_before_close=0'
has "no records" "$L" 'summary recs=0 scan_handles=2 viol=0'
common scan "$L"

echo "== the code says it =="
c=$root/src/usb.c
if grep -q 'wrap_sys_device owns' "$c"; then bad "the wrong ownership comment is gone"; else ok "the wrong ownership comment is gone"; fi
n=$(grep -cE '^[[:space:]]*libusb_close\(' "$c")
if [[ $n == 1 ]]; then ok "libusb_close is called in one place (drop_handle)"; else bad "libusb_close is called in one place (drop_handle), found $n"; fi

echo
echo "usb-fd-close: $pass passed, $fail failed"
(( fail == 0 ))
