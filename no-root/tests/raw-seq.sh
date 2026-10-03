#!/usr/bin/env bash
# read_flash / read_mem / erase_flash: spdhost vs vendored spd_dump on
# tests/mock_fdl2.c. The mock answers READ_FLASH (0x06) with
# part_byte("flash", absolute address), so the bytes are reproducible with
# `gen_expected flash ADDR SIZE` and the same address read through read_flash
# or through read_mem must give the same file -- read_mem is the same opcode
# with the address in the first field and 0 in the third (spd_dump dump_mem).
# The frames are compared after FDL2 is up, byte-for-byte (FNV per packet).
# Usage (from no-root/): tests/raw-seq.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
make -C "$root/spd_dump" GITVER.h >/dev/null
gcc -O1 -w -std=c99 -D_GNU_SOURCE -DUSE_LIBUSB=1 -D__ANDROID__ -I"$root/spd_dump" -I"$root/tests" \
	"$root/spd_dump/spd_dump.c" "$root/spd_dump/common.c" "$root/tests/mock_fdl2.c" -lm -lpthread -o "$tmp/sd" || exit 1
gcc -O2 -w -std=c11 -D_GNU_SOURCE -I"$root/tests" "$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" \
	"$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
gcc -O2 -w -I"$root/tests" "$root/tests/gen_expected.c" -o "$tmp/gen" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
LOAD=(fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
sd() { local L=$1; shift; MOCK_LOG=sd_$L.seq TERMUX_USB_FD=7 timeout 30 ./sd exec_addr 0x65015f08 "${LOAD[@]}" "$@" 7</dev/null </dev/null >sd_$L.log 2>&1; }
sh() { local L=$1 o=(); shift; while [[ ${1:-} == --* ]]; do o+=("$1"); shift; done
	MOCK_LOG=sh_$L.seq timeout 30 ./sh --usb-fd 7 --yes "${o[@]}" exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin "${LOAD[@]}" "$@" 7</dev/null </dev/null >sh_$L.log 2>&1; }
# The two tools reach FDL2 differently (the reference sends no EXEC frame for
# the second loader, and only reads the partition table when a command wants
# it), so the boundary-based tail the other suites use cuts these sessions at
# different places. What this suite is about is the requests themselves: the
# type, length and body of every 0x06/0x0a, and how many there are -- a chunk
# size that disagrees shows up here as a different count. The trailing reset
# is kept so the frames are not compared out of their place in the session.
cmd_frames() { grep -E '^SEQ (06|0a|05) ' "$1" | sed -E 's/^(SEQ [0-9a-f]+ len=[0-9]+( [0-9a-f]*)?).*/\1/'; }
counts() { sed -E 's/^SEQ ([0-9a-f]+) len=.*/\1/' "$1" | sort | uniq -c | tr -s ' ' | tr '\n' ' '; }
short() { sed -E 's/^SEQ ([0-9a-f]+) len=([0-9]+).*/\1:\2/' "$1" | tr '\n' ' '; }
SDRC=0; SHRC=0

# With no step on either side the reference uses 1024 for these two commands
# (`blk_size ? blk_size : 1024` in its read_flash/read_mem call) and so do we,
# so `default` means "use each tool's own default" and both must agree.
#   both LABEL STEP <read cmd...>   -- the two reading commands (they end in FILE)
#   both_erase LABEL STEP ADDR SIZE
both() { # LABEL STEP CMD ADDR [OFF] SIZE
	local L=$1 step=$2; shift 2
	local sdb=() shb=()
	[[ $step != default ]] && { sdb=(blk_size "$step"); shb=(--step="$step"); }
	rm -f sd_$L.bin sh_$L.bin
	sd "$L" "${sdb[@]}" "$@" sd_$L.bin reset; SDRC=$?
	sh "$L" "${shb[@]}" "$@" sh_$L.bin reset; SHRC=$?
	cmd_frames sd_$L.seq > a_$L; cmd_frames sh_$L.seq > b_$L
}
both_erase() { # LABEL STEP ADDR SIZE
	local L=$1 step=$2; shift 2
	local sdb=(skip_confirm 1) shb=()
	[[ $step != default ]] && { sdb+=(blk_size "$step"); shb+=(--step="$step"); }
	sd "$L" "${sdb[@]}" erase_flash "$@" reset; SDRC=$?
	sh "$L" "${shb[@]}" erase_flash "$@" reset; SHRC=$?
	cmd_frames sd_$L.seq > a_$L; cmd_frames sh_$L.seq > b_$L
}

# ---- read_flash: addr, offset, size -> the reference's own chunking ----
for c in "0x2000 0 4096 default" "0x2000 0x100 0x3000 0x2000" "0x100000 0x800 0x1000 0xf800" "0x20 0 64 default"; do
	set -- $c
	a=$1; o=$2; n=$3; s=$4; L=rf
	both "$L" "$s" read_flash "$a" "$o" "$n"
	./gen flash $((a + o)) "$n" > exp_$L.bin
	check "read_flash a=$a o=$o n=$n step=$s: frames identical to spd_dump [$(short b_$L)] rc $SDRC/$SHRC" \
		bash -c "[ -s a_$L ] && diff -q a_$L b_$L >/dev/null && [ $SDRC = 0 ] && [ $SHRC = 0 ]"
	check "read_flash a=$a o=$o n=$n: both files == part_byte(flash, addr+off)" \
		cmp -s sd_$L.bin exp_$L.bin && cmp -s sh_$L.bin exp_$L.bin
done

# ---- read_mem: the same opcode, address in the first field, 0 in the third ----
for c in "0x65000800 512 default" "0x1000 0x2800 0x2000"; do
	set -- $c
	a=$1; n=$2; s=$3; L=rm
	both "$L" "$s" read_mem "$a" "$n"
	./gen flash "$a" "$n" > exp_$L.bin
	check "read_mem a=$a n=$n step=$s: frames identical to spd_dump [$(short b_$L)] rc $SDRC/$SHRC" \
		bash -c "[ -s a_$L ] && diff -q a_$L b_$L >/dev/null && [ $SDRC = 0 ] && [ $SHRC = 0 ]"
	check "read_mem a=$a: both files == part_byte(flash, addr)" \
		cmp -s sd_$L.bin exp_$L.bin && cmp -s sh_$L.bin exp_$L.bin
done
# The documented equivalence: read_flash ADDR 0 N and read_mem ADDR N are the
# same request, so the two spellings must agree with each other and the reference.
both rf2 default read_flash 0x4000 0 0x400
both rm2 default read_mem 0x4000 0x400
check "read_flash 0x4000 0 0x400 == read_mem 0x4000 0x400 == spd_dump" \
	cmp -s sh_rf2.bin sh_rm2.bin && cmp -s sd_rf2.bin sh_rf2.bin

# ---- the 32-bit limit: refused before a single frame is sent ----
for c in "read_flash 0x100000000 0 512 out.bin" "read_flash 0x1000 0 0x100000000 out.bin" \
	"read_flash 0xfffff000 0x2000 512 out.bin" "read_mem 0x100000000 512 out.bin" \
	"read_mem 0xfffffff0 0x100 out.bin"; do
	set -- $c
	rm -f out.bin
	sh big "$@"; rc=$?
	check "$1 $2 $3 over 32 bits: refused (rc $rc), no frames, no file" \
		bash -c "[ $rc != 0 ] && grep -q '32-bit limit' sh_big.log && ! [ -e out.bin ] && ! grep -qs '^SEQ 06 ' sh_big.seq"
done
sh big2 erase_flash 0x100000000 512; rc=$?
check "erase_flash over 32 bits: refused (rc $rc), no frame" \
	bash -c "[ $rc != 0 ] && grep -q '32-bit limit' sh_big2.log && ! grep -qs '^SEQ 0a ' sh_big2.seq"

# ---- erase_flash: the 8 bytes are the reference's ----
both_erase ef default 0x8000 0x1000
check "erase_flash a=0x8000 n=0x1000: frame identical to spd_dump [$(short b_ef)] rc $SDRC/$SHRC" \
	bash -c "[ -s a_ef ] && diff -q a_ef b_ef >/dev/null && grep -q '^SEQ 0a len=8' b_ef"
check "erase_flash: the body is {addr,size} big-endian (0000800000001000)" \
	grep -q '^SEQ 0a len=8 0000800000001000$' b_ef
both_erase ef2 0x2000 0x100000 0x2000
check "erase_flash with a step: the step does not change the frame [$(short b_ef2)]" \
	bash -c "diff -q a_ef2 b_ef2 >/dev/null && grep -q '^SEQ 0a len=8 0010000000002000$' b_ef2"

# ---- short read: the device stops early, the file is what arrived, rc 1 ----
rm -f sh_rf3.bin
MOCK_READ_FLASH_MAX=1000 sh rf3 read_flash 0x9000 0 0x1000 sh_rf3.bin; rc=$?
check "read_flash short (device stopped at 1000 of 4096): INCOMPLETE, rc $rc, 1000 bytes" \
	bash -c "[ $rc = 1 ] && grep -q 'INCOMPLETE' sh_rf3.log && [ \$(stat -c %s sh_rf3.bin) = 1000 ]"
MOCK_FAIL_READ_FLASH=1 sh rf4 read_flash 0x9000 0 0x400 sh_rf4.bin; rc=$?
check "read_flash NACKed: reported as an unexpected response (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'response 0x0082' sh_rf4.log"

# ---- no --yes: erase_flash asks first (the menu never passes --yes) ----
MOCK_LOG=sh_efn.seq timeout 10 ./sh --usb-fd 7 exec_addr 0x65015f08 \
	custom_exec_no_verify_65015f08.bin "${LOAD[@]}" erase_flash 0x8000 0x1000 7</dev/null >sh_efn.log 2>&1; rc=$?
check "erase_flash without --yes: not confirmed, nothing sent (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! grep -qs '^SEQ 0a ' sh_efn.seq && grep -q 'not confirmed\|no terminal' sh_efn.log"

echo
echo "raw-seq: $pass passed, $fail failed"
(( fail == 0 ))
