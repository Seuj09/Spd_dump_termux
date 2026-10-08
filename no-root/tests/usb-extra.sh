#!/usr/bin/env bash
# The BootROM path must send what the known-good build sends.
#
# src/usb.c carries three pieces of extra traffic that spd_dump/common.c does
# not send: CLEAR_FEATURE(ENDPOINT_HALT) on both bulk endpoints, a
# SET_CONFIGURATION when the device reports config 0, and a zero-length OUT
# packet after any transfer that fills a 512-byte packet. A previous change
# reasoned from the vendor reference and turned all three OFF by default.
# Every release after that detected the phone and then timed out, while
# spdhost-exp-write-a6cb72d — which sends all three — worked.
#
# So the default here is the known-good build's: all three on. Each has a
# kill switch (SPDHOST_NO_CLEAR_HALT / SPDHOST_NO_SET_CONFIG /
# SPDHOST_NO_SEND_ZLP) for A/B testing on a host that dislikes one, and this
# suite pins both the default and the switch, so a future change cannot
# silently flip either.
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

# run NAME [VAR=VALUE ...] -- one log per call. Every kill switch is cleared
# first so a stray export in the test environment cannot decide an assertion.
run() {
	local log=$1; shift
	: > "$log"
	env -u SPDHOST_NO_CLEAR_HALT -u SPDHOST_NO_SET_CONFIG -u SPDHOST_NO_SEND_ZLP \
		USB_LOG="$log" "$@" "$tmp/drive" >/dev/null 2>&1
}

echo "== the known-good build's traffic is the default =="
log=$tmp/default.log
run "$log"
has "the descriptor mps is the 512 the ZLP rule keys off" "$log" '^mps in=512 out=512$'
has "line-state is still sent" "$log" '^control rt=0x21 r=34 wv=0x601'
has "CLEAR_FEATURE is sent on the IN endpoint" "$log" 'clear_halt ep=0x81'
has "CLEAR_FEATURE is sent on the OUT endpoint" "$log" 'clear_halt ep=0x01'
has "the configuration is read" "$log" '^get_config$'
has "configuration 1 is written when 0 is read" "$log" '^set_config 1$'
has "a transfer that fills the pipe is followed by a zero-length packet" "$log" '^bulk ep=0x01 len=0$'
has "a transfer that fills a packet is sent" "$log" '^bulk ep=0x01 len=512$'
has "a partial transfer is still sent" "$log" '^bulk ep=0x01 len=100$'

echo "== each kill switch turns off exactly its own traffic =="
log=$tmp/no.clear.log
run "$log" SPDHOST_NO_CLEAR_HALT=1
hasnt "SPDHOST_NO_CLEAR_HALT=1 drops CLEAR_FEATURE" "$log" 'clear_halt'
has "…and leaves the configuration read alone" "$log" 'get_config'
has "…and leaves the ZLP alone" "$log" '^bulk ep=0x01 len=0$'

log=$tmp/no.setcfg.log
run "$log" SPDHOST_NO_SET_CONFIG=1
hasnt "SPDHOST_NO_SET_CONFIG=1 drops GET_CONFIGURATION" "$log" 'get_config'
hasnt "SPDHOST_NO_SET_CONFIG=1 drops SET_CONFIGURATION" "$log" 'set_config'
has "…and leaves CLEAR_FEATURE alone" "$log" 'clear_halt ep=0x01'
has "…and leaves the ZLP alone" "$log" '^bulk ep=0x01 len=0$'

log=$tmp/no.zlp.log
run "$log" SPDHOST_NO_SEND_ZLP=1
hasnt "SPDHOST_NO_SEND_ZLP=1 drops the zero-length packet" "$log" '^bulk ep=0x01 len=0$'
has "…and still sends the packet that filled the pipe" "$log" '^bulk ep=0x01 len=512$'
has "…and leaves CLEAR_FEATURE alone" "$log" 'clear_halt ep=0x01'
has "…and leaves the configuration read alone" "$log" 'get_config'

log=$tmp/zero.log
run "$log" SPDHOST_NO_CLEAR_HALT=0 SPDHOST_NO_SET_CONFIG=0 SPDHOST_NO_SEND_ZLP=0
has "=0 does not count as a kill switch" "$log" 'clear_halt ep=0x01'
has "…for the configuration either" "$log" '^set_config 1$'
has "…or for the ZLP" "$log" '^bulk ep=0x01 len=0$'

echo "== and the hooks are on the BootROM path only =="
# If the extra traffic is reached from anywhere but spd_brom_after_line_state()
# (the one hook this test drives), the switch protects a path the test never
# exercised.
n=$(grep -c 'spd_usb_clear_halts(&io->usb)' "$root/src/proto.c" || true)
check "clear_halts is called from exactly one place, in proto.c" test "${n:-0}" = 1
check "and not from the FDL1/FDL2 code in main.c" \
	test "$(grep -c 'spd_usb_clear_halts' "$root/src/main.c" || true)" = 0

echo "== C9: libusb error classification (PIPE back to the pre-B2-7.1 handling) =="
# PIPE marks gone again (so the hello / exec / final-chunk paths reacquire as
# they did before B2-7.1) and sets `stalled`, which only end_session reads.
log=$tmp/err.pipe.log; run "$log" MOCK_BULK_ERR=PIPE
has "PIPE on send: -1, gone, stalled" "$log" '^err send rc=-1 gone=1 stalled=1$'
has "PIPE on recv: -1, gone, stalled" "$log" '^err recv rc=-1 gone=1 stalled=1$'
log=$tmp/err.nodev.log; run "$log" MOCK_BULK_ERR=NO_DEVICE
has "NO_DEVICE on send: -1, gone, not stalled" "$log" '^err send rc=-1 gone=1 stalled=0$'
has "NO_DEVICE on recv: -1, gone, not stalled" "$log" '^err recv rc=-1 gone=1 stalled=0$'
log=$tmp/err.io.log; run "$log" MOCK_BULK_ERR=IO
has "IO on recv: -1, gone, not stalled" "$log" '^err recv rc=-1 gone=1 stalled=0$'
log=$tmp/err.to.log; run "$log" MOCK_BULK_ERR=TIMEOUT
has "TIMEOUT on send: -2, not gone" "$log" '^err send rc=-2 gone=0 stalled=0$'
has "TIMEOUT on recv: 0, not gone" "$log" '^err recv rc=0 gone=0 stalled=0$'
check "only end_session reads stalled (main.c), proto.c never does" \
	bash -c '[ "$(grep -c "usb.stalled" "$1/src/main.c")" -ge 1 ] && ! grep -q stalled "$1/src/proto.c"' _ "$root"

echo
echo "usb-extra: $pass passed, $fail failed"
(( fail == 0 ))
