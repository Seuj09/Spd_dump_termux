#!/usr/bin/env bash
# Golden test for the offline DHTB image tools in src/dhtb.c — the ports of the
# release's gen_spl-unlock, gen_spl-unlock-legacy, gen_fdl1-dl and chsize.
#
# Those four ship as x86-64 binaries, so the reference run goes through
# qemu-x86_64-static (this host is aarch64, like the phone). When qemu or the
# release tree is missing, the reference checks are reported as skipped instead
# of silently passing.
#
# The reference binaries are dynamic PIE executables. `qemu-x86_64-static PROG
# args` alone does NOT work for those here: qemu fails to resolve the interpreter
# and exits 1 with no output at all, which is easy to mistake for the tool
# rejecting its input. Neither does `-L`. Naming the guest loader explicitly
# does work, so that is what ref_run() does. Do not "simplify" it back.
#
# Usage (from no-root/): tests/dhtb-tools.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

REF=${DHTB_REF:-/root/ref/rel/spreadtrum_flash_termux}
QEMU=$(command -v qemu-x86_64-static || true)
X86_64_LOADER=${X86_64_LOADER:-/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2}
VARIANTS="full pair2 pair1 nopair short badmagic zeroh"

pass=0; fail=0; skip=0
check() { # name rc
	if [[ $2 == 0 ]]; then printf 'ok    %s\n' "$1"; pass=$((pass + 1))
	else printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); fi
}
note() { printf 'skip  %s\n' "$1"; skip=$((skip + 1)); }

cc -O2 -Wall -Wextra -std=c11 -D_FILE_OFFSET_BITS=64 -I"$root/src" \
	-o "$tmp/drv" "$root/src/dhtb.c" "$root/tests/dhtb_driver.c" || exit 1
python3 "$root/tests/dhtb_fixture.py" "$tmp/fx" || exit 1

# A reference run is only meaningful when qemu, the x86-64 loader and the binary
# are all present. Any one missing means "skip", never "pass".
#
# The binary must also be an x86-64 ELF: qemu-x86_64 cannot run anything else,
# and a wrong-arch or non-ELF file (a stray aarch64 build, a text stub) used to
# come back as an exit-code mismatch that looked like a code bug. It is skipped
# here with the reason instead. ref_why holds the reason for the last miss.
ref_why=""
is_x86_64_elf() {
	# e_ident: 7f 45 4c 46, EI_CLASS 2 (64-bit), EI_DATA 1 (LE); e_machine at
	# offset 18 is 0x3e (EM_X86_64), little-endian.
	local h
	h=$(od -An -tx1 -N20 -- "$1" 2>/dev/null | tr -d ' \n')
	[[ ${h:0:8} == 7f454c46 && ${h:8:2} == 02 && ${h:10:2} == 01 && ${h:36:4} == 3e00 ]]
}
have_ref() {
	ref_why=""
	if [[ -z $QEMU || ! -x $X86_64_LOADER ]]; then
		ref_why="no reference binary"
		return 1
	fi
	if [[ ! -f $REF/$1 ]]; then
		ref_why="no reference binary"
		return 1
	fi
	if ! is_x86_64_elf "$REF/$1"; then
		ref_why="reference $REF/$1 is not an x86-64 ELF binary; reference comparison skipped"
		return 1
	fi
	return 0
}

# The arch gate itself, on crafted 20-byte ELF headers (no qemu needed).
elfhdr() { # CLASS MACHINE_LO MACHINE_HI -> stdout
	printf '%b' "\\x7fELF\\x$1\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x$2\\x$3"
}
elfhdr 02 3e 00 > "$tmp/elf-x86_64"
elfhdr 02 b7 00 > "$tmp/elf-aarch64"
elfhdr 01 03 00 > "$tmp/elf-i386"
printf '#!/bin/sh\nexit 0\n' > "$tmp/elf-script"
is_x86_64_elf "$tmp/elf-x86_64"
check "ref gate: an x86-64 ELF header is accepted" $?
! is_x86_64_elf "$tmp/elf-aarch64" && ! is_x86_64_elf "$tmp/elf-i386" && ! is_x86_64_elf "$tmp/elf-script" &&
	! is_x86_64_elf "$tmp/does-not-exist"
check "ref gate: aarch64, i386, a script and a missing file are refused" $?
if [[ -n $QEMU && -x $X86_64_LOADER ]]; then
	mkdir -p "$tmp/fakeref" && cp "$tmp/elf-aarch64" "$tmp/fakeref/chsize"
	( REF=$tmp/fakeref; ! have_ref chsize && [[ $ref_why == *"not an x86-64 ELF binary"* ]] )
	check "ref gate: have_ref skips a non-x86-64 reference with the reason" $?
fi

echo "== golden: reference (qemu-x86_64) vs spdhost =="
if [[ -z $QEMU ]]; then
	note "qemu-x86_64-static not found: reference comparisons skipped"
elif [[ ! -x $X86_64_LOADER ]]; then
	note "$X86_64_LOADER not found: reference comparisons skipped"
fi

for spec in \
	gen_spl-unlock:gen-spl-unlock:spl-unlock.bin \
	gen_spl-unlock-legacy:gen-spl-unlock-legacy:spl-unlock.bin \
	gen_fdl1-dl:gen-fdl1-dl:fdl1-dl.bin \
	chsize:chsize:in.bin
do
	rt=${spec%%:*}; rest=${spec#*:}
	ot=${rest%%:*};  outn=${rest#*:}

	for v in $VARIANTS; do
		fx="$tmp/fx/$v.bin"
		name="$ot/$v"

		# ours: never touches IN, writes OUT
		before=$(sha256sum "$fx" | awk '{print $1}')
		rm -f "$tmp/ours.out"
		"$tmp/drv" "$ot" "$fx" "$tmp/ours.out" >"$tmp/ours.stdout" 2>"$tmp/ours.stderr"
		ours_rc=$?
		after=$(sha256sum "$fx" | awk '{print $1}')
		[[ $before == "$after" ]]
		check "$name: input left untouched" $?

		if ! have_ref "$rt"; then
			note "$name: $ref_why"
			continue
		fi

		rd="$tmp/ref/$rt-$v"; mkdir -p "$rd"
		cp "$fx" "$rd/in.bin"
		( cd "$rd" && "$QEMU" "$X86_64_LOADER" "$REF/$rt" in.bin \
			>stdout.txt 2>stderr.txt )
		ref_rc=$?

		[[ $ours_rc == "$ref_rc" ]]
		check "$name: exit code ($ours_rc vs $ref_rc)" $?

		# chsize rewrites IN in place; the others drop a named file. Either
		# way, "produced nothing" is a real outcome on short/badmagic/zeroh.
		ref_produced=0
		if [[ $outn == in.bin ]]; then
			cmp -s "$rd/in.bin" "$fx" || ref_produced=1
		elif [[ -f $rd/$outn ]]; then
			ref_produced=1
		fi

		if (( ref_produced )); then
			cmp -s "$rd/$outn" "$tmp/ours.out"
			check "$name: output bytes identical" $?
		else
			[[ ! -s $tmp/ours.out ]]
			check "$name: both wrote nothing" $?
		fi
	done
done

echo
echo "== patched-site reporting (drives the menu's legacy fallback) =="
for ot in gen-spl-unlock gen-spl-unlock-legacy gen-fdl1-dl; do
	"$tmp/drv" "$ot" "$tmp/fx/full.bin" "$tmp/ours.out" >/dev/null 2>"$tmp/ours.stderr"
	grep -qE 'patched [1-9][0-9]* signature site' "$tmp/ours.stderr"
	check "$ot: reports a non-zero site count on full.bin" $?
done
"$tmp/drv" chsize "$tmp/fx/full.bin" "$tmp/ours.out" >/dev/null 2>"$tmp/ours.stderr"
grep -q 'patched' "$tmp/ours.stderr" && rc=1 || rc=0
check "chsize: reports no patching" $rc

echo
echo "== size math =="
"$tmp/drv" chsize "$tmp/fx/full.bin" "$tmp/ours.out" >"$tmp/s1" 2>/dev/null
[[ $(cat "$tmp/s1") == "0x1800" ]]; check "full.bin -> 0x1800 (first pair)" $?
"$tmp/drv" chsize "$tmp/fx/pair2.bin" "$tmp/ours.out" >"$tmp/s2" 2>/dev/null
[[ $(cat "$tmp/s2") == "0x1000" ]]; check "pair2.bin -> 0x1000 (middle pair)" $?
"$tmp/drv" chsize "$tmp/fx/pair1.bin" "$tmp/ours.out" >"$tmp/s3" 2>/dev/null
[[ $(cat "$tmp/s3") == "0xe00" ]]; check "pair1.bin -> 0xe00 (first pair)" $?
"$tmp/drv" chsize "$tmp/fx/nopair.bin" "$tmp/ours.out" >"$tmp/s4" 2>/dev/null
[[ $(cat "$tmp/s4") == "0x1200" ]]; check "nopair.bin -> 0x1200 (H+0x200)" $?

echo
echo "dhtb-tools: $pass passed, $fail failed, $skip skipped"
(( fail == 0 ))
