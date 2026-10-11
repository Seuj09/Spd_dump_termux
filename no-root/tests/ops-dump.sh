#!/usr/bin/env bash
# P0-7: `ops dump DIR --preset P` (free-space preflight on the live table, A5
# layout, meta/SHA256SUMS, manifest) and `images list DIR [--json]` (the picker
# rule), against the mock FDL2 (tests/mock_fdl2.c) and the vendored spd_dump.
# Also: menu.sh switches its dump and its restore/promote pickers to the core
# when caps say so, and keeps the bash path for an older binary.
# Usage (from no-root/): tests/ops-dump.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP_TMP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

make -C "$root/spd_dump" GITVER.h >/dev/null
gcc -O1 -w -std=c99 -D_GNU_SOURCE -DUSE_LIBUSB=1 -D__ANDROID__ -I"$root/spd_dump" -I"$root/tests" \
	"$root/spd_dump/spd_dump.c" "$root/spd_dump/common.c" "$root/tests/mock_fdl2.c" -lm -lpthread -o "$tmp/sd" || exit 1
gcc -O2 -w -std=c11 -D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/plan.c" "$root/src/loaders.c" "$root/src/ops.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/events.c" \
	"$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" \
	"$root/tests/statvfs_shim.c" -Wl,--wrap=statvfs,--wrap=statvfs64 -o "$tmp/sh" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
py=$(command -v python3 || true)
unset SPDHOST_PART_XML_DIR
mkdir -p "$tmp/st"; export SPDHOST_STATE_DIR=$tmp/st # never the real state dir

# KiB units (spd_dump divisor 10). A/B pairs, the bulk rows all/all_lite skip,
# and the NV set the imei preset reads (nv1 from nv2 at +512).
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 2048' \
	'vbmeta_a 1024' 'vbmeta_b 1024' 'miscdata 1024' 'prodnv 1024' 'l_fixnv1 2048' 'l_fixnv2 2048' \
	'l_runtimenv1 1024' 'l_runtimenv2 1024' 'userdata 8192' 'cache 2048' 'blackbox 1024' > "$tmp/pt"

FDLS=(exec_addr 0x65015f08 "$tmp/custom_exec_no_verify_65015f08.bin" fdl "$tmp/fdl1-dl.bin" 0x65000800 fdl "$tmp/fdl2-dl.bin" 0x9efffe00)
sh_run() { # DIR SLOT CMD...   (run from DIR; events into DIR.ev)
	local d=$1 s=$2; shift 2; mkdir -p "$d"
	mkdir -p "$d/meta"
	( cd "$d" && MOCK_PTABLE="${PT:-$tmp/pt}" MOCK_SLOT=$s MOCK_LOG="$d.seq" SPDHOST_PART_XML_DIR="$d/meta" \
		timeout 120 "$tmp/sh" --usb-fd 7 --keep-going --events "$d.ev" "${FDLS[@]}" "$@" reset \
		7</dev/null </dev/null >"$d.out" 2>"$d.err" )
}
spd_run() { # DIR MODE
	local d=$1 m=$2; mkdir -p "$d"
	( cd "$d" && MOCK_PTABLE="$tmp/pt" MOCK_SLOT=a MOCK_LOG="$d/sd.seq" TERMUX_USB_FD=7 \
		timeout 120 "$tmp/sd" exec_addr 0x65015f08 fdl "$tmp/fdl1-dl.bin" 0x65000800 \
		fdl "$tmp/fdl2-dl.bin" 0x9efffe00 exec r "$m" reset 7</dev/null </dev/null >sd.log 2>&1 )
}
imgs() { (cd "$1" && ls *.img 2>/dev/null | sed 's/\.img$//' | sort | tr '\n' ' '); }
ev() { grep "\"ev\":\"$2\"" "$1.ev"; }
sum_listed() { # DIR: total bytes of the files named in meta/SHA256SUMS
	local t=0 f
	while read -r _ f; do t=$((t + $(stat -c %s "$1/$f"))); done < "$1/meta/SHA256SUMS"
	echo "$t"
}

echo "== all_lite, slot a =="
d=$tmp/lite; sh_run "$d" a ops dump "$d" --preset all_lite; rc=$?
check "all_lite: exit 0" test "$rc" = 0
check "all_lite: active slot only, bulk rows skipped, splloader added" \
	test "$(imgs "$d")" = "boot_a l_fixnv1 l_fixnv2 l_runtimenv1 l_runtimenv2 misc miscdata prodnv splloader uboot_a vbmeta_a "
check "A5: images at the root, side files only in meta/ (table, XML, sprdpart.bin, manifest, slotinfo)" \
	bash -c 'cd "$1" && [ -z "$(ls | grep -v -e "\.img$" -e "^meta$")" ] && [ -s meta/partition_list.txt ] && [ -s meta/dump-manifest.txt ] && [ -s meta/misc-slotinfo.img ] && [ -s meta/sprdpart.bin ] && ls meta/partition_*.xml >/dev/null && [ ! -e SHA256SUMS ]' _ "$d"
check "meta/SHA256SUMS verifies from the dump folder (cd DIR && sha256sum -c meta/SHA256SUMS)" \
	bash -c 'cd "$1" && sha256sum -c --quiet meta/SHA256SUMS' _ "$d"
check "meta/SHA256SUMS: one line per image, relative names" \
	bash -c '[ "$(wc -l < "$1/meta/SHA256SUMS")" = 11 ] && ! grep -q / "$1/meta/SHA256SUMS"' _ "$d"
check "meta/SHA256SUMS is 0644-ish, not mkstemp's 0600" bash -c '[ "$(stat -c %a "$1/meta/SHA256SUMS")" != 600 ]' _ "$d"
check "manifest: slot a, a start+ok per file, the plan line" \
	bash -c 'm=$1/meta/dump-manifest.txt; grep -qx "slot a" $m && [ "$(grep -c ^start $m)" = 11 ] && [ "$(grep -c ^ok $m)" = 11 ] && grep -q "^plan 11 " $m' _ "$d"
need=$(ev "$d" preflight | sed -n 's/.*"need":\([0-9]*\).*/\1/p')
check "C4: the preflight plan equals the bytes actually written ($need)" test "$need" = "$(sum_listed "$d")"
check "preflight event: ok, slot a, table verified, headroom 64 MiB" \
	bash -c 'grep "\"ev\":\"preflight\"" "$1.ev" | grep -q "\"headroom\":67108864,.*\"slot\":\"a\",\"table_verified\":true,\"ok\":true"' _ "$d"
check "dump-file events: 11 ok, each with the SHA256SUMS digest" \
	bash -c '[ "$(grep -c "\"ev\":\"dump-file\".*\"state\":\"ok\"" "$1.ev")" = 11 ] && h=$(grep " boot_a.img$" "$1/meta/SHA256SUMS" | cut -c1-64) && grep -q "\"name\":\"boot_a\".*\"sha256\":\"$h\"" "$1.ev"' _ "$d"
check "op event: dump ok, 11 files" bash -c 'grep -q "\"ev\":\"op\",\"op\":\"dump\",\"state\":\"ok\",\"files\":11,\"failed\":0" "$1.ev"' _ "$d"
check "the session still ends with reset" grep -q "reset: acknowledged" "$d.err"
check "the table read also feeds plan's table-last (state dir)" bash -c '! grep -q "could not save" "$1.err"' _ "$d"
s=$tmp/sdlite; spd_run "$s" all_lite
same=1
for n in $(imgs "$d"); do cmp -s "$d/$n.img" "$s/$n.bin" || { echo "  $n differs from spd_dump"; same=0; }; done
check "all_lite: the same files and bytes as spd_dump r all_lite" \
	bash -c '[ "$1" = 1 ] && [ "$(cd "$2" && ls *.bin | grep -v -e ^fdl -e ^custom_exec -e ^sprdpart | sed "s/\.bin$//" | sort | tr "\n" " ")" = "$3" ]' _ "$same" "$s" "$(imgs "$d")"

echo "== all, slot b; all_lite on slot b =="
d=$tmp/all; sh_run "$d" b ops dump "$d" --preset all; rc=$?
check "all: exit 0, both slots, no userdata/cache/blackbox" \
	bash -c '[ "$1" = 0 ] && [ "$2" = "boot_a boot_b l_fixnv1 l_fixnv2 l_runtimenv1 l_runtimenv2 misc miscdata prodnv splloader uboot_a uboot_b vbmeta_a vbmeta_b " ]' _ "$rc" "$(imgs "$d")"
check "all: plan == bytes written" test "$(ev "$d" preflight | sed -n 's/.*"need":\([0-9]*\).*/\1/p')" = "$(sum_listed "$d")"
d=$tmp/liteb; sh_run "$d" b ops dump "$d" --preset all_lite
check "all_lite on slot b: the _b rows, manifest says slot b" \
	bash -c '[ "$2" = "boot_b l_fixnv1 l_fixnv2 l_runtimenv1 l_runtimenv2 misc miscdata prodnv splloader uboot_b vbmeta_b " ] && grep -qx "slot b" "$1/meta/dump-manifest.txt"' _ "$d" "$(imgs "$d")"
check "all_lite on slot b: plan counts boot_b (2 MiB), not boot_a" \
	test "$(ev "$d" preflight | sed -n 's/.*"need":\([0-9]*\).*/\1/p')" = "$(sum_listed "$d")"

echo "== free-space preflight (A8 / audit6 C4) =="
d=$tmp/lite
need=$(ev "$d" preflight | sed -n 's/.*"need":\([0-9]*\).*/\1/p')
r=$tmp/full; MOCK_FREE_BYTES=$((need + 67108864 - 1)) sh_run "$r" a ops dump "$r" --preset all_lite; rc=$?
check "one byte short of plan + headroom: refused, exit nonzero" test "$rc" != 0
check "refused: nothing was read (no image, no .tmp/.partial)" bash -c '[ -z "$(ls "$1" | grep -v ^meta$)" ] && [ -z "$(ls "$1/meta" | grep -e "\.img" | grep -v ^misc-slotinfo.img$)" ]' _ "$r"
check "refused: no partition read reached the device" bash -c '! grep -q "read splloader\|read boot_a\|read misc:" "$1.err"' _ "$r"
check "refused: says so with the numbers" grep -q "REFUSED: not enough free space" "$r.err"
check "refused: manifest records it (menu reads this)" grep -q "^refused space $((need + 67108864)) $((need + 67108864 - 1))$" "$r/meta/dump-manifest.txt"
check "refused: preflight ok:false + op refused events" \
	bash -c 'grep "\"ev\":\"preflight\"" "$1.ev" | grep -q "\"ok\":false" && grep -q "\"state\":\"refused\",\"why\":\"space\"" "$1.ev"' _ "$r"
check "refused: --keep-going still ends the session with reset" grep -q "reset: acknowledged" "$r.err"
r=$tmp/exact; MOCK_FREE_BYTES=$((need + 67108864)) sh_run "$r" a ops dump "$r" --preset all_lite; rc=$?
check "exactly plan + headroom free: goes ahead" bash -c '[ "$1" = 0 ] && [ -s "$2/boot_a.img" ]' _ "$rc" "$r"
r=$tmp/head0; MOCK_FREE_BYTES=$need sh_run "$r" a ops dump "$r" --preset all_lite --headroom 0; rc=$?
check "--headroom 0: plan alone is enough" test "$rc" = 0
r=$tmp/nostat; MOCK_FREE_BYTES=fail sh_run "$r" a ops dump "$r" --preset boot; rc=$?
check "statvfs fails: noted, continues (menu's old behaviour), avail -1" \
	bash -c '[ "$1" = 0 ] && grep -q "could not read free space" "$2.err" && grep -q "\"avail\":-1" "$2.ev"' _ "$rc" "$r"
PT=$tmp/ptsuper
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'super 65536' 'metadata 1024' 'system_a 32768' 'system_b 32768' 'userdata 8192' > "$PT"
r=$tmp/super; MOCK_FREE_BYTES=$((64 << 20)) PT=$PT sh_run "$r" a ops dump "$r" --preset all_lite; rc=$?
check "C4: all_lite counts super + metadata + the active system (old bash estimate skipped them)" \
	bash -c 'grep "\"ev\":\"preflight\"" "$1.ev" | grep -q "\"need\":$((262144 + 1048576 + 1048576 + 67108864 + 1048576 + 1048576 + 33554432))," && [ "$2" != 0 ]' _ "$r" "$rc"
unset PT

echo "== presets: names, several names, imei, missing =="
d=$tmp/names; sh_run "$d" a ops dump "$d" --preset boot --preset vbmeta_b --preset splloader; rc=$?
check "names: boot follows slot a, vbmeta_b as typed, splloader 256 KiB" \
	bash -c '[ "$1" = 0 ] && [ "$2" = "boot_a splloader vbmeta_b " ] && [ "$(stat -c %s "$3/splloader.img")" = 262144 ]' _ "$rc" "$(imgs "$d")" "$d"
d=$tmp/imei; sh_run "$d" a ops dump "$d" --preset imei; rc=$?
check "imei: the release NV set (miscdata prodnv l_fixnv1/2 l_runtimenv1/2)" \
	bash -c '[ "$1" = 0 ] && [ "$2" = "l_fixnv1 l_fixnv2 l_runtimenv1 l_runtimenv2 miscdata prodnv " ]' _ "$rc" "$(imgs "$d")"
d=$tmp/miss; sh_run "$d" a ops dump "$d" --preset boot --preset nosuch; rc=$?
check "missing name: boot still dumped, exit nonzero, FAIL line + missing event" \
	bash -c '[ "$1" != 0 ] && [ -s "$2/boot_a.img" ] && grep -q "FAIL nosuch: not in the live table" "$2.err" && grep -q "\"name\":\"nosuch\".*\"state\":\"missing\"" "$2.ev"' _ "$rc" "$d"
d=$tmp/ud; sh_run "$d" a ops dump "$d" --preset userdata; rc=$?
check "userdata asks first: declined without a tty, nothing read" bash -c '[ ! -e "$1/userdata.img" ]' _ "$d"

echo "== SHA256SUMS upkeep =="
d=$tmp/redo; mkdir -p "$d"
printf 'deadbeef%056d  boot_a.img\nabc%061d  keep.img\n' 0 0 > "$d/SHA256SUMS"
sh_run "$d" a ops dump "$d" --preset boot
check "old flat dump: root SHA256SUMS moves into meta/" bash -c '[ ! -e "$1/SHA256SUMS" ] && [ -f "$1/meta/SHA256SUMS" ]' _ "$d"
check "re-dump: the stale boot_a.img line is replaced, other lines kept" \
	bash -c '[ "$(grep -c " boot_a.img$" "$1/meta/SHA256SUMS")" = 1 ] && ! grep -q ^deadbeef "$1/meta/SHA256SUMS" && grep -q " keep.img$" "$1/meta/SHA256SUMS" && cd "$1" && grep " boot_a.img$" meta/SHA256SUMS | sha256sum -c --quiet' _ "$d"
check "no stray SHA256SUMS.XXXXXX left in meta/" bash -c '[ -z "$(ls "$1/meta" | grep "SHA256SUMS\.")" ]' _ "$d"
sh_run "$d" a ops dump "$d" --preset boot
check "a second re-dump still leaves exactly one boot_a.img line" test "$(grep -c ' boot_a.img$' "$d/meta/SHA256SUMS")" = 1

echo "== usage (exit 2, nothing sent) =="
u() { "$tmp/sh" --dry-run "$@" >/dev/null 2>"$tmp/u.err"; echo $?; }
check "no --preset" test "$(u ops dump "$tmp/u")" = 2
check "all with another preset" test "$(u ops dump "$tmp/u" --preset all --preset boot)" = 2
check "imei with another preset" test "$(u ops dump "$tmp/u" --preset boot --preset imei)" = 2
check "a name with /" test "$(u ops dump "$tmp/u" --preset ../boot)" = 2
check "unknown option" test "$(u ops dump "$tmp/u" --preset boot --bogus 1)" = 2
check "bad --headroom" test "$(u ops dump "$tmp/u" --preset boot --headroom -1)" = 2
check "ops without dump" test "$(u ops list)" = 2
check "plan: ops dump is not a confirm-plan op (refused, nothing stored; hard OUT)" \
	bash -c '"$1" plan "${@:3}" ops dump "$2" --preset all_lite reset 2>&1 | grep -q "unknown or unplannable command: ops"' _ "$tmp/sh" "$tmp/u" "${FDLS[@]}"

echo "== menu.sh switch =="
cat > "$tmp/runner" <<R
#!/usr/bin/env bash
echo "ARGV \$*" >> "$tmp/menu.argv"
MOCK_LOG=$tmp/menu.seq exec "$tmp/sh" --usb-fd 7 "\$@" 7</dev/null
R
chmod +x "$tmp/runner"
menu_dump() { # DUMP_DIR SPDHOST_BIN FN ARGS...
	local dd=$1 bin=$2; shift 2
	: > "$tmp/menu.argv"
	MOCK_PTABLE=$tmp/pt MOCK_SLOT=a SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER="$tmp/runner" SPDHOST_BIN="$bin" \
	SPDHOST_MENU_CONFIG="$tmp/none.conf" SPDHOST_EXEC_ADDR=0x65015f08 SPDHOST_TIMEOUT=1000 SPDHOST_DUMP_DIR="$dd" \
	bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1 || exit 99
		FDL1=$2/fdl1-dl.bin FDL1_ADDR=0x65000800 FDL2=$2/fdl2-dl.bin FDL2_ADDR=0x9efffe00 DUMP_DIR=$3 BOOT_AFTER=reset
		shift 3; "$@"' _ "$root" "$tmp" "$dd" "$@" </dev/null
}
mkdir -p "$tmp/pkg"; cp "$tmp/sh" "$tmp/pkg/spdhost"
m=$tmp/m1; menu_dump "$m" "$tmp/pkg/spdhost" dump_live_session all_lite > "$tmp/m1.log" 2>&1; rc=$?
check "menu all_lite: exit 0 through ops dump" test "$rc" = 0
check "menu all_lite: argv is fdl fdl ops dump DIR --preset all_lite reset (no bash parts/dump)" \
	bash -c 'grep -q "fdl .* fdl .* ops dump $2 --preset all_lite reset$" "$1" && ! grep -q " parts " "$1"' _ "$tmp/menu.argv" "$m"
check "menu all_lite: same images + SHA256SUMS as the core run" \
	bash -c '[ "$(cd "$1" && ls *.img | tr "\n" " ")" = "$(cd "$2" && ls *.img | tr "\n" " ")" ] && cmp -s <(sort "$1/meta/SHA256SUMS") <(sort "$2/meta/SHA256SUMS")' _ "$m" "$tmp/lite"
check "menu all_lite: table cache refreshed for the next menu step" grep -q "table refreshed" "$tmp/m1.log"
m=$tmp/m2; menu_dump "$m" "$tmp/pkg/spdhost" dump_many_session boot vbmeta > "$tmp/m2.log" 2>&1; rc=$?
check "menu several names: one ops dump with a --preset each" \
	bash -c '[ "$1" = 0 ] && grep -q "ops dump $3 --preset boot --preset vbmeta reset$" "$2"' _ "$rc" "$tmp/menu.argv" "$m"
m=$tmp/m3; MOCK_FREE_BYTES=1 menu_dump "$m" "$tmp/pkg/spdhost" dump_live_session all > "$tmp/m3.log" 2>&1; rc=$?
check "menu: a core space refusal is reported as REFUSED, exit nonzero" \
	bash -c '[ "$1" != 0 ] && grep -q "REFUSED: not enough free space" "$2"' _ "$rc" "$tmp/m3.log"
# An older spdhost (no cap=ops-dump / images-list): caps prints nothing usable.
printf '#!/bin/sh\nexit 1\n' > "$tmp/old"; chmod +x "$tmp/old"
m=$tmp/m4; menu_dump "$m" "$tmp/old" dump_live_session all_lite > "$tmp/m4.log" 2>&1; rc=$?
check "older binary: the bash path (parts RAW dump all_lite DIR + verify_dump_manifest)" \
	bash -c '[ "$1" = 0 ] && grep -q " parts .*partition_list.txt dump all_lite $3 reset$" "$2" && ! grep -q " ops " "$2"' _ "$rc" "$tmp/menu.argv" "$m"
check "older binary: the bash path still writes the same SHA256SUMS" \
	cmp -s <(sort "$tmp/m4/meta/SHA256SUMS") <(sort "$tmp/lite/meta/SHA256SUMS")
i=$tmp/il; mkdir -p "$i/meta"
for f in boot_a.img vbmeta_b.img super.bin misc-slotinfo.img misc-before-1.img boot_bak.img x.img.partial table.xml; do printf j > "$i/$f"; done
"$tmp/sh" images list "$i" > "$tmp/il.txt"
rn=$(menu_dump "$i" "$tmp/pkg/spdhost" restore_image_names "$i" 2>/dev/null | tr '\n' ' ')
check "restore picker: from images list" test "$rn" = "$(cut -f1 "$tmp/il.txt" | tr '\n' ' ')"
rn_old=$(menu_dump "$i" "$tmp/old" restore_image_names "$i" 2>/dev/null | sort | tr '\n' ' ')
check "restore picker, older binary: the bash filter gives the same names" test "$rn_old" = "$rn"

echo "ops-dump: $pass passed, $fail failed"
[ "$fail" = 0 ]
