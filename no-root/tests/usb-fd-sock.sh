#!/usr/bin/env bash
# P0-5: --usb-fd-sock PATH, the app's descriptor hand-off (README "USB fd
# socket"). Termux cannot exercise it, so tests/fd-sock-server.py plays the
# app: a filesystem-path unix socket that answers HELLO with the fd via
# SCM_RIGHTS and REACQ with "no" (the P0 stub).
#
#   A. the real spdhost: caps, argument refusals, connect / refused / EOF
#      failures, the fd arriving, TERMUX_USB_FD ignored under the socket.
#   B. spdhost on mock_fdl2 (no phone): a whole session over the socket sends
#      exactly the same frames as the same session over --usb-fd, and the
#      event channel says usb=sock.
#   C. src/usb.c on the fd-lifecycle mock (tests/mock_usb_fdlife.c):
#      REACQ goes out and "no" means no reopen; an offered fd is closed and
#      not used; the wrapped fd is still closed once after its handle; the
#      SO_PEERCRED uid check refuses another uid (getuid faked by --wrap,
#      so no root is needed) before HELLO is sent.
#
# Usage (from no-root/): tests/usb-fd-sock.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { if grep -qx -- "$3" "$2"; then ok "$1"; else bad "$1"; echo "      want: $3"; sed 's/^/      log: /' "$2" | head -20; fi; }
hasnt() { if grep -q -- "$3" "$2"; then bad "$1"; grep -- "$3" "$2" | sed 's/^/      got: /'; else ok "$1"; fi; }
before() {
	local a b
	a=$(grep -nx -- "$3" "$2" | head -1 | cut -d: -f1)
	b=$(grep -nx -- "$4" "$2" | head -1 | cut -d: -f1)
	if [[ -n $a && -n $b ]] && (( a < b )); then ok "$1"; else bad "$1 (lines ${a:-none} / ${b:-none})"; fi
}
CC=${CC:-gcc}
if ! command -v python3 >/dev/null 2>&1; then
	echo "skip  python3 is not installed (the app peer is a python script)"
	echo "usb-fd-sock: 0 passed, 0 failed, 1 skipped"
	exit 0
fi
srv=$root/tests/fd-sock-server.py
clean_env=(env -u TERMUX_USB_FD -u SPD_USB_FD -u SPDHOST_EMIT_SOCK -u SPDHOST_STATUS_FILE)

# ------------------------------------------------------------------- A
make -C "$root" spdhost >"$tmp/make.log" 2>&1 || { tail -20 "$tmp/make.log"; echo "usb-fd-sock: build failed"; exit 1; }
bin=$root/spdhost
S=$tmp/s   # short: sun_path is 108 bytes

echo "== A. caps and argument checks =="
"$bin" caps >"$tmp/caps" 2>&1
has "caps advertises usb-fd-sock" "$tmp/caps" 'cap=usb-fd-sock'
has "...and still usb-fd" "$tmp/caps" 'cap=usb-fd'
"${clean_env[@]}" "$bin" --usb-fd-sock "$S" --usb-fd 7 reset 7</dev/null >"$tmp/a1" 2>&1; rc=$?
check "--usb-fd-sock with --usb-fd: exit 2" test "$rc" = 2
has "...says why" "$tmp/a1" 'spdhost: --usb-fd-sock cannot be combined with --usb-fd'
"${clean_env[@]}" "$bin" --usb-fd-sock "$S" --dry-run reset >"$tmp/a2" 2>&1; rc=$?
check "--usb-fd-sock with --dry-run: exit 2" test "$rc" = 2
has "...says why" "$tmp/a2" 'spdhost: --usb-fd-sock cannot be combined with --dry-run'
"${clean_env[@]}" "$bin" --usb-fd-sock "" reset >"$tmp/a3" 2>&1; rc=$?
check "empty --usb-fd-sock: exit 2" test "$rc" = 2

echo "== A. connect failures =="
"${clean_env[@]}" "$bin" --usb-fd-sock "$tmp/nope" reset >"$tmp/a4" 2>&1; rc=$?
check "no socket at PATH: exit 1" test "$rc" = 1
check "...connect error names the path" grep -q "^--usb-fd-sock: connect $tmp/nope: " "$tmp/a4"
long=/$(printf 'x%.0s' $(seq 1 120))
"${clean_env[@]}" "$bin" --usb-fd-sock "$long" reset >"$tmp/a5" 2>&1; rc=$?
check "PATH >= 108 bytes: exit 1" test "$rc" = 1
check "...refused before connect" grep -q 'a unix socket path must be < 108' "$tmp/a5"
"${clean_env[@]}" python3 "$srv" "$S" "$tmp/nofd.srv" nofd -- "$bin" --usb-fd-sock "$S" reset >"$tmp/a6" 2>&1; rc=$?
check "server answers HELLO without an fd: exit 1" test "$rc" = 1
has "...the core sent HELLO 1" "$tmp/nofd.srv" 'line HELLO 1'
has "...the core says no descriptor" "$tmp/a6" '--usb-fd-sock: the server sent no descriptor (refused or closed)'
"${clean_env[@]}" python3 "$srv" "$S" "$tmp/eof.srv" eof -- "$bin" --usb-fd-sock "$S" reset >"$tmp/a7" 2>&1; rc=$?
check "server closes at once: exit 1" test "$rc" = 1
check "...no descriptor, or HELLO could not be sent" grep -qE 'sent no descriptor|HELLO send failed' "$tmp/a7"
check "the socket file is gone after the session (peer unlinks)" test ! -e "$S"

echo "== A. the fd arrives (real libusb then rejects a non-usbfs file) =="
: >"$tmp/notusb"
"${clean_env[@]}" python3 "$srv" "$S" "$tmp/ok.srv" ok "$tmp/notusb" -- "$bin" --usb-fd-sock "$S" reset >"$tmp/a8" 2>&1; rc=$?
has "HELLO 1 sent" "$tmp/ok.srv" 'line HELLO 1'
has "the peer sent the fd" "$tmp/ok.srv" 'sent-fd'
check "spdhost got as far as wrapping it (libusb_wrap_sys_device on that fd)" grep -q '^libusb_wrap_sys_device(' "$tmp/a8"
check "...and exits 1 since it is not a usbfs node" test "$rc" = 1
hasnt "no SO_PEERCRED refusal for our own uid" "$tmp/a8" 'refused: socket server uid'
exec 7</dev/null
"${clean_env[@]}" TERMUX_USB_FD=7 "$bin" --usb-fd-sock "$tmp/nope" reset >"$tmp/a9" 2>&1; rc=$?
check "TERMUX_USB_FD is ignored under --usb-fd-sock (connect error, not a wrap of fd 7)" \
	bash -c '[ "$1" = 1 ] && grep -q "^--usb-fd-sock: connect" "$2" && ! grep -q wrap_sys_device "$2"' _ "$rc" "$tmp/a9"

# ------------------------------------------------------------------- B
echo "== B. a whole session over the socket = the same session over --usb-fd =="
$CC -O2 -w -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I"$root/tests" \
	"$root/src/main.c" "$root/src/plan.c" "$root/src/loaders.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/events.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || { bad "mock_fdl2 build"; }
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
(
	cd "$tmp" || exit 1
	printf '%s\n' 'prodnv 5120' 'miscdata 1024' 'misc 1024' 'uboot 1024' 'boot 36864' 'userdata 4194304' >ptn
	export MOCK_PTABLE=$tmp/ptn MOCK_SLOT=
	SESS=(exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin fdl fdl1-dl.bin 0x65000800
		fdl fdl2-dl.bin 0x9efffe00 parts pt.txt read-part misc 0 4096 misc.bin reset)
	"${clean_env[@]}" MOCK_LOG=fd.seq timeout 60 ./sh --usb-fd 7 "${SESS[@]}" 7<notusb </dev/null >fd.out 2>fd.err
	echo $? >fd.rc; mv pt.txt fd.pt; mv misc.bin fd.misc
	"${clean_env[@]}" MOCK_LOG=sk.seq timeout 60 python3 "$srv" "$S" sk.srv ok notusb -- \
		./sh --usb-fd-sock "$S" --events "$tmp/sk.ev" "${SESS[@]}" </dev/null >sk.out 2>sk.err
	echo $? >sk.rc; mv pt.txt sk.pt; mv misc.bin sk.misc
)
check "session over --usb-fd exits 0" test "$(cat "$tmp/fd.rc")" = 0
check "session over --usb-fd-sock exits 0" test "$(cat "$tmp/sk.rc")" = 0
check "the wire sequence (every frame) is byte-identical" cmp -s "$tmp/fd.seq" "$tmp/sk.seq"
check "...and non-trivial (> 20 frames)" test "$(wc -l <"$tmp/sk.seq")" -gt 20
check "stdout is identical" cmp -s "$tmp/fd.out" "$tmp/sk.out"
check "the parts file is identical" cmp -s "$tmp/fd.pt" "$tmp/sk.pt"
check "the read-back misc bytes are identical" cmp -s "$tmp/fd.misc" "$tmp/sk.misc"
has "the peer saw exactly one HELLO" "$tmp/sk.srv" 'line HELLO 1'
hasnt "no REACQ in a clean session" "$tmp/sk.srv" 'REACQ'
has "the core closed the socket at the end (peer saw EOF)" "$tmp/sk.srv" 'eof'
check "event channel: session usb=sock" grep -q '"ev":"session","usb":"sock"' "$tmp/sk.ev"

# ------------------------------------------------------------------- C
echo "== C. usb.c on the fd-lifecycle mock: REACQ stub, offered fd, SO_PEERCRED =="
if ! $CC -O1 -Wall -Wextra -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -DMOCK_WRAP_GETUID -I"$root/src" \
	-o "$tmp/drive" "$root/src/usb.c" "$root/src/usb_list.c" "$root/tests/mock_usb_fdlife.c" \
	-Wl,--wrap=close -Wl,--wrap=getuid 2>"$tmp/drive.log"; then
	cat "$tmp/drive.log"; bad "driver build"
fi
drv() { # CASE MODE LOG [VAR=VALUE ...]
	local c=$1 m=$2 l=$3; shift 3
	: >"$tmp/dfile"
	"${clean_env[@]}" MOCK_CASE="$c" MOCK_SOCK="$S" "$@" timeout 60 \
		python3 "$srv" "$S" "$l.srv" "$m" "$tmp/dfile" -- "$tmp/drive" >"$l" 2>"$l.err"
}
L=$tmp/c1; drv sock ok "$L"
has "fd from the socket is the wrapped fd; sock_mode set; CLOEXEC on it" "$L" 'ev opened wrapped_fd=fd sock_mode=1 cloexec=1'
has "reacquire over the socket fails (stub answers no)" "$L" 'ev reacquire rc=-1'
has "...REACQ vid=1782 went out" "$L.srv" 'line REACQ vid=1782'
before "...after HELLO" "$L.srv" 'line HELLO 1' 'line REACQ vid=1782'
check "...the core says the app answered no" grep -q 'the app answered no to REACQ; not reopening' "$L.err"
has "the wrapped fd: closed once, after its handle (at reacquire)" "$L" 'rec 0 wrapped=1 libusb_closes=1 fd_closes=1 order_ok=1 open=0'
has "no second wrap" "$L" 'summary recs=1 scan_handles=0 viol=0'
hasnt "no fd violation" "$L" '^viol '
has "the socket is closed at spd_usb_close (peer saw EOF)" "$L.srv" 'eof'
hasnt "no termux-usb fallback in socket mode" "$L.err" 'termux-usb'

L=$tmp/c2; drv sock offer "$L"
has "an offered REACQ fd is not used: reacquire still fails" "$L" 'ev reacquire rc=-1'
check "...and the core says the yes-path is not in this build" grep -q 'only has the REACQ stub' "$L.err"
has "...nothing new is wrapped" "$L" 'summary recs=1 scan_handles=0 viol=0'
hasnt "...no fd violation" "$L" '^viol '

L=$tmp/c3; drv sock_get ok "$L" MOCK_UID=$(( $(id -u) + 4242 ))
has "SO_PEERCRED: another uid's server is refused" "$L" 'ev sock_get fd=-1 sock=-1'
check "...with the reason" grep -q "refused: socket server uid $(id -u) is not this process's uid $(( $(id -u) + 4242 ))" "$L.err"
hasnt "...before HELLO is sent" "$L.srv" 'HELLO'
L=$tmp/c4; drv sock_get ok "$L" MOCK_UID=$(id -u)
has "SO_PEERCRED: the same uid is accepted" "$L" 'ev sock_get fd=ok sock=ok'

echo "== E7: the termux path is unchanged by construction =="
c=$root/src/usb.c
check "reacquire picks the socket only in sock_mode, else termux as before" \
	grep -q 'if (u->sock_mode)' "$c"
check "spd_usb_open does not touch the socket (memset leaves sock_mode 0)" \
	bash -c '! sed -n "/^int spd_usb_open/,/^}/p" "$1" | grep -q sock' _ "$c"

echo
echo "usb-fd-sock: $pass passed, $fail failed"
(( fail == 0 ))
