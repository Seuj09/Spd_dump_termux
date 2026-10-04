#!/usr/bin/env bash
# L4: usb_list.c (spdhost) and usb-pick.sh (the wrappers) must read the vendor
# out of a termux-usb listing the same way. Each listing below goes through
# both, and the two answers must be equal and equal the expected one:
#   - the key starts at a [^A-Za-z0-9_] boundary (x_vendor_id is not it);
#   - 0x1782 and a QUOTED "1782" are hex; an unquoted 6018 is decimal.
# Usage (from no-root/): tests/usb-vendor-agree.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
cc=${CC:-cc}

cat >"$tmp/vid.c" <<'C'
#include "usb_list.h"
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv)
{
	struct spd_usb_dev d[4];
	int n;
	if (argc < 2)
		return 2;
	memset(d, 0, sizeof(d));
	n = spd_usb_collect_devs(argv[1], d, 4, 0);
	if (n >= 1 && d[0].has_vid)
		printf("%x\n", d[0].vid);
	else
		printf("-\n");
	return 0;
}
C
if ! $cc -O1 -std=c11 -D_FILE_OFFSET_BITS=64 -I"$root/src" -o "$tmp/vid" "$tmp/vid.c" "$root/src/usb_list.c"; then
	echo "FAIL: driver failed to compile"
	echo "usb-vendor-agree: 0 passed, 1 failed"
	exit 1
fi
# shellcheck source=../scripts/usb-pick.sh
source "$root/scripts/usb-pick.sh"

P='"device_name":"/dev/bus/usb/001/003"'
cases=(
	"1782|unquoted decimal 6018 is 1782|[{$P,\"vendor_id\":6018}]"
	"1782|quoted 0x1782 is hex|[{$P,\"vendor_id\":\"0x1782\"}]"
	"1782|a bare quoted \"1782\" is hex, not decimal 1782 (0x6f6)|[{$P,\"vendor_id\":\"1782\"}]"
	"17e1|a quoted hex id with letters is read whole|[{$P,\"vendor_id\":\"17e1\"}]"
	"46d|unquoted decimal 1133 is 46d|[{$P,\"vendor_id\":1133}]"
	"-|x_vendor_id is another key, not vendor_id|[{$P,\"x_vendor_id\":6018}]"
	"-|xvendor_id is another key, not vendor_id|[{$P,\"xvendor_id\":6018}]"
	"1782|x_vendor_id is skipped and the real vendor_id after it is read|[{$P,\"x_vendor_id\":1133,\"vendor_id\":6018}]"
	"-|a null vendor is no vendor|[{$P,\"vendor_id\":null,\"product_id\":6018}]"
)
for c in "${cases[@]}"; do
	want=${c%%|*}; rest=${c#*|}; what=${rest%%|*}; text=${rest#*|}
	cv=$("$tmp/vid" "$text")
	win=$(usb_vendor_window "${text#*/dev/bus/usb/001/003}")
	sv=$(usb_vid_in "$win"); [[ -n $sv ]] || sv=-
	if [[ $cv == "$want" && $sv == "$want" ]]; then
		ok "$what (C $cv, sh $sv)"
	else
		bad "$what (want $want; C $cv, sh $sv)"
	fi
done
echo "usb-vendor-agree: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
