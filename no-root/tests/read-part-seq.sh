#!/usr/bin/env bash
# Frame-level compare: spd_dump read_part vs spdhost read-part on tests/mock_fdl2.c
# (ported from the dump-verify audit cmp/run-all.sh + read-part-seq.sh).
# Each case: last READ_START..READ_END block must be byte-identical (FNV of the
# framed bytes) and both output files must equal the mock's contents.
# Usage (from no-root/): tests/read-part-seq.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
make -C "$root/spd_dump" GITVER.h >/dev/null
gcc -O1 -w -std=c99 -D_GNU_SOURCE -DUSE_LIBUSB=1 -D__ANDROID__ -I"$root/spd_dump" -I"$root/tests" \
	"$root/spd_dump/spd_dump.c" "$root/spd_dump/common.c" "$root/tests/mock_fdl2.c" -lm -lpthread -o "$tmp/sd" || exit 1
gcc -O2 -w -std=c11 -D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/proto.c" "$root/src/dumpcmd.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
gcc -O2 -w -I"$root/tests" "$root/tests/gen_expected.c" -o "$tmp/gen" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
fails=0
blk() { awk '/^SEQ 10 /{buf=""; on=1} on{buf=buf $0 "\n"} on&&/^SEQ 12 /{last=buf; on=0} END{printf "%s", last}' "$1"; }
run() { # LABEL NAME OFF SIZE BLK(or "default") [EXPECTED_BYTES: clipped at partition end]
	local L=$1 N=$2 O=$3 S=$4 B=$5 E=${6:-$4} sdb=() shb=() seq f1 f2
	[[ $B != default ]] && { sdb=(blk_size "$B"); shb=(--step "$B"); }
	rm -f sd_$L.bin sh_$L.bin
	MOCK_LOG=sd_$L.full TERMUX_USB_FD=7 timeout 60 ./sd exec_addr 0x65015f08 fdl fdl1-dl.bin 0x65000800 \
		fdl fdl2-dl.bin 0x9efffe00 exec "${sdb[@]}" read_part "$N" "$O" "$S" sd_$L.bin reset 7</dev/null </dev/null >sd_$L.log 2>&1
	MOCK_LOG=sh_$L.full timeout 60 ./sh --usb-fd 7 "${shb[@]}" exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin \
		fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00 read-part "$N" "$O" "$S" sh_$L.bin reset 7</dev/null </dev/null >sh_$L.log 2>&1
	blk sd_$L.full > sd_$L.seq; blk sh_$L.full > sh_$L.seq
	./gen "$N" "$O" "$E" > exp_$L.bin
	[[ -s sh_$L.seq ]] && diff -q sd_$L.seq sh_$L.seq >/dev/null && seq=same || seq=DIFF
	cmp -s sd_$L.bin exp_$L.bin && f1=ok || f1=BAD
	cmp -s sh_$L.bin exp_$L.bin && f2=ok || f2=BAD
	if [[ $seq == same && $f1 == ok && $f2 == ok ]]; then
		echo "PASS [$L] $N off=$O size=$S step=$B frames=$(wc -l < sh_$L.seq) midst=$(grep -c '^SEQ 11 ' sh_$L.seq) $(head -1 sh_$L.seq | grep -o 'len=[0-9]*' | head -1)"
	else
		echo "FAIL [$L] $N off=$O size=$S step=$B seq=$seq spd_dump.file=$f1 spdhost.file=$f2"
		fails=$((fails + 1))
	fi
}
run A misc 0 1048576 4096
run B misc 0 1048576 63488
run C bigpart 0x140000000 1048576 4096
run D bigpart 0xFFFF8000 0x10000 4096
run E bigpart 0x17FFF0000 0x10000 63488
run F misc 0x1000 0x3001 4096
# Past the end (mock accepts READ_START): data is clipped; spdhost must exit 1.
MOCK_LOOSE=1 run G misc 0xFF000 0x2000 4096 0x1000
MOCK_LOOSE=1 run H misc 0xFF800 0x1000 4096 0x800
grep -q 'INCOMPLETE' sh_G.log && grep -q 'INCOMPLETE' sh_H.log && echo "PASS [G,H] spdhost reports short read (INCOMPLETE, rc 1)" || { echo "FAIL [G,H] short read not reported"; fails=$((fails + 1)); }
# No explicit step: spd_dump's highspeed (FDL1 @0x65000800) blk 0xf800 == spdhost default.
run I misc 0 1048576 default
run J bigpart 0x17FFF0000 0x10000 default
# spdhost --step takes hex like spd_dump blk_size.
run K misc 0 0x20000 0xf800
echo "read-part-seq: $((12 - fails)) passed, $fails failed"
(( fails == 0 ))
