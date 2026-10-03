#!/usr/bin/env bash
# wof / wov / firstmode / path against vendored spd_dump on tests/mock_fdl2.c.
#
# These four are w_mem_to_part_offset() (common.c 2073) in the reference: build
# <NAME>.bin for the name the user typed -- at offset 0 it is exactly the memory
# given, past 0 the whole partition is read into the file first and the patch is
# written into it -- then flash that file to the partition's real row. So the
# proof has two halves: the file both tools build must be byte-identical, and
# the frames both send from that partition's START onward must be identical.
#
# The tools run in separate directories because they build the same file name;
# MOCK_LOG is absolute so the two frame logs stay side by side.
# Usage (from no-root/): tests/write-extra-seq.sh
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
gcc -O2 -w -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
gcc -O2 -w -I"$root/tests" "$root/tests/gen_expected.c" -o "$tmp/gen" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
# small is the one to patch: 1 MiB, so a whole-partition read is 256 frames at
# spd_dump's 0x1000 step. Every row must stay >= 1024 units: spd_dump's own
# partition_list() divisor starts at 10 and drops while any entry >> divisor is
# 0, so a row below 1024 units (a partition under 1 MiB) would re-scale the whole
# table and both tools would ask for more than the mock has. That heuristic is
# replicated faithfully in proto.c, so the fixture has to respect it.
printf '%s\n' 'misc 1024' 'miscdata 1024' 'boot_a 4096' 'small 1024' 'userdata 4096' > pt
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a
LOAD=(fdl "$tmp/fdl1-dl.bin" 0x65000800 fdl "$tmp/fdl2-dl.bin" 0x9efffe00)
mkdir -p refdir ourdir
# No --step on purpose. The mock answers the FDL2 flash-info query the way an
# eMMC loader does, so spd_dump takes its rawdata path and sets blk_size 0xf800
# -- wof / wov then chunk at 0xf800, exactly as our own FDL1-at-0x65000800 rule
# raises io->step. Leaving the step alone is what proves the two agree; pinning
# it would have compared our 0x1000 against the reference's 0xf800.
pin=(--usb-fd 7 --yes)
# Both tools get the table read first, as every menu write path does, so the
# name resolves to a row with a size (the reference's `part not exist` guard).
# Both tools run in their own directory because each builds <name>.bin in the
# working directory: the reference's savepath starts as ".", ours starts there
# too. The mount is real -- the mock answers every frame -- so the only timeout
# left is the reference dropping into its own `FDL2 >` REPL after the command,
# where it waits for a terminal that is not there. Its frames are already on
# disk by then, so the kill is what write-seq.sh does too and no assertion here
# looks at the reference's exit status.
ref() { local L=$1; shift
	( cd refdir && MOCK_LOG="$tmp/sd_$L.seq" TERMUX_USB_FD=7 timeout 20 "$tmp/sd" exec_addr 0x65015f08 \
		"${LOAD[@]}" exec skip_confirm 1 partition_list "$tmp/p_$L.xml" "$@" 7</dev/null >"$tmp/sd_$L.log" 2>&1 ); }
ours() { local L=$1 o=(); shift; while [[ ${1:-} == --* ]]; do o+=("$1"); shift; done
	( cd ourdir && MOCK_LOG="$tmp/sh_$L.seq" timeout 20 "$tmp/sh" "${pin[@]}" "${o[@]}" \
		exec_addr 0x65015f08 "$tmp/custom_exec_no_verify_65015f08.bin" "${LOAD[@]}" \
		partition-list "$tmp/p_$L.xml" "$@" 7</dev/null >"$tmp/sh_$L.log" 2>&1 ); }
# UTF-16LE hex of a partition name, as it appears in a 0x10 START frame body.
hexname() { local s=$1 o=""; for ((i = 0; i < ${#s}; i++)); do o+=$(printf '%02x00' "'${s:i:1}"); done; echo "$o"; }
# Everything from the write START frame that names the partition to the end of
# the run. SEQ 01 is the partition START_DATA frame, and it is the first thing a
# write sends; the read that precedes it is SEQ 10/11/12, and the loader download
# that precedes both also uses 01/02/03 but with short, name-free payloads.
from() { awk -v p="$3" '$1=="SEQ" && $2=="01" && index($4,p){f=1} f' "$1" > "$2"; }
# The read phase of the same command: from its READ_START for the partition up to
# (not including) the write START. Empty when the command writes without reading.
rd() { awk -v p="$2" '$1=="SEQ" && $2=="01" && index($4,p){exit} f{print}
	$1=="SEQ" && $2=="10" && index($4,p){f=1}' "$1" > "$3"; }

SDRC=0; SHRC=0
both() { # LABEL NAME ARGS...
	local L=$1 N=$2 h; shift 2
	ref "$L" "$@"; SDRC=$?
	ours "$L" "$@"; SHRC=$?
	h=$(hexname "$N")
	from "sd_$L.seq" "a_$L" "$h"
	from "sh_$L.seq" "b_$L" "$h"
	rd "sd_$L.seq" "$h" "ra_$L"
	rd "sh_$L.seq" "$h" "rb_$L"
}
# Exported so the compound checks below can call them from inside `bash -c`.
# The write itself: same frames from the write START on.
frames_ok() { [ -s "a_$1" ] && [ -s "b_$1" ] && diff -q "a_$1" "b_$1" >/dev/null; }
# The read before it: same frames, same step, same count -- the part that would
# diverge if either tool picked a different chunk size.
reads_same() { [ -s "ra_$1" ] && diff -q "ra_$1" "rb_$1" >/dev/null; }
no_read() { ! [ -s "ra_$1" ] && ! [ -s "rb_$1" ]; }
# READ_MIDST (SEQ 11) frames, and how many bytes they asked the device for. The
# logged frame is the request, not the reply: an 8-byte body of n, pos_lo,
# pos_hi, all little-endian, in the first 16 hex characters of field 4.
reads_mid() { grep -c '^SEQ 11 ' "$1"; }
readbytes() { awk '$1 == "SEQ" && $2 == "11" {
		h = substr($4, 1, 8)
		s += strtonum("0x" substr(h, 7, 2) substr(h, 5, 2) substr(h, 3, 2) substr(h, 1, 2))
	} END {print s + 0}' "$1"; }
# Did a write START carrying this partition's name go out at all?
wrote() { grep -q "^SEQ 01 .*$2" "$1"; }
export -f frames_ok reads_same no_read reads_mid readbytes wrote

# ---- firstmode: 4 bytes at miscdata+0x2420, mode_id + 0x53464D00 ----
both fm miscdata firstmode 5
./gen miscdata 0 $((1024 * 1024)) > exp_fm.bin
printf '\x05\x4d\x46\x53' | dd of=exp_fm.bin bs=1 seek=$((0x2420)) conv=notrunc status=none
check "firstmode 5: miscdata.bin == the raw partition with 5+0x53464D00 at 0x2420 (rc $SDRC/$SHRC)" \
	bash -c "cmp -s refdir/miscdata.bin exp_fm.bin && cmp -s ourdir/miscdata.bin exp_fm.bin"
check "firstmode 5: both build the same image and send the same frames [$(wc -l < b_fm) lines]" \
	frames_ok fm
# firstmode is the one command that hardcodes 0x1000: the reference passes a
# literal DEFAULT_BLK_SIZE, whatever blk_size says, and so do we.
check "firstmode 5: the whole 1 MiB is read at 0x1000 (256 frames), then written" \
	bash -c "reads_same fm && [ \$(reads_mid rb_fm) = 256 ] && [ \$(readbytes rb_fm) = $((1024 * 1024)) ] &&
		grep -q '^SEQ 02 ' b_fm"
# spd_dump memcpy()s a host uint32_t, so the mode reaches the file little-endian.
rm -f ourdir/miscdata.bin
ours fm0 firstmode 0
check "firstmode 0: bytes 0x2420..0x2423 are 00 4d 46 53 (0x53464D00, little-endian)" \
	bash -c "[ \"\$(dd if=ourdir/miscdata.bin bs=1 skip=$((0x2420)) count=4 status=none | od -An -tx1 -v | tr -d ' \n')\" = 004d4653 ]"

# ---- wov at offset 0: the file is exactly the 4 bytes ----
both wo small wov small 0 0xdeadbeef
check "wov small 0 0xdeadbeef: small.bin is 4 bytes, ef be ad de (rc $SDRC/$SHRC)" \
	bash -c "[ \$(stat -c %s refdir/small.bin) = 4 ] && [ \$(stat -c %s ourdir/small.bin) = 4 ] &&
		[ \"\$(od -An -tx1 -v < refdir/small.bin | tr -d ' \n')\" = efbeadde ] && cmp -s refdir/small.bin ourdir/small.bin"
check "wov at offset 0: identical frames, and no partition read before the write [$(wc -l < b_wo) lines]" \
	bash -c "frames_ok wo && no_read wo"

# ---- wov past offset 0: the whole partition, then the patch ----
both wp small wov small 0x100 0xcafebabe
./gen small 0 $((1024 * 1024)) > exp_wp.bin
printf '\xbe\xba\xfe\xca' | dd of=exp_wp.bin bs=1 seek=$((0x100)) conv=notrunc status=none
check "wov small 0x100 0xcafebabe: small.bin == the partition with the patch at 0x100 (rc $SDRC/$SHRC)" \
	bash -c "cmp -s refdir/small.bin exp_wp.bin && cmp -s ourdir/small.bin exp_wp.bin"
check "wov past 0: the whole 1 MiB partition is read first, frame for frame, then both agree" \
	bash -c "frames_ok wp && reads_same wp && [ \$(readbytes rb_wp) = $((1024 * 1024)) ] &&
		[ \$(stat -c %s ourdir/small.bin) = $((1024 * 1024)) ]"

# ---- wof: a file, at offset 0 and past it ----
# $tmp/patch.bin, not patch.bin: each tool runs in its own directory, and the
# source file is the one thing the two calls must agree on by absolute path.
printf 'PATCHPATCH' > "$tmp/patch.bin"
both fo small wof small 0 "$tmp/patch.bin"
check "wof small 0 patch.bin: small.bin is exactly the 10 bytes of patch.bin (rc $SDRC/$SHRC)" \
	bash -c "[ \$(stat -c %s ourdir/small.bin) = 10 ] && cmp -s refdir/small.bin ourdir/small.bin &&
		cmp -s ourdir/small.bin '$tmp/patch.bin'"
both fp small wof small 0x200 "$tmp/patch.bin"
./gen small 0 $((1024 * 1024)) > exp_fp.bin
cat "$tmp/patch.bin" | dd of=exp_fp.bin bs=1 seek=$((0x200)) conv=notrunc status=none
check "wof small 0x200 patch.bin: partition + 10 bytes at 0x200, identical to spd_dump" \
	bash -c "cmp -s refdir/small.bin exp_fp.bin && cmp -s ourdir/small.bin exp_fp.bin && frames_ok fp &&
		reads_same fp && [ \$(readbytes rb_fp) = $((1024 * 1024)) ]"

# ---- the blacklist: fixnv / runtimenv / userdata, as substrings ----
for n in fixnv1 l_fixnv2 runtimenv userdata; do
	rm -f "ourdir/$n.bin" "sh_bl_$n.seq"
	ours "bl_$n" wov "$n" 0 1; rc=$?
	check "wov $n: blacklisted (rc $rc), no file, no write" \
		bash -c "[ $rc != 0 ] && grep -q 'blacklisted' sh_bl_$n.log && ! [ -e ourdir/$n.bin ] &&
			! wrote sh_bl_$n.seq $(hexname "$n")"
done
# wof is blacklisted on the same three, before the file is even opened.
ours bl_wof wof userdata 0 "$tmp/patch.bin"; rc=$?
check "wof userdata: blacklisted (rc $rc), nothing built, nothing sent" \
	bash -c "[ $rc != 0 ] && grep -q 'blacklisted' sh_bl_wof.log && ! [ -e ourdir/userdata.bin ]"

# ---- path: where the built image goes ----
mkdir -p refdir/out ourdir/out
# Clear the image the wof runs above left in each cwd: this case is exactly about
# a build that must NOT land there.
rm -f ourdir/small.bin refdir/small.bin
ref pa path out wov small 0 0x11223344
ours pa path out wov small 0 0x11223344
check "path out: the image lands in out/, not the cwd (rc $SDRC/$SHRC)" \
	bash -c "[ -s ourdir/out/small.bin ] && [ -s refdir/out/small.bin ] && ! [ -e ourdir/small.bin ] &&
		cmp -s ourdir/out/small.bin refdir/out/small.bin &&
		[ \"\$(od -An -tx1 -v < ourdir/out/small.bin | tr -d ' \n')\" = 44332211 ]"
ours pn path
check "path with no argument: reports the current directory and changes nothing" \
	bash -c "grep -q 'save dir is \.' sh_pn.log"

# ---- refusals that stop before a frame is sent ----
ours nn wov nosuchpart 0 1; rc=$?
check "wov on a name the table does not have: refused as spd_dump's 'part not exist' (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'part not exist' sh_nn.log && ! [ -e ourdir/nosuchpart.bin ] &&
		! wrote sh_nn.seq $(hexname nosuchpart)"
rm -f ourdir/small.bin
ours ov wov small 0x200000 1; rc=$?
check "wov past the end of the 1 MiB partition: refused (rc $rc), nothing built" \
	bash -c "[ $rc != 0 ] && grep -q 'past the end' sh_ov.log && ! [ -e ourdir/small.bin ]"
ours bv wov small 0 0x100000000; rc=$?
check "wov value over 0xffffffff: refused, as the reference's own help says" \
	bash -c "[ $rc != 0 ] && grep -q 'not a 32-bit number' sh_bv.log && ! [ -e ourdir/small.bin ]"
ours mf wof small 0 missing.bin; rc=$?
check "wof with a file that is not there: refused (rc $rc), nothing sent" \
	bash -c "[ $rc != 0 ] && grep -q 'cannot read missing.bin' sh_mf.log && ! [ -e ourdir/small.bin ]"
# The write confirm is the same one write-part takes: no --yes, no write.
MOCK_LOG=sh_ny.seq timeout 20 "$tmp/sh" --usb-fd 7 \
	exec_addr 0x65015f08 "$tmp/custom_exec_no_verify_65015f08.bin" "${LOAD[@]}" \
	partition-list "$tmp/p_ny.xml" wov small 0 1 7</dev/null >sh_ny.log 2>&1; rc=$?
check "wov without --yes: not confirmed, no write frame (rc $rc)" \
	bash -c "[ $rc != 0 ] && ! wrote sh_ny.seq $(hexname small) && grep -q 'not confirmed\|no terminal' sh_ny.log"

echo
echo "write-extra-seq: $pass passed, $fail failed"
(( fail == 0 ))
