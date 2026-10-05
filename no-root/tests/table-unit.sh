#!/usr/bin/env bash
# G1: the table unit travels from spdhost to the menu instead of being guessed.
#
# spdhost's `parts FILE` writes "# spdhost-parts shift S verified V" first and
# the rows in that unit; the menu reads the line instead of re-running spd_dump's
# divisor loop. These cases are the ones the loop got wrong:
#   - a UFS SPRD table in MiB (smallest row 2 MiB): read as << 19, every dump
#     half size and still "ok". spdhost's size probe answers 2x the table, so it
#     corrects the table to << 20.
#   - the same table when the device will not size the probe row: the unit
#     stays unverified, `dump` sizes each row by the device, and a row the
#     device will not size is reported UNVERIFIED, not ok.
#   - a 4 KiB-sector GPT with a 512 KiB row: was printed as 0 (dropped from
#     `all`) with the rest halved.
#   - a header-less file (older spdhost): the old loop is still the fallback.
# From no-root/: tests/table-unit.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

CC=${CC:-gcc}
mkdir -p "$tmp/pkg/fdl/ums9230"
$CC -O2 -w -std=c11 -D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" \
	-o "$tmp/pkg/spdhost" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$tmp/pkg/fdl/ums9230/"
cp "$root/fdl/ums9230/infinix/fdl1-dl.bin" "$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cat > "$tmp/runner" <<R
#!/usr/bin/env bash
MOCK_LOG=\${MOCK_LOG:-$tmp/mock.seq} exec "$tmp/pkg/spdhost" --usb-fd 7 "\$@" 7</dev/null
R
chmod +x "$tmp/runner"
export SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER="$tmp/runner" SPDHOST_MENU_CONFIG="$tmp/none.conf"
export SPDHOST_EXEC_ADDR=0x65015f08 SPDHOST_TIMEOUT=1000
# shellcheck source=/dev/null
source "$root/scripts/menu.sh" || { echo "cannot source menu.sh"; exit 1; }
FDL1="$tmp/fdl1-dl.bin" FDL1_ADDR=0x65000800 FDL2="$tmp/fdl2-dl.bin" FDL2_ADDR=0x9efffe00
bytes_of() { awk -v n="$1" '$1 == n { print $2; exit }' "$(parts_bytes_path)"; }
meta_of() { dump_meta_file "$1" read; }
fsize() { stat -c %s "$1" 2>/dev/null || echo -1; }
in_sums() { grep -q " $1\$" "$(dump_meta_file SHA256SUMS read)" 2>/dev/null; }

# ---- the menu side alone: header wins over the loop; no header keeps the loop ----
DUMP_DIR=$tmp/m0; mkdir -p "$DUMP_DIR"
printf '%s\n' 'prodnv 5' 'miscdata 2' 'boot_a 64' > "$(meta_of partition_list.txt)"
load_parts_state
check "no header (older spdhost): divisor loop fallback, shift 19, unverified unknown" \
	bash -c "[ '$PARTS_SHIFT' = 19 ] && [ -z '$PARTS_VERIFIED' ] && [ '$(bytes_of boot_a)' = 33554432 ]"
printf '%s\n' '# spdhost-parts shift 20 verified 1' 'prodnv 5' 'miscdata 2' 'boot_a 64' > "$(meta_of partition_list.txt)"
load_parts_state
check "header shift 20: boot_a 64 MiB, header line not a row" \
	bash -c "[ '$PARTS_SHIFT' = 20 ] && [ '$PARTS_VERIFIED' = 1 ] && [ '$(bytes_of boot_a)' = 67108864 ] &&
		! grep -q '^#' '$(parts_bytes_path)' && [ \$(wc -l < '$(parts_bytes_path)') = 3 ]"
printf '%s\n' '# spdhost-parts shift 10 verified 1' 'sml_a 512' 'boot_a 2048' > "$(meta_of partition_list.txt)"
load_parts_state
m=$(resolve_part_query sml "$(parts_bytes_path)" 2>/dev/null)
check "header shift 10: a 512 KiB row is 524288, resolvable by name ($m)" \
	bash -c "[ '$(bytes_of sml_a)' = 524288 ] && [ '$m' = 'sml_a 524288' ]"

# ---- UFS: SPRD table in MiB, smallest row 2 MiB ----
printf '%s\n' 'prodnv 5' 'miscdata 2' 'misc 2' 'uboot_a 2' 'uboot_b 2' 'boot_a 64' 'boot_b 64' \
	'super 96' 'userdata 200' > "$tmp/pt_ufs"
DUMP_DIR=$tmp/u1
export MOCK_PTABLE=$tmp/pt_ufs MOCK_PTABLE_MIB=1 MOCK_SLOT=a
fetch_parts_table </dev/null >"$tmp/u1.log" 2>&1
check "UFS: parts file header says shift 20, verified, corrected" \
	grep -qx '# spdhost-parts shift 20 verified 1 corrected 1' "$(meta_of partition_list.txt)"
check "UFS: raw rows unchanged (boot_a 64)" grep -qx 'boot_a 64' "$(meta_of partition_list.txt)"
check "UFS: spdhost said it corrected the unit" grep -q "every row's size is corrected to units << 20" "$tmp/u1.log"
check "UFS: menu byte table boot_a = 64 MiB (was 32 MiB)" test "$(bytes_of boot_a)" = 67108864
check "UFS: menu reports the correction, no 'guess' warning" \
	bash -c "grep -q 'spdhost corrected' '$tmp/u1.log' && ! grep -q 'unit is a guess' '$tmp/u1.log'"
dump_live_session boot </dev/null >"$tmp/u1d.log" 2>&1; rc=$?
check "UFS: dump boot -> boot_a.img is the full 64 MiB, ok (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ $(fsize "$DUMP_DIR/boot_a.img") = 67108864 ] && grep -q ' boot_a.img\$' '$(dump_meta_file SHA256SUMS read)'"
DUMP_DIR=$tmp/u1all
dump_live_session all </dev/null >"$tmp/u1a.log" 2>&1; rc=$?
check "UFS: all: every image is the device's size (prodnv 5 MiB, super 96 MiB, rc $rc)" \
	bash -c "[ $rc = 0 ] && [ $(fsize "$DUMP_DIR/prodnv.img") = 5242880 ] && [ $(fsize "$DUMP_DIR/super.img") = 100663296 ] &&
		[ $(fsize "$DUMP_DIR/miscdata.img") = 2097152 ]"

# ---- UFS, the probe row will not be sized: unverified, per-row device sizes ----
DUMP_DIR=$tmp/u2
export MOCK_NOPROBE=prodnv
fetch_parts_table </dev/null >"$tmp/u2.log" 2>&1
check "unverified: header says verified 0 at the guessed shift" \
	grep -qx '# spdhost-parts shift 19 verified 0' "$(meta_of partition_list.txt)"
check "unverified: the menu warns the unit is a guess" grep -q 'unit is a guess the device did not confirm' "$tmp/u2.log"
dump_live_session boot </dev/null >"$tmp/u2d.log" 2>&1; rc=$?
check "unverified: dump boot sizes boot_a by the device: 64 MiB, ok (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ $(fsize "$DUMP_DIR/boot_a.img") = 67108864 ] && grep -q ' boot_a.img\$' '$(dump_meta_file SHA256SUMS read)' &&
		grep -q \"using the device's 67108864 bytes (table says 33554432)\" '$tmp/u2d.log'"
dump_live_session prodnv </dev/null >"$tmp/u2p.log" 2>&1; rc=$?
check "unverified: a row the device will not size is UNVERIFIED, not ok, not in SHA256SUMS (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'UNVERIFIED prodnv' '$tmp/u2p.log' &&
		{ [ -f '$DUMP_DIR/prodnv.img.unverified' ] || [ -f '$DUMP_DIR/prodnv.img' ]; } &&
		! grep -q ' prodnv.img\$' '$(dump_meta_file SHA256SUMS read)' && grep -qx 'unverified prodnv' '$(meta_of dump-manifest.txt)'"
unset MOCK_NOPROBE MOCK_PTABLE_MIB

# ---- 4 KiB-sector GPT with a 512 KiB row ----
printf '%s\n' 'user_partition 32768' 'sml_a 512' 'boot_a 2048' 'boot_b 2048' 'super 6144' 'misc 1024' > "$tmp/pt_gpt"
DUMP_DIR=$tmp/g1
export MOCK_GPT=4k MOCK_PTABLE=$tmp/pt_gpt MOCK_SLOT=a
fetch_parts_table </dev/null >"$tmp/g1.log" 2>&1
check "GPT 4k: spdhost read 4096-byte sectors" grep -q '4 entries from the standard GPT (4096-byte sectors)' "$tmp/g1.log"
check "GPT 4k: header shift 10 (the 512 KiB row needs it), verified" \
	grep -qx '# spdhost-parts shift 10 verified 1' "$(meta_of partition_list.txt)"
check "GPT 4k: sml_a is 512, not 0" grep -qx 'sml_a 512' "$(meta_of partition_list.txt)"
check "GPT 4k: menu bytes sml_a 524288, boot_a 2 MiB (not halved), super 6 MiB" \
	bash -c "[ '$(bytes_of sml_a)' = 524288 ] && [ '$(bytes_of boot_a)' = 2097152 ] && [ '$(bytes_of super)' = 6291456 ]"
dump_live_session all </dev/null >"$tmp/g1a.log" 2>&1; rc=$?
check "GPT 4k: all keeps the sub-MiB row and dumps every row at full size (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ $(fsize "$DUMP_DIR/sml_a.img") = 524288 ] && [ $(fsize "$DUMP_DIR/boot_a.img") = 2097152 ] &&
		[ $(fsize "$DUMP_DIR/super.img") = 6291456 ] && grep -q ' sml_a.img\$' '$(dump_meta_file SHA256SUMS read)'"
unset MOCK_GPT

# ---- eMMC KiB table: unchanged behaviour, header shift 10 ----
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'uboot_b 1024' 'boot_a 4096' 'boot_b 4096' > "$tmp/pt_kib"
DUMP_DIR=$tmp/k1
export MOCK_PTABLE=$tmp/pt_kib
fetch_parts_table </dev/null >"$tmp/k1.log" 2>&1
check "KiB: header shift 10 verified 1, boot_a 4 MiB" \
	bash -c "grep -qx '# spdhost-parts shift 10 verified 1' '$(meta_of partition_list.txt)' && [ '$(bytes_of boot_a)' = 4194304 ]"


# ---- N2: probe under 2 MiB is not sized (sub-MiB row on an unverified table) ----
# A KiB table with a 512 KiB sml: the sub-MiB row drops the divisor, MOCK_NOPROBE
# on the first large row keeps the unit unverified. check_partition used to return
# ~1 MiB for sml; dump trusted it and over-read. Now a probe under 2 MiB is
# "not sized" -> unverified at the table size (no trust of the bad probe).
printf '%s\n' 'prodnv 5120' 'miscdata 1024' 'misc 1024' 'sml 512' 'uboot 1024' 'boot 4096' > "$tmp/pt_n2"
DUMP_DIR=$tmp/n2
export MOCK_PTABLE=$tmp/pt_n2 MOCK_NOPROBE=prodnv
unset MOCK_SLOT MOCK_PTABLE_MIB MOCK_GPT
fetch_parts_table </dev/null >"$tmp/n2f.log" 2>&1
check "N2: header verified 0 (sub-MiB row + failed large-row probe)" \
	grep -qE '^# spdhost-parts shift [0-9]+ verified 0$' "$(meta_of partition_list.txt)"
dump_live_session sml </dev/null >"$tmp/n2d.log" 2>&1; rc=$?
check "N2: sml probe under 2 MiB is treated as not sized (no trust of ~1 MiB)" \
	bash -c "grep -qE 'dump: sml: probe 0x[0-9a-f]+ under 2 MiB is not a reliable' '$tmp/n2d.log' ||
		grep -q 'table unit unverified and the device did not size' '$tmp/n2d.log'"
check "N2: sml does not trust the ~1 MiB probe (no 'using the device' size; did-not-size path)" \
	bash -c "! grep -qE 'dump: sml: table unit unverified; using the device.s' '$tmp/n2d.log' &&
		grep -q 'dump: sml: table unit unverified and the device did not size' '$tmp/n2d.log' &&
		! grep -qE '^start sml 1047552 ' '$(meta_of dump-manifest.txt)'"
unset MOCK_NOPROBE MOCK_PTABLE

echo "table-unit: $pass passed, $fail failed"
(( fail == 0 ))
