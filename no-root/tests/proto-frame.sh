#!/usr/bin/env bash
# Receive-path framing regressions for src/proto.c, via tests/proto-frame.c
# (stubbed spd_usb_bulk_recv, so no phone and no libusb are involved).
#
# The case these exist for: a stray 0x7d before a frame's opening 0x7e used to
# poison the frame and make die() end the session. One byte of noise on the
# cable is not a reason to drop a whole read.
#
# Usage (from no-root/): tests/proto-frame.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

gcc -O2 -Wall -Wextra -std=c11 -D_FILE_OFFSET_BITS=64 -I"$root/src" -I"$root/tests" \
	"$root/tests/proto-frame.c" "$root/src/proto.c" -o "$tmp/pf" || exit 1

# clean and two-frames are the control: the frame itself must still be read,
# so a fix that simply swallows everything cannot pass.
for c in clean junk-then-esc esc-then-frame esc-esc-then-frame junk-esc-junk two-frames split-read; do
	out=$("$tmp/pf" "$c" 2>&1); rc=$?
	if (( rc == 0 )) && [[ $out == "ok $c" ]]; then
		ok "framing: $c"
	else
		bad "framing: $c (rc $rc: $out)"
	fi
done

echo
echo "proto-frame: $pass passed, $fail failed"
(( fail == 0 ))
