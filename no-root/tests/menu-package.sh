#!/usr/bin/env bash
# Every resource a menu option resolves at run time is really there.
#
# This is the guard for the one defect the per-option audit found: menu [6]
# said "Flash images from input/" and the package never created that
# directory, so the folder the message named did not exist in the zip. The
# failure mode is general -- a menu that names a file, or a packaging step
# that forgets to carry one -- so both halves are checked here:
#
#   A. in the tree: every path the menu resolves (loaders, exec stubs, BCB
#      images, the flash folder, the unlock blob) resolves to a real file,
#      and the BCB bytes are the exact ones the menu hashes before writing.
#   B. in the package: scripts/cross-arm32.sh copies fdl/, misc/, input/ and
#      the wrapper into the zip. A file present in the tree but left out of
#      that copy list is invisible to every test that reads the tree, which
#      is how the missing input/ survived a green suite.
#
# No device is needed: this only sources the menu's functions.
#
# Usage (from no-root/): tests/menu-package.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "ok    $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }
# ck NAME RC -- report a status code. The condition is always written on its
# own line above so `$?` is the thing being reported, never a stale status.
ck() { if [[ $2 == 0 ]]; then ok "$1"; else bad "$1"; fi; }
# ck_has NAME HAYSTACK NEEDLE
ck_has() { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1"; fi; }

# Source the menu for its functions only. SPDHOST_MENU_LIB stops it before
# load_config and before the interactive loop. cwd stays $root so the
# package-relative lookups ($script_dir/../fdl) resolve the way they do when
# the menu is started with `bash scripts/menu.sh` from an unpacked zip.
cd "$root" || exit 1
SPDHOST_MENU_LIB=1 source "$root/scripts/menu.sh" || exit 1

# ---------------------------------------------------------------- A. the tree
echo "== the tree ships what each option resolves =="

# [6] flash images from input/ -- the defect this file exists for.
echo "input/ (menu [6])"
[[ -d $INPUT_DIR ]]
ck "[6] input directory exists: $INPUT_DIR" $?
[[ -f $INPUT_DIR/PUT-IMAGES-HERE.txt ]]
ck "[6] input/ carries its README so an empty folder is self-explaining" $?
[[ $(basename "$INPUT_DIR") == input ]]
ck "[6] the flash directory is named input" $?

# [9] copies a dump into input/. Both folders have to be there for that to
# mean anything, and the dump folder carries its own README.
echo "backup/ (menu [1] dump, [7] restore, [9] promote)"
[[ $(basename "$DUMP_DIR") == backup ]]
ck "[1] the dump directory is named backup" $?
[[ -f $DUMP_DIR/PUT-DUMPS-HERE.txt ]]
ck "[1] backup/ carries its README so an empty folder is self-explaining" $?

# [3] loaders: every model the menu offers must have its pair on disk, and
# every SoC's exec stub (both hex-mode addresses) must be there.
echo
echo "fdl/ (menu [3] loaders, ready(), hex mode)"
for soc in ums9230 sc9863a ums512; do
	while read -r brand; do
		[[ -n $brand ]] || continue
		mapfile -t pair < <(shipped_fdl_pair "$(pkg_fdl_root)" "$soc" "$brand" "" || true)
		[[ ${#pair[@]} == 2 && -f ${pair[0]} && -f ${pair[1]} ]]
		ck "[3] $soc/$brand has fdl1-dl.bin + fdl2-dl.bin" $?
		# unlock [8] writes this to uboot, so a brand the menu offers without
		# one is a brand whose unlock refuses. The reference ships one per
		# model and the menu offers exactly its chip+brand set.
		if [[ $brand == universal ]]; then
			# M2: the vendor "cboot" here was byte-identical to fdl2-dl.bin;
			# it is not shipped and unlock refuses universal outright.
			[[ ! -e $(dirname "${pair[0]}")/fdl2-cboot.bin ]]
			ck "[8] $soc/universal ships NO fdl2-cboot.bin (it was only fdl2-dl.bin)" $?
			continue
		fi
		[[ -f $(dirname "${pair[0]}")/fdl2-cboot.bin ]]
		ck "[8] $soc/$brand has fdl2-cboot.bin for unlock" $?
		# M2: every alternatif sub-model carries its own, from the root release.
		while read -r alt; do
			[[ -n $alt ]] || continue
			mapfile -t ap < <(shipped_fdl_pair "$(pkg_fdl_root)" "$soc" "$brand" "$alt" || true)
			[[ -f $(dirname "${ap[0]}")/fdl2-cboot.bin ]] &&
				! cmp -s "$(dirname "${ap[0]}")/fdl2-cboot.bin" "${ap[1]}"
			ck "[8] $soc/$brand/alternatif/$alt has its own fdl2-cboot.bin (not its fdl2-dl.bin)" $?
		done < <(shipped_alt_models "$(pkg_fdl_root)" "$soc" "$brand" || true)
	done < <(soc_brands "$soc")
	soc_profile "$soc"
	exec_stub_present "$EXEC_ADDR_DEFAULT"
	ck "[3] $soc primary exec stub $EXEC_ADDR_DEFAULT is present" $?
	exec_stub_present "$EXEC_ADDR_ALT"
	ck "[3] $soc hex-mode alternate stub $EXEC_ADDR_ALT is present" $?
done
# A model picked through alternatif/ must resolve too (realme ships them).
mapfile -t alts < <(shipped_alt_models "$(pkg_fdl_root)" ums9230 realme || true)
((${#alts[@]}))
ck "[3] realme alternatif/ models are listed" $?
for m in "${alts[@]}"; do
	mapfile -t p < <(shipped_fdl_pair "$(pkg_fdl_root)" ums9230 realme "$m" || true)
	[[ ${#p[@]} == 2 && -f ${p[0]} && -f ${p[1]} ]]
	ck "[3] ums9230/realme/$m has both loaders" $?
done
# The model argument is optional; leaving it off must not abort under set -u.
mapfile -t mainpair < <(shipped_fdl_pair "$(pkg_fdl_root)" ums9230 infinix || true)
[[ ${#mainpair[@]} == 2 ]]
ck "[3] shipped_fdl_pair without a model still returns the main pair" $?

# The BCB images menu [2]/[5] and extra [1]/[6]/[7] write. The bytes matter:
# confirm_wipe_userdata refuses anything whose sha256 is not MISC_WIPE_SHA,
# and set-active --bcb (menu [3] slot + recovery/fastbootd ending) writes what
# spdhost synthesizes, so the shipped files must be those bytes.
echo
echo "misc/ (menu [2] reboot, [5] wipe, extra [1]/[6]/[7])"
resolve_misc_dir
ck "[misc] find_misc_dir resolves to a directory with both required BCBs" $?
[[ -f $MISC_DIR/misc-recovery.bin ]]
ck "[2] misc-recovery.bin is shipped (set_slot with a recovery ending)" $?
for k in reboot-recovery reboot-fastboot; do
	if [[ $k == reboot-recovery ]]; then f=$MISC_DIR/misc-recovery.bin; else f=$MISC_DIR/misc-fastbootd.bin; fi
	[[ $(sha256sum "$f" | awk '{print $1}') == "$(misc_bcb_sha256 "$k")" ]]
	ck "[2] $(basename "$f") is byte-identical to the BCB spdhost writes for $k" $?
done
[[ $(sha256sum "$MISC_DIR/misc-wipe.bin" | awk '{print $1}') == "$MISC_WIPE_SHA" ]]
ck "[5] misc-wipe.bin matches the hash confirm_wipe_userdata enforces" $?

# Extra [8] unlock: the vendor blob has to be reachable from the default
# loaders, which is where the release keeps it.
echo
echo "unlock (extra [8])"
FDL1=$(pkg_fdl_root)/ums9230/infinix/fdl1-dl.bin
c=$(find_user_file fdl2-cboot.bin || true)
[[ -n $c && -f $c ]]
ck "[8] fdl2-cboot.bin is reachable from the default ums9230/infinix loaders" $?

# An alternatif sub-model is its own phone. c53 is not c31 and neither is the
# brand-level realme image, so the lookup must NOT climb out of the sub-model's
# folder and answer with the generic one: that image is what unlock writes to
# uboot, and the wrong one is a brick. It has to come back empty and refuse.
mapfile -t alts < <(shipped_alt_models "$(pkg_fdl_root)" ums9230 realme || true)
mapfile -t altpair < <(shipped_fdl_pair "$(pkg_fdl_root)" ums9230 realme "${alts[0]}" || true)
altsub=$(dirname "${altpair[0]}")
[[ -n $altsub && -d $altsub ]]
ck "[8] an alternatif sub-model resolves a loader directory" $?
# find_user_file reads these three globals; the harness has already sourced the
# menu, so set them the way select_shipped_model would and call it directly.
_soc=$SOC _dev=$DEVICE _f1=$FDL1 _f2=$FDL2
SOC=ums9230 DEVICE="realme/${alts[0]}" FDL1="${altpair[0]}" FDL2="${altpair[1]}"
got=$(find_user_file fdl2-cboot.bin || true)
[[ $got == "$altsub/fdl2-cboot.bin" ]]
ck "[8] an alternatif sub-model finds its OWN fdl2-cboot.bin, never the brand-level one" $?
# M3: with a model chosen, a stray fdl2-cboot.bin in the working directory is
# never picked up, even when the model's own folder has none.
_pwd=$PWD; strayd=$(mktemp -d); cd "$strayd"; printf x > fdl2-cboot.bin
SOC=ums9230 DEVICE=universal FDL1="$(pkg_fdl_root)/ums9230/universal/fdl1-dl.bin" FDL2="$(pkg_fdl_root)/ums9230/universal/fdl2-dl.bin"
got=$(find_user_file fdl2-cboot.bin || true)
[[ -z $got ]]
ck "[8] DEVICE set: \$PWD/fdl2-cboot.bin is not a fallback (got '${got}')" $?
unl=$(unlock_bootloader_menu 2>&1 </dev/null)
grep -q "no model-specific fdl2-cboot.bin" <<<"$unl" && ! grep -q "erase" <<<"$(grep -i '^+ ' <<<"$unl")"
ck "[8] unlock refuses the universal set before anything is sent" $?
cd "$_pwd"; rm -rf "$strayd"
# ...but the same lookup from the brand-level loaders still finds it, so the
# rule above cannot have been met by refusing the lookup outright.
mapfile -t bpair < <(shipped_fdl_pair "$(pkg_fdl_root)" ums9230 realme || true)
SOC=ums9230 DEVICE=realme FDL1="${bpair[0]}" FDL2="${bpair[1]}"
got=$(find_user_file fdl2-cboot.bin || true)
[[ $got == "$(dirname "${bpair[0]}")/fdl2-cboot.bin" ]]
ck "[8] the brand-level loaders still find their own fdl2-cboot.bin" $?
SOC=$_soc DEVICE=$_dev FDL1=$_f1 FDL2=$_f2

# The startup wizard's [1] answer, and the vendor set it comes from.
echo
echo "universal, the startup wizard's generic ums9230 set"
uni=$(pkg_fdl_root)/ums9230/universal
for f in fdl1-dl.bin fdl2-dl.bin; do
	[[ -f $uni/$f ]]
	ck "[wizard] fdl/ums9230/universal/$f ships" $?
done
# M2: the vendor zip's universal "fdl2-cboot.bin" was the same bytes as its
# fdl2-dl.bin -- not an unlock uboot -- so it is no longer shipped.
[[ ! -e $uni/fdl2-cboot.bin ]]
ck "[wizard] universal ships no fdl2-cboot.bin (unlock refuses universal)" $?
[[ $(grep -c '^universal$' < <(soc_brands ums9230)) == 1 ]]
ck "[wizard] ums9230 offers exactly one universal entry" $?
[[ $(soc_brands ums9230 | tail -1) == universal ]]
ck "[wizard] universal is offered last, so the brand indices do not move" $?
# The pair must be the one the release menu's UMS9230 choice uses, at the
# addresses soc_profile derives, or the wizard would save a mismatched config.
mapfile -t upair < <(shipped_fdl_pair "$(pkg_fdl_root)" ums9230 universal || true)
[[ ${#upair[@]} == 2 && ${upair[0]} == "$uni/fdl1-dl.bin" && ${upair[1]} == "$uni/fdl2-dl.bin" ]]
ck "[wizard] shipped_fdl_pair resolves the universal set" $?
soc_profile ums9230
[[ $EXEC_ADDR_DEFAULT == 0x65015f08 ]]
ck "[wizard] ums9230 exec stub is the one the universal fdl2 needs" $?

# The offline image tools the menu calls instead of the release's x86-64 ones.
echo
echo "spdhost image tools (unlock [8], extra [14], unpac)"
b=$(resolve_spdhost_bin || true)
[[ -n $b && -x $b ]]
ck "[tools] resolve_spdhost_bin finds an executable" $?
if [[ -n $b ]]; then
	spdhost_has_image_tools
	ck "[tools] this build has the built-in image tools" $?
	for t in gen-spl-unlock gen-spl-unlock-legacy gen-fdl1-dl chsize unpac; do
		[[ $("$b" "$t" 2>&1) == *"$t"* ]]
		ck "[tools] $t answers with its usage" $?
	done
else
	bad "[tools] no spdhost binary to probe"
fi

# ------------------------------------------------------------- B. the package
# The half that would have caught the original input/ defect: the tree was
# fine, the zip was not. Asserted against the packaging block itself, since
# assembling a real package needs zig and a libusb cross build.
echo
echo "== scripts/cross-arm32.sh copies what the menu needs =="
pkg_src=$(cat "$root/scripts/cross-arm32.sh")
ck_has "packaging copies the menu and the wrapper" "$pkg_src" \
	'"$root/scripts/"*.sh "$root/scripts/spdhost-usb"'
ck_has "packaging copies fdl/ (loaders)" "$pkg_src" \
	'cp -r "$root/fdl" "$pkg/fdl"'
ck_has "packaging copies misc/ (BCB images)" "$pkg_src" \
	'cp -r "$root/misc" "$pkg/misc"'
ck_has "packaging creates input/ (menu [6])" "$pkg_src" \
	'mkdir -p "$pkg/input"'
ck_has "packaging fills input/ with its README" "$pkg_src" \
	'"$root/input/"*.txt "$pkg/input/"'
ck_has "packaging creates backup/ (menu [1] dump folder)" "$pkg_src" \
	'mkdir -p "$pkg/backup"'
ck_has "packaging fills backup/ with its README" "$pkg_src" \
	'"$root/backup/"*.txt "$pkg/backup/"'
ck_has "packaging copies the binary" "$pkg_src" \
	'cp "$OUT/spdhost" "$pkg/spdhost"'
ck_has "packaging copies README.md" "$pkg_src" \
	'"$root/README.md"'

echo
echo "menu-package: $pass passed, $fail failed"
(( fail == 0 ))
