#!/usr/bin/env bash
# Mock end-to-end check of scripts/menu.sh dump paths against vendored spd_dump.
# Both spdhost and spd_dump are linked against tests/mock_fdl2.c (fake libusb
# BootROM -> FDL1 -> FDL2 with a KiB partition table). The menu is sourced with
# SPDHOST_MENU_LIB=1 and SPDHOST_MENU_RUNNER pointing at the mock spdhost.
# Usage (from no-root/): tests/menu-dump.sh      TEST_BIG=0 skips the 6 GiB case.
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
	"$root/src/main.c" "$root/src/usb.c" "$root/src/proto.c" "$root/tests/mock_fdl2.c" -o "$tmp/pkg/spdhost" || exit 1
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
check "KiB table: parts session ok" test -s "$DUMP_DIR/partition_list.txt"
check "KiB table: raw units kept (boot_a 4096)" grep -qx 'boot_a 4096' "$DUMP_DIR/partition_list.txt"
check "KiB table: bytes = units<<10 (boot_a 4194304, misc 1048576)" \
	bash -c "grep -qx 'boot_a 4194304' '$DUMP_DIR/partition_bytes.txt' && grep -qx 'misc 1048576' '$DUMP_DIR/partition_bytes.txt'"
check "KiB table: shift 10 like spd_dump" test "$PARTS_SHIFT" = 10
check "fmt_size 4194304=4M 1572864=1.5M 262144=256K 6442450944=6G" \
	test "$(fmt_size 4194304) $(fmt_size 1572864) $(fmt_size 262144) $(fmt_size 6442450944)" = "4M 1.5M 256K 6G"
sz=$(stat -c %s "$DUMP_DIR/misc-slotinfo.img" 2>/dev/null || echo 0)
check "misc read is 1048576 bytes (got $sz)" test "$sz" = 1048576
spd_all "$tmp/s1" all_lite MOCK_PTABLE="$tmp/pt" MOCK_SLOT=a
check "misc bytes == spd_dump misc.bin" cmp -s "$DUMP_DIR/misc-slotinfo.img" "$tmp/s1/misc.bin"
"$tmp/gen_expected" misc 0 1048576 > "$tmp/misc.exp"
check "misc bytes == mock contents" cmp -s "$DUMP_DIR/misc-slotinfo.img" "$tmp/misc.exp"
# Frame compare: spdhost misc READ_START..READ_END == spd_dump read_part misc 0 1048576.
blk() { awk -v n="$2" '/^SEQ 10 /{buf=""; on=(index($0,n)>0)} on{buf=buf $0 "\n"} on&&/^SEQ 12 /{last=buf; on=0} END{printf "%s", last}' "$1"; }
mkdir -p "$tmp/rp"; ( cd "$tmp/rp" && MOCK_PTABLE="$tmp/pt" MOCK_LOG="$tmp/rp/rp.seq" TERMUX_USB_FD=7 timeout 60 "$tmp/spd_dump" \
	exec_addr 0x65015f08 fdl "$tmp/fdl1-dl.bin" 0x65000800 fdl "$tmp/fdl2-dl.bin" 0x9efffe00 exec \
	read_part misc 0 1048576 rp_misc.bin reset 7</dev/null </dev/null >/dev/null 2>&1 )
misc_hex=6d0069007300630000 # "misc\0" as UTF-16LE prefix in READ_START
blk "$tmp/rp/rp.seq" "$misc_hex" > "$tmp/sd.misc"; blk "$tmp/mock.seq" "$misc_hex" > "$tmp/sh.misc"
check "misc read frames identical to spd_dump ($(grep -c '^SEQ 11' "$tmp/sh.misc") MIDST)" \
	bash -c "[ -s '$tmp/sd.misc' ] && diff -q '$tmp/sd.misc' '$tmp/sh.misc' >/dev/null"
check "slot a detected" test "$ACTIVE_SLOT" = a
dump_matched_parts all_lite "$(parts_bytes_path)" </dev/null >"$tmp/c1d.log" 2>&1; rc=$?
check "slot a all_lite rc=0 ($rc)" test "$rc" = 0
check "slot a all_lite == spd_dump r all_lite (files+bytes, incl. splloader 256K)" same_as_spd "$DUMP_DIR" "$tmp/s1"
check "SHA256SUMS verifies" bash -c "cd '$DUMP_DIR' && sha256sum -c --quiet SHA256SUMS"

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
DUMP_DIR=$tmp/b2all; mkdir -p "$DUMP_DIR"; cp "$tmp/b2/partition_list.txt" "$tmp/b2/misc-slotinfo.img" "$DUMP_DIR/"
load_parts_state
dump_matched_parts all "$(parts_bytes_path)" </dev/null >"$tmp/c2a.log" 2>&1; rc=$?
spd_all "$tmp/s2all" all MOCK_PTABLE="$tmp/pt" MOCK_SLOT=b
check "all (rc=$rc) == spd_dump r all (both slots, splloader, no userdata/cache/blackbox)" same_as_spd "$DUMP_DIR" "$tmp/s2all"

# ---- case 3: one partition fails, the rest still dumped ----
DUMP_DIR=$tmp/b3; mkdir -p "$DUMP_DIR"; cp "$tmp/b2/partition_list.txt" "$tmp/b2/misc-slotinfo.img" "$DUMP_DIR/"
load_parts_state
echo stale > "$DUMP_DIR/boot_b.img"   # an older file must not pass the size check
MOCK_FAIL_MID=boot_b dump_matched_parts all "$(parts_bytes_path)" </dev/null >"$tmp/c3.log" 2>&1; rc=$?
check "failure: nonzero rc ($rc)" test "$rc" != 0
check "failure: failed list names boot_b only" grep -qx 'FAILED (1 of 6): boot_b' "$tmp/c3.log"
check "failure: boot_b.img.partial kept, short" bash -c "[ -f '$DUMP_DIR/boot_b.img.partial' ] && (( \$(stat -c %s '$DUMP_DIR/boot_b.img.partial') < 4194304 ))"
check "failure: previous boot_b.img restored, not in SHA256SUMS" \
	bash -c "[ \"\$(cat '$DUMP_DIR/boot_b.img')\" = stale ] && ! grep -q ' boot_b.img\$' '$DUMP_DIR/SHA256SUMS'"
check "failure: partitions after it still dumped + verified" \
	bash -c "cd '$DUMP_DIR' && [ \$(wc -l < SHA256SUMS) = 5 ] && grep -q ' uboot_b.img\$' SHA256SUMS && sha256sum -c --quiet SHA256SUMS"
check "failure: spdhost logged --keep-going + list" grep -q 'read-part failed (1): boot_b' "$tmp/c3.log"
DUMP_DIR=$tmp/b3n; mkdir -p "$DUMP_DIR"; cp "$tmp/b2/partition_list.txt" "$tmp/b2/misc-slotinfo.img" "$DUMP_DIR/"
load_parts_state
MOCK_FAIL_START=uboot_a dump_matched_parts all "$(parts_bytes_path)" </dev/null >"$tmp/c3n.log" 2>&1; rc=$?
check "READ_START NACK: rc=$rc, uboot_a failed (no file), 5 others ok" \
	bash -c "[ $rc != 0 ] && grep -qx 'FAILED (1 of 6): uboot_a' '$tmp/c3n.log' && [ ! -e '$DUMP_DIR/uboot_a.img' ] && [ \$(wc -l < '$DUMP_DIR/SHA256SUMS') = 5 ]"

# ---- case 4: > 4 GiB partition (6 GiB = 6291456 KiB), end to end ----
DUMP_DIR=$tmp/b4
printf '%s\n' 'misc 1024' 'bigpart 6291456' > "$tmp/pt4"
export MOCK_PTABLE=$tmp/pt4
unset MOCK_SLOT
fetch_parts_table </dev/null >"$tmp/c4.log" 2>&1
m=$(resolve_part_query bigpart "$(parts_bytes_path)")
check "6 GiB: 6291456 KiB -> 6442450944 bytes (got '$m')" test "$m" = "bigpart 6442450944"
list_6g() { show_parts_list "$(parts_bytes_path)" | grep -Eq '^bigpart +6G +6442450944$'; }
check "6 GiB: list shows 6G" list_6g
if [[ ${TEST_BIG:-1} != 0 ]]; then
	DQ_NAMES=(bigpart) DQ_SIZES=(6442450944) DQ_OUTS=("$DUMP_DIR/bigpart.img")
	SPDHOST_STEP=0xf800 MOCK_ZERO=bigpart run_dump_queue </dev/null >"$tmp/c4d.log" 2>&1; rc=$?
	want=$(head -c 6442450944 /dev/zero | sha256sum | cut -c1-64)
	check "6 GiB read (step 0xf800 via SPDHOST_STEP): rc=$rc size+sha256 ok" \
		bash -c "[ $rc = 0 ] && grep -q '^$want  bigpart.img\$' '$DUMP_DIR/SHA256SUMS'"
	check "6 GiB read used 64-bit frames past 4 GiB" \
		bash -c "grep -q '^SEQ 11 len=12 00f8000000000000' '$tmp/mock.seq' && grep -c '^SEQ 11 len=12' '$tmp/mock.seq' | awk '{exit !(\$1 > 100000)}'"
	rm -f "$DUMP_DIR/bigpart.img"
else
	echo "SKIP: 6 GiB read (TEST_BIG=0)"
fi

echo "menu-dump: $pass passed, $fail failed"
(( fail == 0 ))
