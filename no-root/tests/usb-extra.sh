#!/usr/bin/env bash
# The BootROM path must send what the vendor reference sends — nothing more.
#
# src/usb.c grew three pieces of extra traffic that spd_dump/common.c never
# sends: CLEAR_FEATURE(ENDPOINT_HALT) on both bulk endpoints, SET_CONFIGURATION
# when the device reports config 0, and a zero-length OUT packet after any
# transfer that fills a 512-byte packet. All three came from a diagnostics
# experiment that was marked "no merge" and never proven on hardware, and all
# three had ended up on by default — two control transfers and a stray URB
# inserted between the phone being detected and the first hello, which is
# exactly where the reported "device leaves the bus / every transfer times
# out" failures live.
#
# Each is now off unless its SPDHOST_* variable asks for it, and that is what
# this guards: not just the values, but that the opt-ins still work, so a
# future change cannot quietly make them unconditional again.
#
# Usage (from no-root/): tests/usb-extra.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
# has NAME LOG PATTERN / hasnt NAME LOG PATTERN
has() { if grep -q -- "$3" "$2"; then ok "$1"; else bad "$1"; fi; }
hasnt() { if grep -q -- "$3" "$2"; then bad "$1"; else ok "$1"; fi; }

cc=${CC:-cc}
$cc -O1 -Wall -Wextra -std=c11 -D_FILE_OFFSET_BITS=64 -I"$root/src" \
	-o "$tmp/drive" "$root/src/usb.c" "$root/src/usb_list.c" \
	"$root/tests/mock_usb_layer.c" \
	|| { echo "usb-extra: build failed"; exit 1; }

# run NAME [VAR=VALUE ...] -- one log per call.
run() {
	local log=$1; shift
	: > "$log"
	env -u SPDHOST_CLEAR_HALT -u SPDHOST_NO_CLEAR_HALT -u SPDHOST_SEND_ZLP \
		-u SPDHOST_SET_CONFIG USB_LOG="$log" "$@" "$tmp/drive" >/dev/null 2>&1
}

echo "== the vendor's byte stream is the default =="
log=$tmp/default.log
run "$log"
has "the descriptor mps is the 512 the ZLP rule keys off" "$log" '^mps in=512 out=512$'
has "line-state is still sent (it is not extra traffic)" "$log" '^control rt=0x21 r=34 wv=0x601'
hasnt "no CLEAR_FEATURE by default" "$log" 'clear_halt'
hasnt "no GET_CONFIGURATION by default" "$log" 'get_config'
hasnt "no SET_CONFIGURATION by default" "$log" 'set_config'
hasnt "no zero-length OUT packet by default" "$log" 'bulk ep=0x01 len=0$'
has "a transfer that fills a packet is sent once" "$log" '^bulk ep=0x01 len=512$'
has "a partial transfer is still sent" "$log" '^bulk ep=0x01 len=100$'

echo "== each opt-in still turns its own extra traffic back on =="
log=$tmp/clear.log
run "$log" SPDHOST_CLEAR_HALT=1
has "SPDHOST_CLEAR_HALT=1 sends CLEAR_FEATURE on the IN endpoint" "$log" 'clear_halt ep=0x81'
has "SPDHOST_CLEAR_HALT=1 sends CLEAR_FEATURE on the OUT endpoint" "$log" 'clear_halt ep=0x01'
hasnt "SPDHOST_CLEAR_HALT=1 does not also turn the ZLP back on" "$log" '^bulk ep=0x01 len=0$'

log=$tmp/no.clear.log
run "$log" SPDHOST_CLEAR_HALT=1 SPDHOST_NO_CLEAR_HALT=1
hasnt "SPDHOST_NO_CLEAR_HALT=1 wins over a global SPDHOST_CLEAR_HALT=1" "$log" 'clear_halt'

log=$tmp/zlp.log
run "$log" SPDHOST_SEND_ZLP=1
has "SPDHOST_SEND_ZLP=1 sends the zero-length packet" "$log" '^bulk ep=0x01 len=0$'
has "…right after the packet that filled the 512-byte pipe" "$log" '^bulk ep=0x01 len=512$'
hasnt "SPDHOST_SEND_ZLP=1 does not also turn CLEAR_FEATURE back on" "$log" 'clear_halt'

log=$tmp/setcfg.log
run "$log" SPDHOST_SET_CONFIG=1
has "SPDHOST_SET_CONFIG=1 reads the configuration" "$log" 'get_config'
has "SPDHOST_SET_CONFIG=1 writes configuration 1 when it reads 0" "$log" 'set_config 1'
hasnt "SPDHOST_SET_CONFIG=1 does not also turn CLEAR_FEATURE back on" "$log" 'clear_halt'

log=$tmp/off.log
run "$log" SPDHOST_CLEAR_HALT=0 SPDHOST_SEND_ZLP=0 SPDHOST_SET_CONFIG=0
hasnt "=0 means off, like unset" "$log" 'clear_halt'
hasnt "=0 means off for the ZLP too" "$log" '^bulk ep=0x01 len=0$'

echo "== and the hooks are on the BootROM path only =="
# If the extra traffic is reached from anywhere but spd_brom_after_line_state()
# (the one hook this test drives), the default-off gate protects a path the
# test never exercised.
n=$(grep -c 'spd_usb_clear_halts(&io->usb)' "$root/src/proto.c" || true)
check "clear_halts is called from exactly one place, in proto.c" test "${n:-0}" = 1
check "and not from the FDL1/FDL2 code in main.c" \
	test "$(grep -c 'spd_usb_clear_halts' "$root/src/main.c" || true)" = 0

echo
echo "usb-extra: $pass passed, $fail failed"
(( fail == 0 ))
