#!/usr/bin/env bash
# The menu items that expose spdhost commands the rest of the menu never
# reached: write-parts-a/-b (restore to a forced slot), check-part, erase-part,
# pack-slot, and the offline PAC reader. Driven on a pty, the way termux-usb -e
# runs the menu, because
# every one of these confirms through confirm_action/confirm_dangerous and both
# refuse without a terminal.
#
# The runner is a stub that prints its argv and exits, so this checks the
# command line the menu builds (and what it does NOT build: --yes, --dangerous)
# without needing a device. pack-slot is offline, so that one runs for real.
#
# Usage (from no-root/): tests/menu-extra.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

drive=$root/tests/pty_drive.py
menus=0
mkdir -p "$tmp/dump" "$tmp/input" "$tmp/ran"
cp "$root/fdl/ums9230/infinix/fdl1-dl.bin" "$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
# A real spdhost for pack-slot (offline). The mock FDL2 only supplies the USB
# symbols; the offline tools never open a device.
gcc -O2 -w -std=c11 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" \
	"$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" \
	"$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" \
	-o "$tmp/spdhost" || exit 1

cat >"$tmp/runner" <<R
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/ran/log"
echo "runner: \$*"
exit 0
R
chmod +x "$tmp/runner"

# A backup folder with one image per slot, so write-parts has something to
# filter. Contents do not matter: the runner is a stub.
: >"$tmp/dump/boot_a.img"; : >"$tmp/dump/boot_b.img"; : >"$tmp/dump/misc.img"

cat >"$tmp/conf" <<EOF
FDL1=$tmp/fdl1-dl.bin
FDL1_ADDR=0x65000800
FDL2=$tmp/fdl2-dl.bin
FDL2_ADDR=0x9efffe00
EXEC_ADDR=0
SOC=ums9230
DEVICE=
BOOT_AFTER=reset
EOF

# Sources the menu (functions only), loads that config, runs the named item.
cat >"$tmp/fn.sh" <<R
#!/usr/bin/env bash
source "$root/scripts/menu.sh" >/dev/null 2>&1
load_config
"\$@"
R
chmod +x "$tmp/fn.sh"

export SPDHOST_MENU_LIB=1 SPDHOST_MENU_CONFIG=$tmp/conf SPDHOST_BIN=$tmp/spdhost
export SPDHOST_MENU_RUNNER=$tmp/runner SPDHOST_DUMP_DIR=$tmp/dump
export SPDHOST_INPUT_DIR=$tmp/input TMPDIR=$tmp
unset SPDHOST_EXEC_ADDR 2>/dev/null || true

# menu ITEM [EXPECT SEND]... -- runs on a pty, transcript in $tmp/<item>.pty
menu() {
	local item=$1 tr; shift
	menus=$((menus + 1))
	# One transcript per call: the same item runs more than once.
	tr=$tmp/$item-$menus.pty
	rm -f "$tmp/ran/log"
	# pty_drive takes one shell string after --, not an argv list.
	python3 "$drive" "$tr" "$@" -- "$tmp/fn.sh $item" </dev/null
	printf '%s\n' "$tr"
}
ran_has() { grep -q -- "$1" "$tmp/ran/log" 2>/dev/null; }
ran_lacks() { ! grep -q -- "$1" "$tmp/ran/log" 2>/dev/null; }
pty_has() { grep -qF -- "$2" "$1"; }

# ------------------------------------------------- restore: forced slot
tr=$(menu restore_backup_menu \
	"type yes to restore this backup" 'yes\r' \
	"Restore to slot" 'b\r' \
	"Press Enter to continue" '\r')
check "restore [b]: the command is write-parts-b" ran_has "write-parts-b $tmp/dump"
check "restore [b]: parts runs first in the same session" ran_has "parts $tmp/dump/partition_list.txt write-parts-b"
check "restore [b]: never passes --yes" ran_lacks --yes
check "restore [b]: the pty says which slot was forced" pty_has "$tr" "forced slot b"

tr=$(menu restore_backup_menu \
	"type yes to restore this backup" 'yes\r' \
	"Restore to slot" '\r' \
	"Press Enter to continue" '\r')
check "restore [Enter]: falls back to plain write-parts" ran_has "write-parts $tmp/dump"
check "restore [Enter]: no -a/-b is passed" ran_lacks "write-parts-"

tr=$(menu restore_backup_menu \
	"type yes to restore this backup" 'no\r')
check "restore: a typed 'no' starts no session" test ! -s "$tmp/ran/log"

# --------------------------------------------- part-size (read-only)
tr=$(menu check_part_action \
	"Partition name" 'boot_a\r' \
	"Press Enter to continue" '\r')
check "part-size: parts then part-size in one session" ran_has "parts $tmp/dump/partition_list.txt part-size boot_a"
check "part-size: nothing else is sent" ran_lacks "write-part"
check "part-size: never passes --yes" ran_lacks --yes

tr=$(menu check_part_action "Partition name" 'not a name\r')
check "part-size: a bad name is refused before the plug-in wait" test ! -s "$tmp/ran/log"

# ----------------------------------------------- erase-part (dangerous)
for name in persist splloader all; do
	menu erase_part_action "Partition name to erase" "$name\r" >/dev/null
	check "erase-part $name: refused by the menu, no session" test ! -s "$tmp/ran/log"
done

tr=$(menu erase_part_action \
	"Partition name to erase" 'userdata\r' \
	"type dangerous to erase userdata" 'yes\r')
check "erase-part: 'yes' is not accepted for erase" test ! -s "$tmp/ran/log"

tr=$(menu erase_part_action \
	"Partition name to erase" 'userdata\r' \
	"type dangerous to erase userdata" 'dangerous\r' \
	"Press Enter to continue" '\r')
check "erase-part: the typed word runs parts + erase-part + reset" \
	ran_has "parts $tmp/dump/partition_list.txt erase-part userdata reset"
check "erase-part: never passes --yes (spdhost asks itself)" ran_lacks --yes

# ------------------------------------------ pack-slot (offline, for real)
# A full-size misc image: the slot block is at 0x800, so a 2048-byte file is
# not enough for spdhost to patch. 1 MiB matches the mock table's misc.
misc_in=$tmp/dump/misc-full.img
head -c 1048576 /dev/zero >"$misc_in"
misc_sha=$(sha256sum "$misc_in" | awk '{print $1}')
tr=$(menu pack_slot_action \
	"misc image" "$misc_in\r" \
	"Slot to make active" 'b\r')
out=${misc_in%.img}-slotb.img
check "pack-slot: writes <name>-slotb.img" test -f "$out"
check "pack-slot: the image keeps its size" \
	test "$(stat -c %s "$out" 2>/dev/null)" = 1048576
check "pack-slot: slot b record at 0x800 (_b, BCAB, version, nb_slot)" \
	bash -c '[ "$(dd if="$1" bs=1 skip=2048 count=2 status=none)" = _b ] &&
		[ "$(dd if="$1" bs=1 skip=2052 count=4 status=none)" = BCAB ] &&
		[ "$(od -An -tu1 -j2056 -N2 "$1" | tr -s " ")" = " 1 2" ]' _ "$out"
check "pack-slot: the input is untouched (same sha256)" \
	test "$(sha256sum "$misc_in" | awk '{print $1}')" = "$misc_sha"
check "pack-slot: the output is recorded in SHA256SUMS" \
	grep -q "misc-full-slotb.img" "$tmp/dump/SHA256SUMS"

misc_in2=$tmp/dump/misc2.img
head -c 1048576 /dev/zero >"$misc_in2"
tr=$(menu pack_slot_action "misc image" "$misc_in2\r" "Slot to make active" 'x\r')
check "pack-slot: a bad slot letter writes nothing" test ! -e "${misc_in2%.img}-slotx.img"

# promote_dump_action -- menu [9]. Filesystem only, no phone. The point is
# what it refuses to do: input/ also holds the images a user meant to flash,
# so an image already there is never replaced, and the dump folder's non-image
# files (SHA256SUMS, *.txt, *.xml, *_bak, misc-before-*) stay behind.
pd=$tmp/promote_dump
pi=$tmp/promote_input
mkdir -p "$pd" "$pi"
: >"$pd/system.img"                       # new name -> copied
head -c 100 /dev/zero >"$pd/vendor.img"   # input has the same name, other size -> skipped
printf 'BBBBBBBBBB' >"$pd/dtbo.img"        # input has the same name and size -> left alone
printf 'AAAAAAAAAA' >"$pi/dtbo.img"
printf 'KEEP' >"$pi/vendor.img"
: >"$pd/SHA256SUMS"; : >"$pd/notes.txt"; : >"$pd/partitions.xml"
: >"$pd/misc-before-1.img"; : >"$pd/uboot_bak.img"; : >"$pd/l_fixnv1.img"
pd_tr=$tmp/promote-1.pty
rm -f "$tmp/ran/log"
python3 "$drive" "$pd_tr" "type yes to copy" 'yes\r' -- \
	"SPDHOST_DUMP_DIR=$pd SPDHOST_INPUT_DIR=$pi $tmp/fn.sh promote_dump_action" </dev/null
pd_out=$(cat "$pd_tr")
check "promote: a new image is copied into input/" test -f "$pi/system.img"
check "promote: the l_fixnv1 image is copied too" test -f "$pi/l_fixnv1.img"
check "promote: an existing name with the same size keeps its own bytes" \
	test "$(cat "$pi/dtbo.img" 2>/dev/null)" = AAAAAAAAAA
check "promote: an existing name with another size is not overwritten" \
	test "$(cat "$pi/vendor.img" 2>/dev/null)" = KEEP
check "promote: SHA256SUMS is not copied" test ! -e "$pi/SHA256SUMS"
check "promote: *.txt is not copied" test ! -e "$pi/notes.txt"
check "promote: *.xml is not copied" test ! -e "$pi/partitions.xml"
check "promote: *_bak is not copied" test ! -e "$pi/uboot_bak.img"
check "promote: a misc backup image is not copied" test ! -e "$pi/misc-before-1.img"
check "promote: says which file it skipped and why" \
	bash -c '[[ $1 == *"different file of that name"* ]]' _ "$pd_out"
check "promote: points at the flash menu afterwards" \
	bash -c '[[ $1 == *"menu [6]"* ]]' _ "$pd_out"
check "promote: leaves no .new.* temporary behind" \
	bash -c '! ls "$1"/*.new.* >/dev/null 2>&1' _ "$pi"
check "promote: wrote exactly the two new names" \
	bash -c '[ "$(ls "$1" | sort | tr "\n" " ")" = "dtbo.img l_fixnv1.img system.img vendor.img " ]' _ "$pi"

# A second run has nothing left to do and must not be an error or a rewrite.
pd_tr2=$tmp/promote-2.pty
rm -f "$tmp/ran/log"
python3 "$drive" "$pd_tr2" -- \
	"SPDHOST_DUMP_DIR=$pd SPDHOST_INPUT_DIR=$pi $tmp/fn.sh promote_dump_action" </dev/null
pd_out2=$(cat "$pd_tr2")
check "promote: a second run copies nothing" \
	bash -c '[[ $1 == *"Nothing new to copy"* || $1 == *"already has every one"* ]]' _ "$pd_out2"

# Declining the confirm copies nothing.
pd2=$tmp/promote_dump2
pi2=$tmp/promote_input2
mkdir -p "$pd2" "$pi2"
head -c 3 /dev/zero >"$pd2/boot.img"
pd_tr3=$tmp/promote-3.pty
rm -f "$tmp/ran/log"
python3 "$drive" "$pd_tr3" "type yes to copy" 'no\r' -- \
	"SPDHOST_DUMP_DIR=$pd2 SPDHOST_INPUT_DIR=$pi2 $tmp/fn.sh promote_dump_action" </dev/null
check "promote: answering no copies nothing" test ! -e "$pi2/boot.img"

# ----------------------------------------------------------- PAC (offline)
# The release ships extrac.sh for this; here it is built into spdhost and
# reached from extra_menu [16]. Offline: the runner must never be called.
python3 "$root/tests/pac_fixture.py" --suite "$tmp/pacfx" >/dev/null || exit 1
cp "$tmp/pacfx/payloads.pac" "$tmp/input/"
rm -f "$tmp/ran/log"

# Enter accepts the only .pac in the flash folder; [1] is check.
tr=$(menu pac_extract_action \
	"PAC file" '\r' \
	"Choice" '1\r')
check "pac check: a good pac reports matching CRCs" pty_has "$tr" "CRCs match."
check "pac check: sends nothing over USB" test ! -s "$tmp/ran/log"

# A corrupt pac exits 0 (the vendor tool does too), so the menu has to read
# the text to say so -- otherwise [1] would report success on a bad pac.
cp "$tmp/pacfx/bad.pac" "$tmp/input/"
tr=$(menu pac_extract_action \
	"PAC file" "$tmp/input/bad.pac\r" \
	"Choice" '1\r')
check "pac check: a bad data CRC is reported as a mismatch" pty_has "$tr" "MISMATCH"
check "pac check: a bad pac sends nothing over USB" test ! -s "$tmp/ran/log"

# [2] extract everything into the default folder, <input>/extract.
tr=$(menu pac_extract_action \
	"PAC file" "$tmp/input/payloads.pac\r" \
	"Choice" '2\r' \
	"Output folder" '\r')
check "pac extract: writes the entries into <input>/extract" \
	test -s "$tmp/input/extract/system.img"
check "pac extract: the payload is the pac's bytes, not truncated" \
	test "$(stat -c %s "$tmp/input/extract/system.img")" = 8000
check "pac extract: offline, no runner session" test ! -s "$tmp/ran/log"

# [3] only the named entry.
rm -rf "$tmp/input/extract"
tr=$(menu pac_extract_action \
	"PAC file" "$tmp/input/payloads.pac\r" \
	"Choice" '3\r' \
	"Entries" 'system.img\r' \
	"Output folder" "$tmp/pac_only\r")
check "pac extract one: writes the named entry" test -s "$tmp/pac_only/system.img"
check "pac extract one: writes nothing else" \
	bash -c '[ "$(ls "$1" | tr "\n" " ")" = "system.img " ]' _ "$tmp/pac_only"

# A folder with no .pac and no answer must not fall through to an extract.
mkdir -p "$tmp/no-pac"
tr=$tmp/no-pac.pty
python3 "$drive" "$tr" "PAC file" '\r' -- \
	"SPDHOST_INPUT_DIR=$tmp/no-pac $tmp/fn.sh pac_extract_action" </dev/null
check "pac: no pac anywhere is refused before anything runs" \
	bash -c '[[ $1 == *"none in"* ]]' _ "$(cat "$tr")"

echo
echo "menu-extra: $pass passed, $fail failed"
(( fail == 0 ))
