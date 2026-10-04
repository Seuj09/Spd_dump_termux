#!/usr/bin/env bash
# Compile and run the usb_list picker checks. CI only executes tests/*.sh.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
cc=${CC:-cc}

if ! $cc -O1 -Wall -Wextra -Wno-format-truncation -Werror=implicit-function-declaration -std=c11 \
	-D_FILE_OFFSET_BITS=64 -I"$root/src" \
	-o "$tmp/usb-list-test" "$root/tests/usb-list-test.c" "$root/src/usb_list.c"
then
	echo "FAIL: usb-list-test failed to compile"
	echo "usb-list: 0 passed, 1 failed"
	exit 1
fi

out=$("$tmp/usb-list-test") || true
printf '%s\n' "$out"
pass=$(printf '%s\n' "$out" | grep -c '^PASS:' || true)
fail=$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)
echo "usb-list: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
