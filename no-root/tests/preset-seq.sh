#!/usr/bin/env bash
# preset_modem / preset_resign / check-part / read-part "full" vs vendored spd_dump.
# Same fake libusb (tests/mock_fdl2.c) for both, same KiB table, same mock device,
# so a preset that picks a different partition set or reads different bytes fails.
# Usage (from no-root/): tests/preset-seq.sh
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
gcc -O2 -w -std=c11 -D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" \
	"$root/src/dumpcmd.c" "$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" \
	-o "$tmp/sh" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"

# KiB units, min 1024 so spd_dump's divisor stays 10 (units << 10 = bytes) and
# the mock's part_size (kb << 10) agrees with what spdhost reads out of it.
# The nv2 partners must be present: dump reads l_*nv1 from l_*nv2 at +512.
printf '%s\n' 'misc 1024' 'uboot_a 1024' 'boot_a 4096' 'vbmeta 1024' 'sml 1024' \
	'trustos 1024' 'teecfg 1024' 'recovery 32768' 'l_fixnv1 2048' 'l_fixnv2 2048' \
	'l_runtimenv1 1024' 'l_runtimenv2 1024' 'l_dsp 4096' 'nr_fixnv1 1024' 'nr_fixnv2 1024' \
	'nvefs 1024' 'userdata 8192' > "$tmp/pt"

spd_run() { # DIR MODE
	local d=$1 m=$2; mkdir -p "$d"
	( cd "$d" && MOCK_PTABLE="$tmp/pt" MOCK_SLOT=a MOCK_LOG="$d/sd.seq" TERMUX_USB_FD=7 \
		timeout 120 "$tmp/sd" exec_addr 0x65015f08 fdl "$tmp/fdl1-dl.bin" 0x65000800 \
		fdl "$tmp/fdl2-dl.bin" 0x9efffe00 exec r "$m" reset 7</dev/null </dev/null >sd.log 2>&1 )
}
sh_run() { # DIR CMD...
	local d=$1; shift; mkdir -p "$d"
	( cd "$d" && MOCK_PTABLE="$tmp/pt" MOCK_SLOT=a MOCK_LOG="$d/sh.seq" \
		timeout 120 "$tmp/sh" --usb-fd 7 exec_addr 0x65015f08 "$tmp/custom_exec_no_verify_65015f08.bin" \
		fdl "$tmp/fdl1-dl.bin" 0x65000800 fdl "$tmp/fdl2-dl.bin" 0x9efffe00 "$@" reset \
		7</dev/null </dev/null >sh.log 2>&1 )
}
# Same session, but stdout is what the caller gets: for the commands whose whole
# answer is a number on stdout (check-part, part-size). Digits only, one line.
sh_out() { # DIR CMD...
	local d=$1; shift; mkdir -p "$d"
	( cd "$d" && MOCK_PTABLE="$tmp/pt" MOCK_SLOT=a MOCK_LOG="$d/sh.seq" \
		timeout 120 "$tmp/sh" --usb-fd 7 exec_addr 0x65015f08 "$tmp/custom_exec_no_verify_65015f08.bin" \
		fdl "$tmp/fdl1-dl.bin" 0x65000800 fdl "$tmp/fdl2-dl.bin" 0x9efffe00 "$@" reset \
		7</dev/null 2>/dev/null | grep -xE '[0-9]+' | tr '\n' ' ' )
}
# menu DIR/*.img vs spd_dump DIR/*.bin: same names, same bytes. misc-slotinfo.img is
# spdhost's own 32-byte slot record and has no spd_dump counterpart.
same_as_spd() { # MENUDIR SPDDIR
	local m=$1 s=$2 f n rc=0 a b
	a=$(cd "$m" && ls *.img 2>/dev/null | grep -vx misc-slotinfo.img | sed 's/\.img$//' | sort | tr '\n' ' ')
	b=$(cd "$s" && ls *.bin 2>/dev/null | grep -v -e '^fdl' -e '^custom_exec' -e '^sprdpart' | sed 's/\.bin$//' | sort | tr '\n' ' ')
	[[ $a == "$b" ]] || { echo "  spdhost: $a"; echo "  spd_dump: $b"; return 1; }
	for n in $a; do
		[[ -f "$s/$n.bin" ]] || continue
		cmp -s "$m/$n.img" "$s/$n.bin" || { echo "  $n differs"; rc=1; }
	done
	return $rc
}
# preset_resign names its files differently on each side: spd_dump writes the
# loop-list name (boot.bin) even though it read boot_a, spdhost writes the
# resolved table name (boot_a.img), the same rule all/all_lite already use.
# The invariant that matters is the same partitions read to the same bytes.
same_bytes_as_spd() { # MENUDIR SPDDIR
	local x y
	x=$(cd "$1" && ls *.img | grep -vx misc-slotinfo.img | xargs -r sha256sum | awk '{print $1}' | sort)
	y=$(cd "$2" && ls *.bin | grep -v -e '^fdl' -e '^custom_exec' -e '^sprdpart' | xargs -r sha256sum | awk '{print $1}' | sort)
	[[ $x == "$y" ]] || { echo "  spdhost bytes: $(tr '\n' ' ' <<<"$x")"; echo "  spd_dump bytes: $(tr '\n' ' ' <<<"$y")"; return 1; }
}

# ---- preset_modem: l_* + nr_* (+ misc when A/B) ----
sh_run "$tmp/m1" parts "$tmp/m1/pt.txt" dump preset_modem "$tmp/m1"; rc=$?
spd_run "$tmp/m1sd" preset_modem
check "preset_modem rc=0 ($rc)" test "$rc" = 0
check "preset_modem == spd_dump r preset_modem (names+bytes)" same_as_spd "$tmp/m1" "$tmp/m1sd"
check "preset_modem took every l_* and nr_*, plus misc" bash -c \
	'cd "'"$tmp"'/m1" && for n in misc l_fixnv1 l_fixnv2 l_runtimenv1 l_runtimenv2 l_dsp nr_fixnv1 nr_fixnv2; do [ -f "$n.img" ] || exit 1; done'
check "preset_modem left boot/vbmeta/userdata alone" bash -c \
	'cd "'"$tmp"'/m1" && for n in boot_a vbmeta userdata nvefs uboot_a; do [ -e "$n.img" ] && exit 1; done; exit 0'
check "preset_modem misc is a fixed 1 MiB (spd_dump 0..1048576)" \
	test "$(stat -c %s "$tmp/m1/misc.img" 2>/dev/null || echo 0)" = 1048576

# ---- preset_resign: index 7 down to 0, missing rows skipped ----
sh_run "$tmp/r1" parts "$tmp/r1/pt.txt" dump preset_resign "$tmp/r1"; rc=$?
spd_run "$tmp/r1sd" preset_resign
check "preset_resign rc=0 ($rc)" test "$rc" = 0
check "preset_resign == spd_dump r preset_resign (same bytes)" same_bytes_as_spd "$tmp/r1" "$tmp/r1sd"
check "preset_resign is the spd_dump set, named by the resolved table name" bash -c \
	'cd "'"$tmp"'/r1" && [ -f recovery.img ] && [ -f boot_a.img ] && [ -f teecfg.img ] && [ -f trustos.img ] && [ -f sml.img ] && [ -f uboot_a.img ] && [ -f splloader.img ] && [ -f vbmeta.img ]'
check "preset_resign splloader is 256 KiB" test "$(stat -c %s "$tmp/r1/splloader.img")" = 262144

# ---- check-part (0/1, spd_dump check_part) and part-size (bytes, size_part) ----
# Two commands with two contracts: the reference prints 0/1 for check_part
# ("Checks if the specified partition exists", README.md:177, need_size=0 at
# spd_dump.c:925) and the byte count for size_part / part_size. Both read the
# slot-resolved live table here.
sh_run "$tmp/c1" parts "$tmp/c1/pt.txt" check-part boot check-part l_dsp check-part splloader \
	check-part nvefs check-part nosuchpart >/dev/null; rc=$?
check "check-part on a fresh session rc=0 ($rc)" test "$rc" = 0
out=$(sh_out "$tmp/c1" parts "$tmp/c1/pt2.txt" check-part boot check-part l_dsp \
	check-part splloader check-part nvefs check-part nosuchpart)
check "check-part prints 5 answers: $out" test "$(wc -w <<<"$out")" = 5
check "check-part: an existing partition is 1, an unknown name is 0" \
	test "$(awk '{print $1, $2, $3, $4, $5}' <<<"$out")" = "1 1 1 1 0"

out=$(sh_out "$tmp/c1" parts "$tmp/c1/pt3.txt" part-size boot part-size l_dsp \
	part-size splloader part-size nvefs part-size nosuchpart)
check "part-size boot -> boot_a 4096 KiB = 4194304, l_dsp 4194304, splloader 262144, nvefs 1048576" \
	test "$(awk '{print $1, $2, $3, $4}' <<<"$out")" = "4194304 4194304 262144 1048576"
check "part-size unknown name -> 0" test "$(awk '{print $5}' <<<"$out")" = 0
out=$(sh_out "$tmp/c1" parts "$tmp/c1/pt4.txt" size_part boot part_size boot)
check "part-size answers to the size_part / part_size spellings too: $out" \
	test "$(tr -d ' ' <<<"$out")" = "41943044194304"

# ---- read-part SIZE "-" / "full" / 0xffffffff: whole partition ----
sh_run "$tmp/f1" parts "$tmp/f1/pt.txt" read-part l_dsp 0 - "$tmp/f1/a.bin" \
	read-part boot 0 full "$tmp/f1/b.bin" read-part splloader 0 0xffffffff "$tmp/f1/c.bin"; rc=$?
check "read-part full rc=0 ($rc)" test "$rc" = 0
check "read-part l_dsp '-' -> 4194304 bytes" test "$(stat -c %s "$tmp/f1/a.bin" 2>/dev/null || echo 0)" = 4194304
check "read-part boot 'full' -> boot_a 4194304 bytes" test "$(stat -c %s "$tmp/f1/b.bin" 2>/dev/null || echo 0)" = 4194304
check "read-part splloader 0xffffffff -> 262144 bytes" test "$(stat -c %s "$tmp/f1/c.bin" 2>/dev/null || echo 0)" = 262144
check "read-part boot issued READ_START for boot_a, not boot" grep -q 'boot_a' "$tmp/f1/sh.log"

# an explicit size is still honoured, and an unknown name still reads (older behaviour)
sh_run "$tmp/f2" parts "$tmp/f2/pt.txt" read-part l_dsp 0 512 "$tmp/f2/part.bin"; rc=$?
check "read-part explicit 512 still honoured ($rc)" test "$(stat -c %s "$tmp/f2/part.bin" 2>/dev/null || echo 0)" = 512
sh_run "$tmp/f3" parts "$tmp/f3/pt.txt" read-part nosuch 0 - "$tmp/f3/x.bin"; rc=$?
check "read-part unknown + full: refused, nonzero rc ($rc), size was needed" \
	bash -c "[ $rc != 0 ] && [ ! -e '$tmp/f3/x.bin' ] && grep -q 'no size for' '$tmp/f3/sh.log'"

echo
echo "preset-seq: $pass passed, $fail failed"
[[ $fail = 0 ]]
