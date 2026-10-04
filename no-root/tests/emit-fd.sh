#!/usr/bin/env bash
# The descriptor hand-off that reacquire depends on.
#
# After a loader reset spdhost re-execs itself as the termux-usb launcher with
# SPDHOST_EMIT_SOCK set, and spd_usb_emit_fd() sends the reopened USB
# descriptor back over that socket. The launcher gets the descriptor one of
# two ways: TERMUX_USB_FD (termux-usb -E), or, on a termux-api that predates
# -E, as its own argv[1] — the same two-form contract the wrapper's generated
# launcher already honours with ${TERMUX_USB_FD:-${1:-}}.
#
# spd_usb_emit_fd() used to read only the environment variable, and the child
# it is spawned by hardcoded -E, so on an older termux-api reacquire could
# never succeed: the device stayed gone and every later transfer timed out on
# a dead handle. Both halves are checked here, along with the refusals.
#
# Usage (from no-root/): tests/emit-fd.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# Build the binary this checks rather than depend on the suite order (it used
# to exit 1 when it ran before anything had run make). No compiler or no
# libusb headers is a clean skip, not a failure.
bin=$root/spdhost
if ! make -C "$root" -q spdhost >/dev/null 2>&1; then
	if ! make -C "$root" spdhost >"$tmp/make.log" 2>&1; then
		echo "skip  spdhost could not be built here (see make output below); emit-fd not run"
		tail -5 "$tmp/make.log"
		echo "emit-fd: 0 passed, 0 failed, 1 skipped"
		exit 0
	fi
fi
if [[ ! -x $bin ]]; then
	echo "skip  $bin is missing after make; emit-fd not run"
	echo "emit-fd: 0 passed, 0 failed, 1 skipped"
	exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
	echo "skip  python3 is not installed (the fixture is a python script); emit-fd not run"
	echo "emit-fd: 0 passed, 0 failed, 1 skipped"
	exit 0
fi

# run LABEL [VAR=VALUE ...] -- CHILD_ARGS...
# Leaves the fixture's JSON in $out and the socket path in $sock.
out= sock=
run() {
	local label=$1; shift
	local -a envs=()
	while [[ ${1:-} != -- ]]; do envs+=("$1"); shift; done
	shift
	sock=$tmp/$label.sock
	out=$tmp/$label.json
	env -u TERMUX_USB_FD -u SPD_USB_FD EMIT_FD_ACCEPT_TIMEOUT=2 \
		"${envs[@]}" python3 "$root/tests/emit-fd-fixture.py" "$sock" "$out" \
		-- "$bin" "$@"
}
jq_get() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(v[sys.argv[2]])' "$1" "$2"; }

# Two descriptors with different targets, so forwarding the wrong one (or the
# right number of a closed one) is visible. bash keeps these inheritable.
exec 7</dev/null
exec 8</dev/zero

echo "== the environment variable still wins when both are present =="
run env TERMUX_USB_FD=7 -- 8
check "TERMUX_USB_FD is preferred over argv[1]" \
	test "$(jq_get "$out" target)" = /dev/null
check "…and the child exits cleanly" test "$(jq_get "$out" rc)" = 0

echo "== the legacy argv[1] form works, which is what broke reacquire =="
run argv -- 7
check "a descriptor passed only as argv[1] is forwarded" \
	test "$(jq_get "$out" connected)" = True
check "…and it is the descriptor we opened, not another one" \
	test "$(jq_get "$out" target)" = /dev/null
check "…and the child exits cleanly" test "$(jq_get "$out" rc)" = 0

echo "== the SPD_USB_FD alias still works =="
run alias SPD_USB_FD=7 -- 8
check "SPD_USB_FD alone is accepted" test "$(jq_get "$out" target)" = /dev/null

echo "== refusals: a bad descriptor must not be forwarded =="
run closed TERMUX_USB_FD=99 -- 7
check "a descriptor that is not open is refused" \
	test "$(jq_get "$out" rc)" != 0
check "…with an explanation, not a silent failure" \
	bash -c 'grep -qi "not open" "$1"' _ "$out"
check "…and nothing is sent over the socket" \
	test "$(jq_get "$out" connected)" = False

run zero TERMUX_USB_FD=0 -- 7
check "descriptor 0 is refused (that is stdin, not a device)" \
	test "$(jq_get "$out" rc)" != 0

run junk TERMUX_USB_FD=abc -- 7
check "a non-numeric descriptor is refused" test "$(jq_get "$out" rc)" != 0

run none -- notanumber
check "no descriptor anywhere is refused" test "$(jq_get "$out" rc)" != 0
check "…naming both sources it looked at" \
	bash -c 'grep -q "TERMUX_USB_FD" "$1"' _ "$out"

echo
echo "emit-fd: $pass passed, $fail failed"
(( fail == 0 ))
