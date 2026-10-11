#!/usr/bin/env bash
# P0-7: `spdhost images list DIR [--json] [--verify]` -- the picker list (A5):
# root only, the write-parts candidate rule (meta/ and junk hidden), the
# recorded sha256 from meta/SHA256SUMS or an old dump's root SHA256SUMS. Offline.
# Usage (from no-root/): tests/images-list.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP_TMP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
# Linked against the fake libusb: `images` must not need a device at all.
gcc -O2 -w -std=c11 -D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/plan.c" "$root/src/loaders.c" "$root/src/ops.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/events.c" \
	"$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" \
	-o "$tmp/sh" || exit 1
py=$(command -v python3 || true)

echo "== images list =="
i=$tmp/il; mkdir -p "$i/meta" "$i/sub"
for f in boot_a.img vbmeta_b.img misc.img super.bin metadata.img splloader.img; do printf '%s' "$f" > "$i/$f"; done
for f in misc-slotinfo.img misc-before-1.img persist-before-2.img vbmeta-before-3.img frp-before-4.img \
	misc-slota.img boot_bak.img boot_a.img.partial x.img.tmp y.img.unverified table.xml list.txt \
	pgpt.bin sprdpart.bin fdl1.bin custom_exec_no_verify_65015f08.bin .hidden.img SHA256SUMS; do printf j > "$i/$f"; done
printf 'x' > "$i/meta/boot_b.img"; printf 'x' > "$i/sub/boot_b.img"
( cd "$i" && sha256sum boot_a.img misc.img > meta/SHA256SUMS && printf '%064d  vbmeta_b.img\n' 0 >> meta/SHA256SUMS )
"$tmp/sh" images list "$i" > "$tmp/il.txt"; rc=$?
check "text: exit 0, the restore candidates only, sorted" \
	bash -c '[ "$1" = 0 ] && [ "$(cut -f2 "$2" | tr "\n" " ")" = "boot_a.img metadata.img misc.img splloader.img super.bin vbmeta_b.img " ]' _ "$rc" "$tmp/il.txt"
check "text: NAME FILE BYTES SHA (- when no line)" \
	bash -c 'grep -qP "^boot_a\tboot_a.img\t10\t[0-9a-f]{64}$" "$1" && grep -qP "^super\tsuper.bin\t9\t-$" "$1"' _ "$tmp/il.txt"
"$tmp/sh" images list "$i" --json --verify > "$tmp/il.json"; rc=$?
if [[ -n $py ]]; then
	check "json: valid, v 1, layout meta, 6 images, slot from the suffix" "$py" - "$tmp/il.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
assert o["v"] == 1 and o["layout"] == "meta", o
im = {x["file"]: x for x in o["images"]}
assert sorted(im) == ["boot_a.img", "metadata.img", "misc.img", "splloader.img", "super.bin", "vbmeta_b.img"], sorted(im)
assert im["boot_a.img"]["slot"] == "a" and im["vbmeta_b.img"]["slot"] == "b" and im["misc.img"]["slot"] is None
assert im["boot_a.img"]["verified"] is True and im["misc.img"]["verified"] is True
assert im["vbmeta_b.img"]["verified"] is False and len(im["vbmeta_b.img"]["sha256"]) == 64
assert im["super.bin"]["sha256"] is None and im["super.bin"]["verified"] is False
assert im["boot_a.img"]["name"] == "boot_a" and im["boot_a.img"]["bytes"] == 10
PY
else
	ok "json: python3 missing, skipped (skip)"
fi
check "json without --verify has no verified key" bash -c '! "$1" images list "$2" --json | grep -q verified' _ "$tmp/sh" "$i"
f=$tmp/flat; mkdir -p "$f"; printf 'q' > "$f/boot.img"; ( cd "$f" && sha256sum boot.img > SHA256SUMS )
check "old flat dump: layout flat, digest from the root SHA256SUMS" \
	bash -c 'o=$("$1" images list "$2" --json --verify) && [[ $o == *"\"layout\":\"flat\""* && $o == *"\"verified\":true"* ]]' _ "$tmp/sh" "$f"
check "a missing folder: exit 1" bash -c '"$1" images list "$2/nope" >/dev/null 2>&1; [ $? = 1 ]' _ "$tmp/sh" "$tmp"
check "usage: exit 2" bash -c '"$1" images >/dev/null 2>&1; a=$?; "$1" images list >/dev/null 2>&1; b=$?; "$1" images list x --bogus >/dev/null 2>&1; [ $a$b$? = 222 ]' _ "$tmp/sh"
check "images list opens no USB (runs with no device and no fd)" bash -c '"$1" images list "$2" >/dev/null' _ "$tmp/sh" "$i"
# E5: the core list == menu.sh's own bash filter (part_image_candidate) on the same folder.
menu_names=$(SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true bash -c '
	source "$1/scripts/menu.sh" >/dev/null 2>&1
	for f in "$2"/*; do [[ -f $f ]] || continue; b=$(basename "$f"); part_image_candidate "$b" && echo "${b%.*}"; done | sort | tr "\n" " "' _ "$root" "$i")
check "E5: images list == menu.sh part_image_candidate on the same folder" \
	test "$(cut -f1 "$tmp/il.txt" | tr '\n' ' ')" = "$menu_names"

e=$tmp/empty; mkdir -p "$e"
check "empty folder: exit 0, layout none, no images" \
	bash -c '[ "$("$1" images list "$2" --json)" = "{\"v\":1,\"dir\":\"$2\",\"layout\":\"none\",\"images\":[]}" ]' _ "$tmp/sh" "$e"
m=$tmp/mixed; mkdir -p "$m/meta"; printf 'r' > "$m/boot.img"; ( cd "$m" && sha256sum boot.img > SHA256SUMS )
check "meta/ without SHA256SUMS: the root one is still read (legacy fallback)" \
	bash -c '"$1" images list "$2" | grep -qP "^boot\tboot.img\t1\t[0-9a-f]{64}$"' _ "$tmp/sh" "$m"
q=$tmp/quote; mkdir -p "$q"; printf 'z' > "$q/a\"b.img"
if [[ -n $py ]]; then
	check "json escapes odd file names (still valid JSON)" bash -c '"$1" images list "$2" --json | "$3" -c "import json,sys; o=json.load(sys.stdin); assert o[\"images\"][0][\"file\"]==\"a\\\"b.img\""' _ "$tmp/sh" "$q" "$py"
fi

echo "images-list: $pass passed, $fail failed"
[ "$fail" = 0 ]
