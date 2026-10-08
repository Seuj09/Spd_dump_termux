#!/usr/bin/env bash
# P0-2: `spdhost caps` and the menu's use of it.
#
# caps tells a caller (menu.sh now, the app later) what this build can do:
# the commit it was built from, the caller-interface protocol version and
# one cap= line per feature, in a fixed line format (README, "spdhost caps").
# It must work with no device and never open USB. menu.sh asks caps instead
# of running a tool and grepping its usage text (spdhost_has_image_tools,
# spdhost_has_unpac), and a build without caps counts as having none.
#
# Usage (from no-root/): tests/caps.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
nope() { ! "$@"; }

cc=${CC:-cc}
make -C "$root" spdhost >"$tmp/make.log" 2>&1 || { tail -20 "$tmp/make.log"; echo "caps: build failed"; exit 1; }
bin=$root/spdhost

# The cap list is pinned: adding or dropping one is a deliberate change here.
want_caps='confirm-token dry-run frp-part image-tools misc-bytes pack-slot parts-header status-file unpac usb-fd'

echo "== format =="
"$bin" caps >"$tmp/caps.out" 2>"$tmp/caps.err"; rc=$?
check "caps exits 0" test "$rc" = 0
check "caps writes nothing to stderr" test ! -s "$tmp/caps.err"
check "line 1 is caps_format=1" test "$(sed -n 1p "$tmp/caps.out")" = caps_format=1
check "line 2 is build_sha=<40 hex|unknown>" grep -qxE 'build_sha=([0-9a-f]{40}|unknown)' <(sed -n 2p "$tmp/caps.out")
check "line 3 is protocol=1" test "$(sed -n 3p "$tmp/caps.out")" = protocol=1
check "the last line is end" test "$(tail -n 1 "$tmp/caps.out")" = end
check "every other line is cap=<name>, names [a-z0-9:-]" \
	bash -c '[ -z "$(sed -e 1,3d -e "\$d" "$1" | grep -vxE "cap=[a-z0-9][a-z0-9:-]*")" ]' _ "$tmp/caps.out"
got=$(sed -n 's/^cap=//p' "$tmp/caps.out")
check "cap names are sorted and unique" test "$got" = "$(printf '%s\n' "$got" | LC_ALL=C sort -u)"
check "the cap list is exactly: $want_caps" test "$(echo $got)" = "$want_caps"
check "every line is key=value except the final end" \
	bash -c '[ -z "$(sed "\$d" "$1" | grep -vE "^[a-z_]+=[^[:space:]]+$")" ]' _ "$tmp/caps.out"
if git -C "$root" rev-parse HEAD >/dev/null 2>&1; then
	check "build_sha is the commit make built from (git rev-parse HEAD)" \
		test "$(sed -n 2p "$tmp/caps.out")" = "build_sha=$(git -C "$root" rev-parse HEAD)"
fi
"$bin" caps extra >/dev/null 2>"$tmp/x.err"; rc=$?
check "caps with an argument is refused (exit 2)" bash -c '[ "$1" = 2 ] && grep -q "caps takes no arguments" "$2"' _ "$rc" "$tmp/x.err"
check "options before caps change nothing (--dry-run, --verbose)" \
	bash -c 'cmp -s <("$1" --dry-run --verbose caps) "$2"' _ "$bin" "$tmp/caps.out"
check "--help lists caps" bash -c '"$1" --help 2>&1 | grep -q "^  caps "' _ "$bin"

echo "== no device, no USB =="
# The same sources linked with every libusb entry point trapped (exit 99).
srcs=("$root"/src/{main,usb,usb_list,proto,dumpcmd,writecmd,sha256,dhtb,pac}.c)
wraps=-Wl,--wrap=libusb_init,--wrap=libusb_init_context,--wrap=libusb_wrap_sys_device,--wrap=libusb_open_device_with_vid_pid
if $cc -O1 -w -std=c11 -D_FILE_OFFSET_BITS=64 $(pkg-config --cflags libusb-1.0 2>/dev/null) \
	-o "$tmp/trapped" "${srcs[@]}" "$root/tests/libusb_trap.c" "$wraps" \
	$(pkg-config --libs libusb-1.0 2>/dev/null || echo -lusb-1.0) 2>"$tmp/trap.log"; then
	"$tmp/trapped" ping >/dev/null 2>"$tmp/t0.err"
	check "(the trap works: a device command hits it)" grep -q '^TRAP ' "$tmp/t0.err"
	"$tmp/trapped" caps >"$tmp/t1.out" 2>"$tmp/t1.err"; rc=$?
	check "caps: exit 0, no libusb call" bash -c '[ "$1" = 0 ] && ! grep -q TRAP "$2"' _ "$rc" "$tmp/t1.err"
	check "caps from the trapped build: build_sha=unknown (no stamp), same caps" \
		bash -c 'grep -qx build_sha=unknown "$1" && diff <(grep "^cap=" "$1") <(grep "^cap=" "$2") >/dev/null' _ "$tmp/t1.out" "$tmp/caps.out"
	TERMUX_USB_FD=7 "$tmp/trapped" caps >/dev/null 2>"$tmp/t2.err"; rc=$?
	check "caps with TERMUX_USB_FD set: no libusb call" bash -c '[ "$1" = 0 ] && ! grep -q TRAP "$2"' _ "$rc" "$tmp/t2.err"
	"$tmp/trapped" --usb-fd 9 --vid 0x1782 --pid 0x4d00 caps >/dev/null 2>"$tmp/t3.err" 9</dev/null; rc=$?
	check "caps with --usb-fd and --vid/--pid: no libusb call" bash -c '[ "$1" = 0 ] && ! grep -q TRAP "$2"' _ "$rc" "$tmp/t3.err"
else
	cat "$tmp/trap.log"; bad "trapped build failed"
fi

echo "== each cap is real =="
for t in gen-spl-unlock gen-spl-unlock-legacy gen-fdl1-dl chsize; do
	"$bin" "$t" >/dev/null 2>"$tmp/t.err"; rc=$?
	check "image-tools: $t is an offline command (usage, exit 2)" bash -c '[ "$1" = 2 ] && grep -qx "$2 IN OUT" "$3"' _ "$rc" "$t" "$tmp/t.err"
done
"$bin" unpac >/dev/null 2>"$tmp/t.err"; rc=$?
check "unpac: offline command (usage, exit 2)" bash -c '[ "$1" = 2 ] && grep -q "^unpac \[-d dir\]" "$2"' _ "$rc" "$tmp/t.err"
"$bin" pack-slot >/dev/null 2>"$tmp/t.err"; rc=$?
check "pack-slot: offline command (usage, exit 2)" bash -c '[ "$1" = 2 ] && grep -qx "pack-slot a|b IN OUT" "$2"' _ "$rc" "$tmp/t.err"
check "dry-run: --dry-run ping prints a DRY packet line" bash -c '"$1" --dry-run ping 2>/dev/null | grep -q "^DRY "' _ "$bin"
"$bin" --confirm-token xyz caps >/dev/null 2>"$tmp/t.err"; rc=$?
check "confirm-token: --confirm-token is parsed (a bad one is refused)" bash -c '[ "$1" = 2 ] && grep -q "bad --confirm-token" "$2"' _ "$rc" "$tmp/t.err"
"$bin" --usb-fd 1 caps >/dev/null 2>"$tmp/t.err"; rc=$?
check "usb-fd: --usb-fd is parsed (fd < 3 refused)" bash -c '[ "$1" = 2 ] && grep -q "bad --usb-fd" "$2"' _ "$rc" "$tmp/t.err"
check "status-file: SPDHOST_STATUS_FILE is read by the core" grep -q 'getenv("SPDHOST_STATUS_FILE")' "$root/src/main.c"
check "misc-bytes: the core writes the misc-bytes status key" grep -q '"misc-bytes"' "$root/src/main.c"
check "frp-part: frp-reset reads SPDHOST_FRP_PART" grep -q 'SPDHOST_FRP_PART' "$root/src/main.c"
check "parts-header: parts files start with the # spdhost-parts header" grep -q '# spdhost-parts shift %d verified %d' "$root/src/proto.c"

echo "== build stamping =="
check "Makefile passes -DSPDHOST_BUILD_SHA" grep -q -- "-DSPDHOST_BUILD_SHA=" "$root/Makefile"
check "the cross build passes -DSPDHOST_BUILD_SHA (both arches use cross-arm32.sh)" \
	bash -c 'grep -q -- "-DSPDHOST_BUILD_SHA=" "$1/scripts/cross-arm32.sh" && grep -q "cross-arm32.sh" "$1/scripts/cross-arm64.sh"' _ "$root"
$cc -O1 -w -std=c11 -D_FILE_OFFSET_BITS=64 -DSPDHOST_BUILD_SHA='"not-a-sha"' $(pkg-config --cflags libusb-1.0 2>/dev/null) \
	-o "$tmp/bogus" "${srcs[@]}" $(pkg-config --libs libusb-1.0 2>/dev/null || echo -lusb-1.0) 2>/dev/null
check "a stamp that is not 40 hex reports unknown" bash -c '"$1" caps | grep -qx build_sha=unknown' _ "$tmp/bogus"

echo "== menu.sh asks caps =="
m=$root/scripts/menu.sh
menu() { # BIN FUNC...: run a menu function against SPDHOST_BIN=BIN
	local b=$1; shift
	SPDHOST_BIN=$b SPDHOST_MENU_LIB=1 SPDHOST_MENU_CONFIG=$tmp/none.conf TMPDIR=$tmp \
		bash -c 'source "$1" >/dev/null 2>&1; shift; "$@"' _ "$m" "$@" </dev/null
}
check "real build: spdhost_has_image_tools" menu "$bin" spdhost_has_image_tools
check "real build: spdhost_has_unpac" menu "$bin" spdhost_has_unpac
check "real build: spdhost_has_cap for a cap it lacks is false" nope menu "$bin" spdhost_has_cap no-such-cap
menu "$bin" spdhost_caps >"$tmp/menu-caps.out"
check "real build: spdhost_caps prints the caps output" cmp -s "$tmp/menu-caps.out" "$tmp/caps.out"

# Fake builds. Each logs its argv, so the probe's own command line is checked.
fake() { # NAME BODY
	printf '#!/bin/bash\necho "$*" >>"%s/%s.argv"\n%s\n' "$tmp" "$1" "$2" >"$tmp/$1"
	chmod +x "$tmp/$1"
}
# An spdhost from before caps: `caps` is an unknown command (as in dry-run),
# while its tools still answer their usage lines the old probes grepped for.
fake old 'case " $* " in
*" gen-spl-unlock "*) echo "gen-spl-unlock IN OUT" >&2; exit 2 ;;
*" unpac "*) echo "unpac [-d dir] {list|extract|check} firmware.pac [names]" >&2; exit 2 ;;
esac
echo "unknown command: ${@: -1}" >&2; exit 2'
check "pre-caps build: no image tools (menu takes its release-tool path)" nope menu "$tmp/old" spdhost_has_image_tools
check "pre-caps build: no unpac" nope menu "$tmp/old" spdhost_has_unpac
check "the probe runs exactly '--dry-run caps', never a tool for its usage" \
	bash -c '[ "$(sort -u "$1")" = "--dry-run caps" ]' _ "$tmp/old.argv"
out=$(SPDHOST_INPUT_DIR=$tmp menu "$tmp/old" pac_extract_action 2>&1); rc=$?
check "pre-caps build: [16] PAC extract stops with the rebuild message" \
	bash -c '[ "$1" != 0 ] && [[ $2 == *"no built-in PAC reader"* && $2 == *"Rebuild it"* ]]' _ "$rc" "$out"
fake noend 'printf "caps_format=1\nbuild_sha=unknown\nprotocol=1\ncap=unpac\ncap=image-tools\n"'
check "truncated caps (no end line) counts as none" nope menu "$tmp/noend" spdhost_has_unpac
fake fmt2 'printf "caps_format=2\nbuild_sha=unknown\nprotocol=1\ncap=unpac\nend\n"'
check "an unknown caps_format counts as none" nope menu "$tmp/fmt2" spdhost_has_unpac
fake fails 'printf "caps_format=1\ncap=unpac\nend\n"; exit 1'
check "a non-zero exit counts as none" nope menu "$tmp/fails" spdhost_has_unpac
fake extra 'printf "caps_format=1\nbuild_sha=unknown\nprotocol=7\nfuture_key=x y\ncap=unpac\ncap=zz:new\nend\n"'
check "unknown keys and caps are ignored; the known cap still counts" menu "$tmp/extra" spdhost_has_unpac
fake part 'printf "caps_format=1\ncap=unpac-x\ncap=xunpac\nend\n"'
check "a cap is matched whole (unpac does not match unpac-x or xunpac)" nope menu "$tmp/part" spdhost_has_unpac
check "menu.sh no longer greps usage text for features" \
	bash -c '! grep -nE "\"gen-spl-unlock IN OUT\"|\"unpac \[-d dir\]\"|\"\\\$bin\" (gen-spl-unlock|unpac) 2>&1" "$1"' _ "$m"

echo
echo "caps: $pass passed, $fail failed"
(( fail == 0 ))
