#!/usr/bin/env bash
# Mock end-to-end check of scripts/menu.sh dump paths against vendored spd_dump.
# Both spdhost and spd_dump are linked against tests/mock_fdl2.c (fake libusb
# BootROM -> FDL1 -> FDL2 with a KiB partition table). The menu is sourced with
# SPDHOST_MENU_LIB=1 and SPDHOST_MENU_RUNNER pointing at the mock spdhost.
# Usage (from no-root/): tests/menu-dump.sh
# The 6 GiB case needs 6 GiB of free space in TMPDIR; it skips itself when there
# is less (TEST_BIG=0 skips, TEST_BIG=1 forces the attempt).
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=${TEST_TMP:-$(mktemp -d)}; [[ -n ${TEST_TMP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

make -C "$root/spd_dump" GITVER.h >/dev/null
mkdir -p "$tmp/pkg/fdl/ums9230"
gcc -O2 -w -std=c11 -D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/pkg/spdhost" || exit 1
gcc -O1 -w -std=c99 -D_GNU_SOURCE -DUSE_LIBUSB=1 -D__ANDROID__ -I"$root/spd_dump" -I"$root/tests" \
	"$root/spd_dump/spd_dump.c" "$root/spd_dump/common.c" "$root/tests/mock_fdl2.c" -lm -lpthread -o "$tmp/spd_dump" || exit 1
gcc -O2 -w -I"$root/tests" "$root/tests/gen_expected.c" -o "$tmp/gen_expected" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$tmp/pkg/fdl/ums9230/"
cp "$root/fdl/ums9230/infinix/fdl1-dl.bin" "$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cat > "$tmp/runner" <<R
#!/usr/bin/env bash
MOCK_LOG=\${MOCK_LOG:-$tmp/mock.seq} exec "$tmp/pkg/spdhost" --usb-fd 7 "\$@" 7</dev/null
R
chmod +x "$tmp/runner"
# KiB units, as eMMC FDL2 reports them (spd_dump divisor stays 10).
# (spd_dump's heuristic: any entry < 1024 units lowers the divisor, i.e. the
# table is then read as bigger units. menu.sh copies that rule exactly.)
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' \
	'userdata 8192' 'cache 2048' 'blackbox 1024' > "$tmp/pt"

export SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER="$tmp/runner" SPDHOST_MENU_CONFIG="$tmp/none.conf"
export SPDHOST_EXEC_ADDR=0x65015f08 SPDHOST_TIMEOUT=1000
# shellcheck source=/dev/null
source "$root/scripts/menu.sh" || { echo "cannot source menu.sh"; exit 1; }
FDL1="$tmp/fdl1-dl.bin" FDL1_ADDR=0x65000800 FDL2="$tmp/fdl2-dl.bin" FDL2_ADDR=0x9efffe00
# Dump side files live under DUMP_DIR/meta/ (legacy: DUMP_DIR itself).
meta_of() { dump_meta_file "$1" read; }
sums_of() { dump_meta_file SHA256SUMS read; }


spd_all() { # DIR MODE ENV...
	local d=$1 m=$2; shift 2; mkdir -p "$d"
	cp "$tmp/pkg/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$d/"
	( cd "$d" && env "$@" MOCK_LOG="$d/sd.seq" TERMUX_USB_FD=7 timeout 120 "$tmp/spd_dump" \
		exec_addr 0x65015f08 fdl "$tmp/fdl1-dl.bin" 0x65000800 fdl "$tmp/fdl2-dl.bin" 0x9efffe00 \
		exec r "$m" reset 7</dev/null </dev/null >sd.log 2>&1 )
}
# Same files, same bytes: menu DIR/*.img vs spd_dump DIR/*.bin (misc/splloader too).
same_as_spd() { # MENUDIR SPDDIR
	local m=$1 s=$2 f n rc=0 a b
	a=$(cd "$m" && ls *.img 2>/dev/null | grep -vx misc-slotinfo.img | sed 's/\.img$//' | sort | tr '\n' ' ')
	b=$(cd "$s" && ls *.bin | grep -v -e '^fdl' -e '^custom_exec' -e '^sprdpart' | sed 's/\.bin$//' | sort | tr '\n' ' ')
	[[ $a == "$b" ]] || { echo "  menu: $a"; echo "  spd_dump: $b"; return 1; }
	for n in $a; do cmp -s "$m/$n.img" "$s/$n.bin" || { echo "  $n differs"; rc=1; }; done
	return $rc
}

# ---- case 1: KiB partition table -> bytes, misc 1048576 like spd_dump ----
DUMP_DIR=$tmp/b1
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a
fetch_parts_table </dev/null >"$tmp/c1.log" 2>&1
check "KiB table: parts session ok" test -s "$(meta_of partition_list.txt)"
check "KiB table: raw units kept (boot_a 4096)" grep -qx 'boot_a 4096' "$(meta_of partition_list.txt)"
check "KiB table: bytes = units<<10 (boot_a 4194304, misc 1048576)" \
	bash -c "grep -qx 'boot_a 4194304' '$(meta_of partition_bytes.txt)' && grep -qx 'misc 1048576' '$(meta_of partition_bytes.txt)'"
check "KiB table: shift 10 like spd_dump" test "$PARTS_SHIFT" = 10
# Every table read also leaves the XML a repartition edit is made from, in the
# folder the dumps go to (spd_dump writes the same file wherever it runs).
autox=$(ls "$(dump_meta_dir)"/partition_*.xml 2>/dev/null | head -1)
check "KiB table: the parts session left partition_<unixtime>.xml in the dump folder" \
	test -n "$autox"
check "auto XML is the live table in MiB (boot_a 4096 KiB -> 4, last row 0xffffffff)" \
	bash -c "grep -q 'Partition id=\"boot_a\" size=\"4\"' '$autox' &&
		grep -q 'Partition id=\"blackbox\" size=\"0xffffffff\"' '$autox'"
check "fmt_size 4194304=4M 1572864=1.5M 262144=256K 6442450944=6G" \
	test "$(fmt_size 4194304) $(fmt_size 1572864) $(fmt_size 262144) $(fmt_size 6442450944)" = "4M 1.5M 256K 6G"
sz=$(stat -c %s "$(meta_of misc-slotinfo.img)" 2>/dev/null || echo 0)
check "slot record is 32 bytes at misc+0x800 (got $sz)" test "$sz" = 32
spd_all "$tmp/s1" all_lite MOCK_PTABLE="$tmp/pt" MOCK_SLOT=a
dd if="$tmp/s1/misc.bin" of="$tmp/slot.exp" bs=1 skip=2048 count=32 status=none
check "slot record == spd_dump misc.bin[0x800:0x820]" cmp -s "$(meta_of misc-slotinfo.img)" "$tmp/slot.exp"
# One READ_MIDST: 32 bytes at offset 0x800 (le32 length, le32 offset). Not a 1 MiB misc read.
check "slot read is one 32-byte MIDST at 0x800" \
	grep -q '^SEQ 11 len=8 2000000000080000 ' "$tmp/mock.seq"
check "slot a detected" test "$ACTIVE_SLOT" = a
dump_matched_parts all_lite "$(parts_bytes_path)" </dev/null >"$tmp/c1d.log" 2>&1; rc=$?
check "slot a all_lite rc=0 ($rc)" test "$rc" = 0
check "slot a all_lite == spd_dump r all_lite (files+bytes, incl. splloader 256K)" same_as_spd "$DUMP_DIR" "$tmp/s1"
check "SHA256SUMS verifies under meta/" bash -c "[ -f '$DUMP_DIR/meta/SHA256SUMS' ] && [ ! -e '$DUMP_DIR/SHA256SUMS' ] && cd '$DUMP_DIR' && sha256sum -c --quiet meta/SHA256SUMS"

# ---- case 2: slot b ----
DUMP_DIR=$tmp/b2
export MOCK_SLOT=b
fetch_parts_table </dev/null >"$tmp/c2.log" 2>&1
check "slot b detected from misc" test "$ACTIVE_SLOT" = b
check "slot b: 'boot' resolves to boot_b" test "$(resolve_part_query boot "$(parts_bytes_path)")" = "boot_b 4194304"
check "splloader by name resolves to 262144" test "$(resolve_part_query splloader.img "$(parts_bytes_path)")" = "splloader 262144"
dump_matched_parts all_lite "$(parts_bytes_path)" </dev/null >"$tmp/c2d.log" 2>&1; rc=$?
spd_all "$tmp/s2" all_lite MOCK_PTABLE="$tmp/pt" MOCK_SLOT=b
check "slot b all_lite rc=0, keeps _b, drops _a" \
	bash -c "[ $rc = 0 ] && [ -f '$DUMP_DIR/boot_b.img' ] && [ ! -e '$DUMP_DIR/boot_a.img' ] && [ ! -e '$DUMP_DIR/uboot_a.img' ]"
check "slot b all_lite == spd_dump r all_lite" same_as_spd "$DUMP_DIR" "$tmp/s2"
DUMP_DIR=$tmp/b2all; mkdir -p "$DUMP_DIR/meta"; cp "$tmp/b2/meta/partition_list.txt" "$tmp/b2/meta/misc-slotinfo.img" "$DUMP_DIR/meta/"
load_parts_state
dump_matched_parts all "$(parts_bytes_path)" </dev/null >"$tmp/c2a.log" 2>&1; rc=$?
spd_all "$tmp/s2all" all MOCK_PTABLE="$tmp/pt" MOCK_SLOT=b
check "all (rc=$rc) == spd_dump r all (both slots, splloader, no userdata/cache/blackbox)" same_as_spd "$DUMP_DIR" "$tmp/s2all"

# ---- case 3: one partition fails, the rest still dumped ----
DUMP_DIR=$tmp/b3; mkdir -p "$DUMP_DIR/meta"; cp "$tmp/b2/meta/partition_list.txt" "$tmp/b2/meta/misc-slotinfo.img" "$DUMP_DIR/meta/"
load_parts_state
echo stale > "$DUMP_DIR/boot_b.img"   # an older file must not pass the size check
MOCK_FAIL_MID=boot_b dump_matched_parts all "$(parts_bytes_path)" </dev/null >"$tmp/c3.log" 2>&1; rc=$?
check "failure: nonzero rc ($rc)" test "$rc" != 0
check "failure: failed list names boot_b only" grep -qx 'FAILED (1 of 6): boot_b' "$tmp/c3.log"
check "failure: boot_b.img.partial kept, short" bash -c "[ -f '$DUMP_DIR/boot_b.img.partial' ] && (( \$(stat -c %s '$DUMP_DIR/boot_b.img.partial') < 4194304 ))"
check "failure: previous boot_b.img kept, not in SHA256SUMS" \
	bash -c "[ \"\$(cat '$DUMP_DIR/boot_b.img')\" = stale ] && ! grep -q ' boot_b.img\$' '$(sums_of)'"
check "failure: partitions after it still dumped + verified" \
	bash -c "cd '$DUMP_DIR' && [ \$(wc -l < meta/SHA256SUMS) = 5 ] && grep -q ' uboot_b.img\$' meta/SHA256SUMS && sha256sum -c --quiet meta/SHA256SUMS"
check "failure: spdhost logged the failed partition" grep -q 'dump failed (1): boot_b' "$tmp/c3.log"
check "failure: older boot_b.img called out" grep -q 'OLDER copy' "$tmp/c3.log"
DUMP_DIR=$tmp/b3n; mkdir -p "$DUMP_DIR/meta"; cp "$tmp/b2/meta/partition_list.txt" "$tmp/b2/meta/misc-slotinfo.img" "$DUMP_DIR/meta/"
load_parts_state
MOCK_FAIL_START=uboot_a dump_matched_parts all "$(parts_bytes_path)" </dev/null >"$tmp/c3n.log" 2>&1; rc=$?
check "READ_START NACK: rc=$rc, uboot_a failed (no file), 5 others ok" \
	bash -c "[ $rc != 0 ] && grep -qx 'FAILED (1 of 6): uboot_a' '$tmp/c3n.log' && [ ! -e '$DUMP_DIR/uboot_a.img' ] && [ \$(wc -l < '$(sums_of)') = 5 ]"

# ---- case 4: > 4 GiB partition (6 GiB = 6291456 KiB), end to end ----
DUMP_DIR=$tmp/b4
printf '%s\n' 'misc 1024' 'bigpart 6291456' > "$tmp/pt4"
export MOCK_PTABLE=$tmp/pt4
unset MOCK_SLOT
fetch_parts_table </dev/null >"$tmp/c4.log" 2>&1
m=$(resolve_part_query bigpart "$(parts_bytes_path)")
check "6 GiB: 6291456 KiB -> 6442450944 bytes (got '$m')" test "$m" = "bigpart 6442450944"
# Capture first, grep second. Piping show_parts_list straight into `grep -q`
# races with pipefail: grep exits the moment it matches, show_parts_list takes
# SIGPIPE on the rest of its output, and the pipeline returns 141. Whether that
# happens depends on the writer getting ahead of the reader, so the check passed
# or failed run to run.
list_6g() { local out; out=$(show_parts_list "$(parts_bytes_path)") || return 1; grep -Eq '^bigpart +6G +6442450944$' <<<"$out"; }
check "6 GiB: list shows 6G" list_6g
# A 6 GiB image needs 6 GiB of room. Without this guard a small box (or a
# tmpfs TMPDIR) fails the write mid-way, fills the filesystem, and takes every
# case after this one down with it -- failures that look like regressions but
# are only disk. TEST_BIG=1 forces the attempt anyway.
big_free=$(df -Pk "$tmp" 2>/dev/null | awk 'NR==2 { print $4 }')
big_why="TEST_BIG=0"
# Only an unset TEST_BIG auto-skips: an explicit 0 or 1 is the caller's call.
if [[ -z ${TEST_BIG:-} && ${big_free:-0} -lt 7340032 ]]; then
	TEST_BIG=0
	big_why="only $(( ${big_free:-0} / 1024 )) MiB free; TEST_BIG=1 forces it"
fi
if [[ ${TEST_BIG:-1} != 0 ]]; then
	DQ_NAMES=(bigpart) DQ_SIZES=(6442450944) DQ_OUTS=("$DUMP_DIR/bigpart.img")
	SPDHOST_STEP=0xf800 MOCK_ZERO=bigpart run_dump_queue </dev/null >"$tmp/c4d.log" 2>&1; rc=$?
	want=$(head -c 6442450944 /dev/zero | sha256sum | cut -c1-64)
	check "6 GiB read (step 0xf800 via SPDHOST_STEP): rc=$rc size+sha256 ok" \
		bash -c "[ $rc = 0 ] && grep -q '^$want  bigpart.img\$' '$(sums_of)'"
	check "6 GiB read used 64-bit frames past 4 GiB" \
		bash -c "grep -q '^SEQ 11 len=12 00f8000000000000' '$tmp/mock.seq' && grep -c '^SEQ 11 len=12' '$tmp/mock.seq' | awk '{exit !(\$1 > 100000)}'"
	rm -f "$DUMP_DIR/bigpart.img"
else
	echo "SKIP: 6 GiB read ($big_why)"
fi

# ---- case 5: refresh + dump in ONE session (spdhost `parts FILE dump ...`) ----
export MOCK_PTABLE=$tmp/pt
sessions() { grep -c '^+ ' "$1"; }
DUMP_DIR=$tmp/b5; export MOCK_SLOT=b
dump_live_session all_lite </dev/null >"$tmp/c5.log" 2>&1; rc=$?
spd_all "$tmp/s5" all_lite MOCK_PTABLE="$tmp/pt" MOCK_SLOT=b
check "one-session all_lite (slot b): 1 spdhost run, rc=$rc" bash -c "[ $rc = 0 ] && [ \$(grep -c '^+ ' '$tmp/c5.log') = 1 ] && grep -q ' parts .* dump all_lite ' '$tmp/c5.log'"
check "one-session all_lite == spd_dump r all_lite (slot b)" same_as_spd "$DUMP_DIR" "$tmp/s5"
check "one-session: table cache refreshed, slot b, SHA256SUMS ok" \
	bash -c "grep -qx 'boot_b 4096' '$(meta_of partition_list.txt)' && [ '$ACTIVE_SLOT' = b ] && cd '$DUMP_DIR' && [ \$(wc -l < meta/SHA256SUMS) = 4 ] && sha256sum -c --quiet meta/SHA256SUMS"
DUMP_DIR=$tmp/b6
dump_live_session all </dev/null >"$tmp/c6.log" 2>&1; rc=$?
spd_all "$tmp/s6" all MOCK_PTABLE="$tmp/pt" MOCK_SLOT=b
check "one-session all (rc=$rc) == spd_dump r all" same_as_spd "$DUMP_DIR" "$tmp/s6"
DUMP_DIR=$tmp/b7
t=$(live_dump_target boot.img "$tmp/none")
dump_live_session "$t" </dev/null >"$tmp/c7.log" 2>&1; rc=$?
"$tmp/gen_expected" boot_b 0 4194304 > "$tmp/boot_b.exp"
check "one-session single 'boot.img' (no cache) -> boot_b from live slot, rc=$rc" \
	bash -c "[ $rc = 0 ] && [ '$t' = boot ] && cmp -s '$DUMP_DIR/boot_b.img' '$tmp/boot_b.exp' && grep -q ' boot_b.img\$' '$(sums_of)' && [ ! -e '$DUMP_DIR/boot_a.img' ]"
# cached table said slot a (boot_a) but the live device is slot b: live wins
t=$(ACTIVE_SLOT=a; live_dump_target boot "$tmp/b1/meta/partition_bytes.txt")
check "cached match boot_a is passed as 'boot' so the live slot decides ($t)" test "$t" = boot
DUMP_DIR=$tmp/b8
t=$(live_dump_target splloader "$tmp/none")
dump_live_session "$t" </dev/null >"$tmp/c8.log" 2>&1; rc=$?
check "one-session splloader: 262144 bytes, rc=$rc" bash -c "[ $rc = 0 ] && [ \$(stat -c %s '$DUMP_DIR/splloader.img') = 262144 ]"
DUMP_DIR=$tmp/b9; mkdir -p "$DUMP_DIR"; echo stale > "$DUMP_DIR/boot_b.img"
MOCK_FAIL_MID=boot_b dump_live_session all </dev/null >"$tmp/c9.log" 2>&1; rc=$?
check "one-session keep-going: rc=$rc, boot_b failed, others verified" \
	bash -c "[ $rc != 0 ] && grep -qx 'FAILED (1 of 6): boot_b' '$tmp/c9.log' && [ -f '$DUMP_DIR/boot_b.img.partial' ] && [ \"\$(cat '$DUMP_DIR/boot_b.img')\" = stale ] && grep -q 'OLDER copy' '$tmp/c9.log' && cd '$DUMP_DIR' && [ \$(wc -l < meta/SHA256SUMS) = 5 ] && sha256sum -c --quiet meta/SHA256SUMS"
DUMP_DIR=$tmp/b10
dump_live_session nosuch </dev/null >"$tmp/c10.log" 2>&1; rc=$?
check "one-session unknown name: nonzero rc ($rc), reported" bash -c "[ $rc != 0 ] && grep -q 'nosuch(not in live table)' '$tmp/c10.log'"
# dump_partition end to end (answers on stdin): cached table + 'y' refresh -> one session
DUMP_DIR=$tmp/b11; mkdir -p "$DUMP_DIR/meta"; cp "$tmp/b1/meta/partition_list.txt" "$DUMP_DIR/meta/"
cls() { :; }; pause() { :; }; ready() { :; }
printf 'y\nall_lite\n' | dump_partition >"$tmp/c11.log" 2>&1; rc=$?
check "menu Refresh=y then all_lite: ONE session, slot b live (rc=$rc)" \
	bash -c "[ $rc = 0 ] && [ \$(grep -c '^+ ' '$tmp/c11.log') = 1 ] && [ -f '$DUMP_DIR/boot_b.img' ] && [ ! -e '$DUMP_DIR/boot_a.img' ]"
DUMP_DIR=$tmp/b12; mkdir -p "$DUMP_DIR/meta"; cp "$tmp/b2/meta/partition_list.txt" "$tmp/b2/meta/misc-slotinfo.img" "$DUMP_DIR/meta/"
printf 'n\nboot\n' | dump_partition >"$tmp/c12.log" 2>&1; rc=$?
check "menu Refresh=n still re-reads the live table and slot (rc=$rc)" \
	bash -c "[ $rc = 0 ] && grep -q ' parts .* dump boot ' '$tmp/c12.log' && cmp -s '$DUMP_DIR/boot_b.img' '$tmp/boot_b.exp'"
check "menu never passes --yes" bash -c "! grep -h '^+ ' '$tmp'/c*.log | grep -q -- '--yes'"

# ---- case 6: guarded misc write via the menu helper ----
# The menu's typed confirm sets MISC_CONFIRM_TOKEN (sha256 of the bytes to
# write); guarded_misc_session passes it as --confirm-token. No --yes anywhere.
unset MOCK_SLOT
DUMP_DIR=$tmp/g1
MISC_CONFIRM_TOKEN=$(misc_bcb_sha256 reboot-fastboot)
MOCK_MISC_OUT=$tmp/g1.misc guarded_misc_session reboot-fastboot reboot-fastboot </dev/null >"$tmp/g1.log" 2>&1; rc=$?
b=$(ls "$(dump_meta_dir)"/misc-before-*.img "$DUMP_DIR"/misc-before-*.img 2>/dev/null | head -1)
"$tmp/gen_expected" misc 0 1048576 > "$tmp/misc0.exp"
check "guarded reboot-fastboot: rc=$rc, backup 1 MiB == old misc, sha recorded, verified" \
	bash -c "[ $rc = 0 ] && cmp -s '$b' '$tmp/misc0.exp' && grep -qE ' (meta/)?${b##*/}\$' '$(sums_of)' && grep -q 'misc-verify: OK' '$tmp/g1.log' && [ \$(grep -c '^+ ' '$tmp/g1.log') = 1 ]"
check "guarded: menu command line has --confirm-token=<BCB sha>, no --yes" bash -c "grep '^+ ' '$tmp/g1.log' | grep -q -- '--confirm-token=$(misc_bcb_sha256 reboot-fastboot)' && ! grep '^+ ' '$tmp/g1.log' | grep -q -- '--yes'"
DUMP_DIR=$tmp/g2
MISC_CONFIRM_TOKEN=$(misc_bcb_sha256 reboot-recovery)
MOCK_FAIL_MID=misc guarded_misc_session reboot-recovery reboot-recovery </dev/null >"$tmp/g2.log" 2>&1; rc=$?
check "guarded: failed pre-dump aborts: rc=$rc, no misc write, no reset, no backup kept" \
	bash -c "[ $rc != 0 ] && grep -q 'misc-backup FAILED' '$tmp/g2.log' && grep -q 'write was NOT done' '$tmp/g2.log' && ! grep -qE '^SEQ (02 len=2048|05 )' '$tmp/mock.seq' && ! ls '$DUMP_DIR'/misc-before-*.img '$DUMP_DIR'/meta/misc-before-*.img >/dev/null 2>&1"
DUMP_DIR=$tmp/g3; mkdir -p "$DUMP_DIR"
MISC_CONFIRM_TOKEN=$(sha256sum "$b" | awk '{print $1}')
MOCK_MISC_OUT=$tmp/g3.misc guarded_misc_session "restore misc" write-part misc "$b" reset </dev/null >"$tmp/g3.log" 2>&1; rc=$?
check "guarded restore from backup: rc=$rc, misc == backup" bash -c "[ $rc = 0 ] && cmp -s '$tmp/g3.misc' '$b'"

# ---- SHA256SUMS under meta/ (new) vs dump-root (legacy) ----
# New dumps already asserted meta/SHA256SUMS above ("SHA256SUMS verifies under
# meta/"). Flash/restore verify reads the same file via dump_meta_file.
DUMP_DIR=$tmp/b1
check "flash verify: dump_meta_file SHA256SUMS prefers meta/" \
	bash -c "[ \"$(dump_meta_file SHA256SUMS read)\" = '$DUMP_DIR/meta/SHA256SUMS' ] &&
		cd '$DUMP_DIR' && sha256sum -c --quiet meta/SHA256SUMS"
# Older dump layout: SHA256SUMS next to the images still verifies, and the
# first write migrates it into meta/.
DUMP_DIR=$tmp/legacy_sums
mkdir -p "$DUMP_DIR"
printf 'legacy-img\n' > "$DUMP_DIR/boot.img"
( cd "$DUMP_DIR" && sha256sum boot.img > SHA256SUMS )
check "legacy: reader falls back to dump-root SHA256SUMS" \
	bash -c "[ \"$(dump_meta_file SHA256SUMS read)\" = '$DUMP_DIR/SHA256SUMS' ]"
check "legacy: root SHA256SUMS still verifies" \
	bash -c "cd '$DUMP_DIR' && sha256sum -c --quiet SHA256SUMS"
record_sha256 "$DUMP_DIR/boot.img" >/dev/null
check "legacy: first write migrates SHA256SUMS into meta/" \
	bash -c "[ -f '$DUMP_DIR/meta/SHA256SUMS' ] && [ ! -e '$DUMP_DIR/SHA256SUMS' ] &&
		cd '$DUMP_DIR' && sha256sum -c --quiet meta/SHA256SUMS"


# nv1: spd_dump reads the nv2 name from offset 512, file keeps the nv1 name.
# Units stay >= 1024 so the KiB divisor does not change (128 would).
printf '%s\n' 'l_fixnv1 1024' 'l_fixnv2 1024' 'misc 1024' 'uboot_a 1024' > "$tmp/ptnv"
DUMP_DIR=$tmp/bnv
export MOCK_PTABLE=$tmp/ptnv MOCK_SLOT=a
dump_live_session l_fixnv1 </dev/null >"$tmp/cnv.log" 2>&1; rc=$?
spd_all "$tmp/snv" l_fixnv1 MOCK_PTABLE="$tmp/ptnv" MOCK_SLOT=a
check "nv1 dump matches spd_dump (nv2 at +512, 1048064 bytes, rc=$rc)" \
	bash -c "[ $rc = 0 ] && [ -f '$tmp/snv/l_fixnv1.bin' ] && cmp -s '$DUMP_DIR/l_fixnv1.img' '$tmp/snv/l_fixnv1.bin' && [ \$(stat -c %s '$DUMP_DIR/l_fixnv1.img') = 1048064 ]"

echo "menu-dump: $pass passed, $fail failed"
(( fail == 0 ))
