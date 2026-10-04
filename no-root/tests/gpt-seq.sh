#!/usr/bin/env bash
# The standard-GPT partition table: what a modern phone actually answers.
#
# spd_dump's partition_list() first tries the 32 KiB read of `user_partition` and
# hands the dump to gpt_info() (common.c:977). Only when that is not a GPT does it
# fall back to the SPRD `READ_PARTITION` packet. Every phone this tool is pointed
# at takes the GPT branch, and nothing covered it: `parts` segfaulted there (it
# dereferenced the packet pointer gpt_info never fills) and every row came out with
# a blank name (the name was read from the type GUID at offset 0 instead of
# partition_name at offset 56). Both are asserted here.
#
# From no-root/: tests/gpt-seq.sh
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
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
mkdir -p ref ours
# The mock must still list `user_partition`, or the 32 KiB read is NACKed before
# the GPT is ever looked at. The rows are the GPT's own partitions in KiB -- the
# listing always comes from the GPT, never from here -- and they double as the
# READ_START ceiling, because the mock NACKs a read bigger than the row it was
# handed (mock_fdl2.c:206): misc 2048*512, boot_a 16384*512, boot_b 20480*512,
# userdata 40960*512 sectors, i.e. 1024/8192/10240/20480 KiB.
printf '%s\n' 'misc 1024' 'user_partition 32768' 'boot_a 8192' 'boot_b 10240' 'userdata 20480' > phonept
# MOCK_GPT: `user_partition` holds a real GPT -- header at LBA 1, 128 entries at
# LBA 2 -- with misc 1 MiB, boot_a 8 MiB, boot_b 10 MiB, userdata 20 MiB and 124
# zeroed entries after them, which is what a formatted phone looks like.
export MOCK_GPT=1 MOCK_PTABLE=$tmp/phonept MOCK_SLOT=a
LOAD=(fdl "$tmp/fdl1-dl.bin" 0x65000800 fdl "$tmp/fdl2-dl.bin" 0x9efffe00)
# The reference can fall into its `FDL2 >` REPL, so its exit code is never asserted.
sd() { local L=$1; shift; ( cd ref && MOCK_LOG=$tmp/ref_$L.seq TERMUX_USB_FD=7 timeout 30 "$tmp/sd" \
	exec_addr 0x65015f08 "${LOAD[@]}" exec "$@" 7</dev/null </dev/null >$tmp/ref_$L.log 2>&1 ); }
# `parts` then `partition-list`: two listings, one device read (see the latch note below).
sh() { local L=$1; shift; ( cd ours && MOCK_LOG=$tmp/sh_$L.seq SPDHOST_PART_XML_DIR=$tmp/ours \
	timeout 30 "$tmp/sh" --usb-fd 7 --step 0x1000 --yes exec_addr 0x65015f08 \
	"$tmp/custom_exec_no_verify_65015f08.bin" "${LOAD[@]}" "$@" 7</dev/null </dev/null >$tmp/sh_$L.log 2>&1 ); }

# A separate reference run inside ref/, so its automatic partition_<unixtime>.xml
# lands in its own directory and cannot collide with ours.
sd gpt partition_list ref.xml reset
# Two `parts` and a `partition-list` in the one session: the latch must answer both
# listings from the table already in hand, so this is three outputs and one read.
sh gpt parts pt.txt parts pt2.txt partition-list ours.xml; shrc=$?

# The four rows, in order, with the sizes gpt_info()'s LBA arithmetic gives:
# (2047*512)>>20 = 1 MiB, 16384*512 = 8, 20480*512 = 10, 40960*512 = 20.
# G1: the file starts with the unit line the menu reads instead of guessing.
check "parts on a GPT device: four named rows, in MiB (rc $shrc)" \
	bash -c "[ $shrc = 0 ] && [ \"\$(grep -v '^#' ours/pt.txt)\" = \
		\"\$(printf '%s\n' 'misc 1' 'boot_a 8' 'boot_b 10' 'userdata 20')\" ]"
check "parts file names its unit: shift 20, verified (G1)" \
	bash -c "[ \"\$(head -1 ours/pt.txt)\" = '# spdhost-parts shift 20 verified 1' ]"
check "the second parts in the session writes the same table" \
	bash -c "diff -q ours/pt.txt ours/pt2.txt >/dev/null"
# The name must come from partition_name at offset 56, not the type GUID at 0. A
# wrong offset gives blank names -- a leading space here -- or non-ASCII bytes,
# which a UTF-16 GUID read reproduces; the exact-file check above would also catch
# those, but only as an opaque mismatch.
check "GPT names are real, not blank or mojibake" \
	bash -c "[ \$(grep -vc '^#' ours/pt.txt) = 4 ] &&
		! LC_ALL=C grep -q '[^ -~]' ours/pt.txt &&
		! grep -qE '^[[:space:]]|[[:space:]][[:space:]]' ours/pt.txt"

# gpt_info() saves the 32 KiB dump and says so; the SPRD packet path is skipped.
check "pgpt.bin saved, sprdpart.bin not, packet path skipped" \
	bash -c "[ -s ours/pgpt.bin ] && [ ! -e ours/sprdpart.bin ] &&
		grep -q 'standard gpt table saved' sh_gpt.log && grep -q 'skip saving sprd partition list packet' sh_gpt.log &&
		! grep -q 'sprd partition table saved' sh_gpt.log"

# spd_dump writes partition_<unixtime>.xml by itself on any session that reads the
# table; ours does too, and the two listings must agree.
check "the automatic partition_*.xml holds the same rows" \
	bash -c "n=\$(ls ours/partition_*.xml 2>/dev/null | wc -l); [ \"\$n\" = 1 ] &&
		diff -q ours/partition_*.xml ours/ours.xml >/dev/null"

# The whole point of the port: byte-for-byte the same XML the reference writes.
check "partition-list XML is byte-identical to spd_dump's" \
	bash -c "[ -s ref/ref.xml ] && diff -q ref/ref.xml ours/ours.xml >/dev/null"
check "the saved GPT dump is byte-identical too" \
	bash -c "[ -s ref/pgpt.bin ] && cmp -s ref/pgpt.bin ours/pgpt.bin"

# A GPT is answered by the 32 KiB read, so neither tool sends READ_PARTITION at all,
# and each asks for `user_partition` exactly once -- the u0075-s0073-e0065-r0072-_
# prefix below is that name in UTF-16LE, which is how it goes on the wire.
check "no READ_PARTITION frame, one user_partition read each" \
	bash -c "[ \$(grep -c '^SEQ 2d ' ref_gpt.seq) = 0 ] && [ \$(grep -c '^SEQ 2d ' sh_gpt.seq) = 0 ] &&
		[ \$(grep -c '^SEQ 10 .*75007300650072005f0070' ref_gpt.seq) = 1 ] &&
		[ \$(grep -c '^SEQ 10 .*75007300650072005f0070' sh_gpt.seq) = 1 ]"

# Every listing after the first re-prints the table already in hand. `parts` is the
# only command that prints the rows (`partition-list` just writes the XML), and its
# stdout is block-buffered into the log, so the two runs appear together at the end:
# two copies of the four rows, one READ_START. Re-reading the device here would be
# two more frames and a second 32 KiB transfer.
check "three listings in one session are still one device read" \
	bash -c "[ \$(grep -c '^1 misc 1$' sh_gpt.log) = 2 ] &&
		[ \$(grep -c '^4 userdata 20$' sh_gpt.log) = 2 ] &&
		[ \$(grep -c '^SEQ 10 .*75007300650072005f0070' sh_gpt.seq) = 1 ]"

# The GPT-derived XML is what a real phone feeds `read-parts`, so drive it from one.
# `userdata` is 0xffffffff -- read to the end of the partition -- which both tools
# skip rather than pull 20 MiB through a test; the two sized rows must come back at
# exactly the GPT sizes: misc 2048*512 = 1048576, boot_a 16384*512 = 8388608.
printf '%s\n' '<Partitions>' '    <Partition id="misc" size="1"/>' \
	'    <Partition id="boot_a" size="8"/>' '    <Partition id="userdata" size="0xffffffff"/>' \
	'</Partitions>' > ours/rl.xml
mkdir -p ours/out
sh read read-parts rl.xml out; rc=$?
check "read-parts from the GPT table: both sized rows at their GPT sizes, end-to-end row skipped (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ \$(stat -c %s ours/out/misc.bin) = 1048576 ] &&
		[ \$(stat -c %s ours/out/boot_a.bin) = 8388608 ] && [ ! -e ours/out/userdata.bin ]"

# A row the live table does not carry is skipped rather than read as something
# else: spd_dump's dump_partitions drops any row whose lookup comes back size 0
# (common.c:1757-1758). Ours says so in the log and carries on, same exit code.
printf '%s\n' '<Partitions>' '    <Partition id="nosuchpart" size="1"/>' '</Partitions>' > ours/rb.xml
mkdir -p ours/bad
sh bad read-parts rb.xml bad; rc=$?
check "a row the live table does not have is skipped like spd_dump, not read as another partition (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -q 'nosuchpart is not in the live table' sh_bad.log &&
		[ ! -e ours/bad/nosuchpart.bin ]"

# `0xffffffff` on a named row means "to the end of the partition" and the size
# comes from a device query, not from the file. The same list goes to each tool in
# its own directory, and the images have to land on the same bytes.
printf '%s\n' '<Partitions>' '    <Partition id="misc" size="1"/>' \
	'    <Partition id="boot_b" size="0xffffffff"/>' '    <Partition id="userdata" size="0xffffffff"/>' \
	'</Partitions>' > ours/rp.xml
cp ours/rp.xml ref/rp.xml
sd rp partition_list rp_list.xml read_parts rp.xml reset
sh rp partition-list rp_list.xml read-parts rp.xml .
check "read-parts 0xffffffff reads to the partition end, byte-identical to spd_dump" \
	bash -c "cmp -s ref/boot_b.bin ours/boot_b.bin && cmp -s ref/misc.bin ours/misc.bin &&
		[ \$(stat -c %s ours/boot_b.bin) = 10485760 ]"
# userdata is dropped by name (common.c:1755) and the misc image is re-dumped as
# the slot info (common.c:1771) -- both tools do both, from the same list.
check "read-parts drops userdata and re-dumps misc as slot info, like spd_dump" \
	bash -c "[ ! -e ref/userdata.bin ] && [ ! -e ours/userdata.bin ] &&
		grep -q 'saving slot info' ref_rp.log && grep -q 'saving slot info' sh_rp.log"

# With the on-flash GPT replaced by pattern bytes (MOCK_GPT unset), the same phone
# falls back to the SPRD packet: the branch gpt_info() is tried BEFORE.
( unset MOCK_GPT
  cd ours
  MOCK_LOG=$tmp/sh_nogpt.seq SPDHOST_PART_XML_DIR=$tmp/ours timeout 30 "$tmp/sh" \
	--usb-fd 7 --step 0x1000 --yes exec_addr 0x65015f08 \
	"$tmp/custom_exec_no_verify_65015f08.bin" "${LOAD[@]}" parts pt2.txt 7</dev/null </dev/null >$tmp/sh_nogpt.log 2>&1 )
shrc=$?
check "a device whose user_partition is not a GPT falls back to the SPRD packet (rc $shrc)" \
	bash -c "[ $shrc = 0 ] && [ \$(grep -c '^SEQ 2d ' sh_nogpt.seq) = 1 ] && [ -s ours/pt2.txt ]"

echo
echo "gpt-seq: $pass passed, $fail failed"
[ "$fail" = 0 ]
