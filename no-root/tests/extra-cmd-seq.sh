#!/usr/bin/env bash
# The spd_dump verbs that are neither a read, a write nor a dump: print (p),
# read_parts, loadexec and loadfdl, against the vendored reference on
# tests/mock_fdl2.c. Each is compared by what it produces rather than by text:
# print by the table it lists, read_parts by the files it writes and the frames
# it sends, loadfdl by the frames it sends for the same loader, loadexec by the
# exec_addr it derives from a file name.
#
# spd_dump's exec_addr builds "custom_exec_no_verify_<addr>.bin" relative to the
# working directory, so each tool runs in its own directory holding a copy of
# the stub -- the same layout read-part-seq.sh uses.
# Usage (from no-root/): tests/extra-cmd-seq.sh
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
cd "$tmp"
# KiB units with every row >= 1024, so spd_dump's divisor stays 10 and a row's
# byte size is its number times 1024 (see write-extra-seq.sh). Sizes are whole
# MiB, so print's "%7lldMB" has one right answer.
printf '%s\n' 'misc 1024' 'boot_a 2048' 'super 8192' 'userdata 4096' > pt
printf '%s\n' '<Partitions>' \
	'    <Partition id="misc" size="1"/>' \
	'    <Partition id="boot_a" size="2"/>' \
	'    <Partition id="userdata" size="4"/>' \
	'    <Partition id="splloader" size="1"/>' \
	'    <Partition id="super" size="0xffffffff"/>' \
	'</Partitions>' > list.xml
export MOCK_PTABLE=$tmp/pt MOCK_SLOT=a
F1=(fdl "$tmp/fdl1-dl.bin" 0x65000800 fdl "$tmp/fdl2-dl.bin" 0x9efffe00)
EX=(exec skip_confirm 1)
mkdir -p refdir ourdir
# The loaders by absolute path (spd_dump's `fdl` takes a path; ours takes one too)
# and again inside each directory, because the stub exec_addr builds is looked up
# relative to the working directory.
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cp "$tmp"/*.bin refdir/
cp "$tmp"/*.bin ourdir/
# The reference runs `exec` AFTER the two fdl commands: spd_dump skips exec while
# no loader has been sent, so putting it first leaves Da_Info zeroed and the FDL2
# stage never runs. EX is that verb, and every call site puts it after F1 --
# exactly where ours reaches FDL2 (our `fdl` advances the stage by itself).
ref() { local L=$1; shift
	( cd refdir && MOCK_LOG="$tmp/sd_$L.seq" TERMUX_USB_FD=7 timeout 20 "$tmp/sd" exec_addr 0x65015f08 \
		"$@" 7</dev/null >"$tmp/sd_$L.out" 2>"$tmp/sd_$L.log" ); }
ours() { local L=$1; shift
	( cd ourdir && MOCK_LOG="$tmp/sh_$L.seq" timeout 20 "$tmp/sh" --usb-fd 7 --yes \
		exec_addr 0x65015f08 "$tmp/ourdir/custom_exec_no_verify_65015f08.bin" \
		"$@" 7</dev/null >"$tmp/sh_$L.out" 2>"$tmp/sh_$L.log" ); }
# UTF-16LE hex of a name, as it appears in a 0x10 READ_START frame body.
hexname() { local s=$1 o=""; for ((i = 0; i < ${#s}; i++)); do o+=$(printf '%02x00' "'${s:i:1}"); done; echo "$o"; }
# The same, padded to the whole 36-character name field (72 bytes, 144 hex), so
# a match cannot be a prefix of a longer name: "boot_a" must not find "uboot_a".
hexfield() { local o; o=$(hexname "$1"); local pad=$((144 - ${#o}))
	while ((pad-- > 0)); do o+=0; done; echo "$o"; }
# Every READ_START..READ_END block whose START names NAME, in the log's order.
blocks() { awk -v p="$2" '
	/^SEQ 10 / {buf = ""; on = (index($4, p) == 1)}
	on {buf = buf $0 "\n"}
	on && /^SEQ 12 / {printf "%s", buf; buf = ""; on = 0}' "$1" > "$3"; }
# Line of NAME's first READ_START, for the order check.
lineof() { grep -n "^SEQ 10 len=[0-9]* $(hexfield "$2")" "$1" | head -1 | cut -d: -f1; }
# Line of NAME's LAST READ_START: the slot-info misc is the second one.
lastof() { grep -n "^SEQ 10 len=[0-9]* $(hexfield "$2")" "$1" | tail -1 | cut -d: -f1; }

# ---- print / p: the table, exactly as spd_dump lists it ----
ref pr "${F1[@]}" "${EX[@]}" partition_list "$tmp/p_pr.xml" p
ours pr "${F1[@]}" parts print
# The table block, and only it. The reference prints the table three times -- once
# from partition_list() during the fdl stage, once from the `partition_list FILE`
# command and once from p itself -- and sends its whole log to stderr, while ours
# prints parts' own "index name units" listing plus the p table on stdout. Only
# the table rows carry a MB/KB suffix, and the table is the last thing either tool
# writes, so its five rows are the tail of that shape.
tab() { grep -E '^ *[0-9]+ .*(MB|KB)$' "$1" | tail -5; }
tab "$tmp/sd_pr.log" > a_pr
tab "$tmp/sh_pr.out" > b_pr
check "print: the same table as spd_dump's p [$(wc -l < b_pr) rows]" \
	bash -c 'diff -q a_pr b_pr >/dev/null'
check "print: splloader as row 0 at 256KB, then the table's order and MiB sizes" \
	bash -c "grep -q '0 .*splloader .*256KB' b_pr && grep -q '1 .*misc .*1MB' b_pr &&
		grep -q '2 .*boot_a .*2MB' b_pr && grep -q '3 .*super .*8MB' b_pr &&
		grep -q '4 .*userdata .*4MB' b_pr"
ours prb "${F1[@]}" parts p
tab "$tmp/sh_prb.out" > b_prb
check "print: the p alias lists the same table" bash -c 'diff -q b_pr b_prb >/dev/null'

# ---- read_parts: every partition the list names, in the list's order ----
ref rp "${F1[@]}" "${EX[@]}" read_parts "$tmp/list.xml"
ours rp "${F1[@]}" read-parts "$tmp/list.xml"
# The reference writes through my_fopen, which drops the directory; with no
# `path` set that is the cwd, so the two land side by side, one per directory.
# super's size comes from the list's 0xffffffff ("take the rest"), which asks
# the device, so the largest frame in the table above is its 8 MiB.
declare -A want=( [misc]=1 [boot_a]=2 [splloader]="$((256 * 1024))" [super]=8 )
rc=0
for n in "${!want[@]}"; do
	sz=${want[$n]}; ((sz < 1024)) && sz=$((sz * 1024 * 1024))
	"$tmp/gen" "$n" 0 "$sz" > "exp_$n.bin"
	cmp -s "refdir/$n.bin" "exp_$n.bin" || { rc=1; echo "  refdir/$n.bin differs"; }
	cmp -s "ourdir/$n.bin" "exp_$n.bin" || { rc=1; echo "  ourdir/$n.bin differs"; }
done
check "read_parts: misc, boot_a, splloader and the 0xffffffff super match spd_dump" test $rc = 0
check "read_parts: userdata is skipped, as in spd_dump" \
	bash -c '[ ! -e ourdir/userdata.bin ] && [ ! -e refdir/userdata.bin ]'
check "read_parts: splloader is read at its fixed 256 KiB, not the list's 1 MiB" \
	bash -c "[ \$(stat -c %s ourdir/splloader.bin) = $((256 * 1024)) ]"
# The list is copied into the dump folder ("saving dump list") only when the run
# was told where to put things: spd_dump's savepath is empty until `path DIR`
# (common.c:232), so with no destination named neither tool copies the list.
check "read_parts: with no destination named, neither tool copies the list" \
	bash -c "[ ! -e ourdir/list.xml ] && [ ! -e refdir/list.xml ]"
mkdir -p refout ourout
ref rq "${F1[@]}" "${EX[@]}" path "$tmp/refout" read_parts "$tmp/list.xml"
ours rq "${F1[@]}" path "$tmp/ourout" read-parts "$tmp/list.xml" "$tmp/ourout"
check "read_parts: with a destination, both copy the list into it (\"saving dump list\")" \
	bash -c "grep -q 'saving dump list' sd_rq.log && grep -q 'saving dump list' sh_rq.log &&
		cmp -s refout/list.xml '$tmp/list.xml' && cmp -s ourout/list.xml '$tmp/list.xml'"
# Same reads, frame for frame. Ours is cut from our own log, the reference from
# its own: the two logs hold the same blocks in the same order.
for n in misc boot_a splloader super; do
	blocks "sd_rp.seq" "$(hexfield "$n")" "ra_$n"
	blocks "sh_rp.seq" "$(hexfield "$n")" "rb_$n"
done
check "read_parts: every partition's read sends spd_dump's own frames" \
	bash -c 'for n in misc boot_a splloader super; do
		[ -s "ra_$n" ] && diff -q "ra_$n" "rb_$n" >/dev/null || exit 1; done'
# The list's order, and the slot-info misc block spd_dump puts after them.
lm=$(lineof sh_rp.seq misc); lb=$(lineof sh_rp.seq boot_a)
ls=$(lineof sh_rp.seq splloader); lu=$(lineof sh_rp.seq super)
check "read_parts: the reads follow the list's order (misc, boot_a, splloader, super)" \
	test "$lm" -lt "$lb" -a "$lb" -lt "$ls" -a "$ls" -lt "$lu"
# The slot block is the second misc read, and it comes after the list's last row.
lslast=$(lastof sh_rp.seq misc)
llast=$(grep -n '^SEQ 10 ' sh_rp.seq | tail -1 | cut -d: -f1)
check "read_parts: the A/B slot block is dumped last, as spd_dump's \"saving slot info\"" \
	bash -c "grep -q 'saving slot info' sh_rp.log && [ $lslast -gt $lu ] && [ $lslast = $llast ]"
# A list that is not there is refused, not crashed on.
ours rx "${F1[@]}" read-parts "$tmp/nothere.xml"; rc=$?
check "read_parts: a list that is not there is refused (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'nothere.xml' sh_rx.log"

# ---- loadfdl: `fdl FILE addr` with the address read out of FILE's name ----
cp "$tmp/fdl1-dl.bin" "$tmp/fdl1-dl_0x65000800.bin"
cp "$tmp/fdl2-dl.bin" "$tmp/fdl2-dl_0x9efffe00.bin"
ref lf loadfdl "$tmp/fdl1-dl_0x65000800.bin" loadfdl "$tmp/fdl2-dl_0x9efffe00.bin" "${EX[@]}" reset
ours lf loadfdl "$tmp/fdl1-dl_0x65000800.bin" loadfdl "$tmp/fdl2-dl_0x9efffe00.bin" reset
# The loader transfers only: every START/MIDST/END frame, which is the loader
# bytes and the address it was sent to. The two logs are not compared whole --
# spd_dump's fdl stage probes the device (KEEP_CHARGE, the GPT reads, the table
# packet) around the same transfer, and the loader download is the part loadfdl
# is responsible for.
loads() { grep -E '^SEQ 0[123] ' "$1"; }
loads sd_lf.seq > a_lf
loads sh_lf.seq > b_lf
check "loadfdl: both loaders, byte for byte, at the addresses in their names [$(wc -l < b_lf) frames]" \
	bash -c '[ -s b_lf ] && diff -q a_lf b_lf >/dev/null'
# The address is read from the name: fdl1's START carries 0x65000800, fdl2's
# 0x9efffe00, and neither is the address the plain fdl command would have taken.
check "loadfdl: the two addresses came out of the names (0x65000800, then 0x9efffe00)" \
	bash -c "grep -q '^SEQ 01 len=8 65000800' b_lf && grep -q '^SEQ 01 len=8 9efffe00' b_lf"
# The address really came out of the name: the same file under a plain name has
# no address, and both refuse it.
ours ln loadfdl "$tmp/fdl1-dl.bin"; rc=$?
check "loadfdl: a name with no 0x address is refused (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -q 'not found in name' sh_ln.log"

# ---- loadexec: exec_addr from the stub's own name, BootROM stage only ----
ref le "${F1[@]}" loadexec "$tmp/refdir/custom_exec_no_verify_65015f08.bin" reset
ours le "${F1[@]}" loadexec "$tmp/ourdir/custom_exec_no_verify_65015f08.bin" reset
check "loadexec: both read 0x65015f08 out of the file name" \
	bash -c "grep -q 'current exec_addr is 0x65015f08' sd_le.log &&
		grep -q 'current exec_addr is 0x65015f08' sh_le.log"
# spd_dump: a file that is not there prints "does not exist" and zeroes it.
ref lm loadexec "$tmp/refdir/custom_exec_no_verify_650fffff.bin"
ours lm loadexec "$tmp/ourdir/custom_exec_no_verify_650fffff.bin"
check "loadexec: a stub that is not there is disabled on both (exec_addr 0)" \
	bash -c "grep -q 'current exec_addr is 0x0' sd_lm.log && grep -q 'current exec_addr is 0x0' sh_lm.log &&
		grep -q 'does not exist' sd_lm.log && grep -q 'does not exist' sh_lm.log"
# And it drives the same run as exec_addr with the same stub: the helper above
# already put exec_addr 0x65015f08 on the command line, so the loadexec run and
# the same run without it must be identical frame for frame.
ours lez "${F1[@]}" reset
check "loadexec: the run it produces is exec_addr's own run with that stub" \
	bash -c '[ -s sh_le.seq ] && diff -q sh_le.seq sh_lez.seq >/dev/null'
# Past the first fdl it is ignored, exactly as the reference ignores it. The stub
# it names carries a different address from the one exec_addr was given, so an
# ignored loadexec is visible: exec_addr must stay 0x65015f08, not become 0x650abcde.
cp "$tmp/custom_exec_no_verify_65015f08.bin" refdir/custom_exec_no_verify_650abcde.bin
cp "$tmp/custom_exec_no_verify_65015f08.bin" ourdir/custom_exec_no_verify_650abcde.bin
ref lx fdl "$tmp/fdl1-dl.bin" 0x65000800 loadexec "$tmp/refdir/custom_exec_no_verify_650abcde.bin" reset
ours lx fdl "$tmp/fdl1-dl.bin" 0x65000800 loadexec "$tmp/ourdir/custom_exec_no_verify_650abcde.bin" reset
check "loadexec after the first fdl: ignored on both, exec_addr unchanged" \
	bash -c "! grep -q '0x650abcde' sd_lx.log && ! grep -q '0x650abcde' sh_lx.log &&
		grep -q 'current exec_addr is 0x65015f08' sd_lx.log &&
		grep -q 'current exec_addr is 0x65015f08' sh_lx.log"

# spd_dump's `keep_charge {0,1}` (spd_dump.c:1285) turns off the KEEP_CHARGE packet
# it otherwise sends after the FDL1 CONNECT (`keep_charge = 1` at spd_dump.c:155,
# sent at :706). It only matters when the command precedes the `fdl` that starts
# FDL1, which is where both tools read it. Frame type 0x13.
ref kc0 keep_charge 0 "${F1[@]}" reset
ours kc0 keep_charge 0 "${F1[@]}" reset
ref kc1 "${F1[@]}" reset
ours kc1 "${F1[@]}" reset
check "keep_charge 0: neither tool sends the KEEP_CHARGE frame" \
	bash -c "[ \$(grep -c '^SEQ 13 ' sd_kc0.seq) = 0 ] && [ \$(grep -c '^SEQ 13 ' sh_kc0.seq) = 0 ]"
# The default is on, so the same run without the command must still send exactly one.
check "keep_charge defaults on: one KEEP_CHARGE frame, on both" \
	bash -c "[ \$(grep -c '^SEQ 13 ' sd_kc1.seq) = 1 ] && [ \$(grep -c '^SEQ 13 ' sh_kc1.seq) = 1 ]"

echo
echo "extra-cmd-seq: $pass passed, $fail failed"
(( fail == 0 ))
