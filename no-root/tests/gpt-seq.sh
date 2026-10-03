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
# the GPT is ever looked at. The row size is only there to satisfy the table walk.
printf '%s\n' 'misc 1024' 'user_partition 32768' 'boot_a 4096' 'boot_b 4096' 'userdata 8192' > phonept
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
check "parts on a GPT device: four named rows, in MiB (rc $shrc)" \
	bash -c "[ $shrc = 0 ] && [ \"\$(cat ours/pt.txt)\" = \
		\"\$(printf '%s\n' 'misc 1' 'boot_a 8' 'boot_b 10' 'userdata 20')\" ]"
check "the second parts in the session writes the same table" \
	bash -c "diff -q ours/pt.txt ours/pt2.txt >/dev/null"
# The name must come from partition_name at offset 56, not the type GUID at 0. A
# wrong offset gives blank names -- a leading space here -- or non-ASCII bytes,
# which a UTF-16 GUID read reproduces; the exact-file check above would also catch
# those, but only as an opaque mismatch.
check "GPT names are real, not blank or mojibake" \
	bash -c "[ \$(wc -l < ours/pt.txt) = 4 ] &&
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
