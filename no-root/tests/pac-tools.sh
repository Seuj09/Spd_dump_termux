#!/usr/bin/env bash
# Golden test for the PAC reader in src/pac.c against the vendor `unpac`.
#
# The release ships `unpac` as an x86-64 binary. Like the DHTB tools it is a
# dynamic PIE, so `qemu-x86_64-static PROG args` does NOT run it here (qemu
# exits 1 with no output at all); naming the guest loader explicitly does. See
# tests/dhtb-tools.sh for the same note.
#
# Coverage: list/check output, every header guard, every entry field shape,
# name filters, extract contents, and the unsafe-filename refusal. The one
# place we deliberately differ from the vendor is the exit status after a
# refused name -- see the "deliberate divergence" section at the end.
#
# Usage (from no-root/): tests/pac-tools.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

REF=${PAC_REF:-/root/ref/rel/spreadtrum_flash_termux}
QEMU=$(command -v qemu-x86_64-static || true)
X86_64_LOADER=${X86_64_LOADER:-/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2}
FX=$tmp/fx

pass=0; fail=0; skip=0
check() { # name rc
	if [[ $2 == 0 ]]; then printf 'ok    %s\n' "$1"; pass=$((pass + 1))
	else printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); fi
}
note() { printf 'skip  %s\n' "$1"; skip=$((skip + 1)); }

cc -O2 -Wall -Wextra -std=c11 -D_FILE_OFFSET_BITS=64 -I"$root/src" \
	-o "$tmp/drv" "$root/src/pac.c" "$root/tests/pac_driver.c" || exit 1
python3 "$root/tests/pac_fixture.py" --suite "$FX" || exit 1
[[ -f $FX/INDEX ]] || { echo "fixture suite missing" >&2; exit 1; }
FIXTURES=$(cat "$FX/INDEX")

have_ref() { [[ -n $QEMU && -x $X86_64_LOADER && -f $REF/unpac ]]; }

echo "== golden: reference (qemu-x86_64) vs spdhost =="
# Every reference comparison below is gated on have_ref(). When the reference
# is absent this suite must report skips, not failures: an empty $REF/unpac
# produces empty output, which would otherwise read as the vendor disagreeing
# with us on every single case. On a CI runner that is exactly what happens --
# the release tree is a local artifact and is not in this repository.
if [[ -z $QEMU ]]; then
	note "qemu-x86_64-static not found: reference comparisons skipped"
elif [[ ! -x $X86_64_LOADER ]]; then
	note "$X86_64_LOADER not found: reference comparisons skipped"
elif [[ ! -f $REF/unpac ]]; then
	note "$REF/unpac not found: reference comparisons skipped"
fi

# Run both tools in their own copy of the fixture dir. Reference stdout/stderr
# go outside the dir so they are not mistaken for extracted payloads.
ref_run() { # dir mode [args...]
	local d=$1; shift
	( cd "$d" && "$QEMU" "$X86_64_LOADER" "$REF/unpac" "$@" )
}
our_run() {
	local d=$1; shift
	( cd "$d" && "$tmp/drv" "$@" )
}

# (path, sha256) of everything extracted, sorted.
tree_hash() {
	( cd "$1" && find . -type f ! -name '*.pac' -print0 2>/dev/null |
		sort -z | xargs -0 -r sha256sum )
}

setup_pair() { # fixture -> $tmp/a $tmp/b
	rm -rf "$tmp/a" "$tmp/b"
	mkdir -p "$tmp/a" "$tmp/b"
	cp "$FX/$1.pac" "$tmp/a/" && cp "$FX/$1.pac" "$tmp/b/"
}

# ---------------------------------------------------------------- list/check
for mode in list check; do
	for f in $FIXTURES; do
		setup_pair "$f"
		our_run "$tmp/b" "$mode" "$f.pac" >"$tmp/o.out" 2>"$tmp/o.err"
		orc=$?

		if ! have_ref; then
			note "$mode/$f: no reference binary"
			continue
		fi

		ref_run "$tmp/a" "$mode" "$f.pac" >"$tmp/r.out" 2>"$tmp/r.err"
		rrc=$?

		cmp -s "$tmp/r.out" "$tmp/o.out"
		check "$mode/$f: stdout identical" $?
		cmp -s "$tmp/r.err" "$tmp/o.err"
		check "$mode/$f: stderr identical" $?
		[[ $rrc == "$orc" ]]
		check "$mode/$f: exit code ($orc vs $rrc)" $?
	done
done

# ------------------------------------------------------------------ extract
# $EXTRACT_SAFE are fixtures where no entry is refused, so the two tools must
# agree completely. The rest are checked in the divergence section below.
EXTRACT_SAFE="main safe3 emptyname zeroff probe"
for f in $EXTRACT_SAFE; do
	setup_pair "$f"
	our_run "$tmp/b" extract "$f.pac" >"$tmp/o.out" 2>"$tmp/o.err"
	orc=$?

	if ! have_ref; then
		note "extract/$f: no reference binary"
		continue
	fi

	ref_run "$tmp/a" extract "$f.pac" >"$tmp/r.out" 2>"$tmp/r.err"
	rrc=$?

	cmp -s "$tmp/r.out" "$tmp/o.out"
	check "extract/$f: stdout identical" $?
	[[ $rrc == "$orc" ]]
	check "extract/$f: exit code ($orc vs $rrc)" $?
	ra=$(tree_hash "$tmp/a"); rb=$(tree_hash "$tmp/b")
	[[ $ra == "$rb" ]]
	check "extract/$f: extracted bytes identical" $?
done

# Extracted payloads must match the manifest the generator wrote.
# `payloads` holds only safe names, so extraction runs to the end.
if [[ -f $FX/payloads.pac.manifest ]]; then
	setup_pair payloads
	our_run "$tmp/b" extract payloads.pac >/dev/null 2>&1
	bad=0
	while IFS=$'\t' read -r name size sha; do
		[[ -z $name ]] && continue
		[[ -f $tmp/b/$name ]] || { bad=1; echo "  missing $name"; continue; }
		[[ $(stat -c%s "$tmp/b/$name") == "$size" ]] || { bad=1; echo "  size $name"; }
		[[ $(sha256sum "$tmp/b/$name" | awk '{print $1}') == "$sha" ]] ||
			{ bad=1; echo "  sha $name"; }
	done <"$FX/payloads.pac.manifest"
	check "extract/payloads: bytes match the manifest" $bad
else
	note "extract: no manifest to check payloads against"
fi

# -------------------------------------------------------------- name filters
# The filter matches the file name or the partition id, is case-sensitive, and
# supports * and ?. "FDL" is the id of fdl1.bin, so it selects the same entry.
while IFS=: read -r pat expect; do
	[[ -z $pat ]] && continue
	setup_pair main
	our_run "$tmp/b" extract main.pac "$pat" >"$tmp/o.out" 2>&1
	got=$(sort "$tmp/o.out" | tr '\n' ' ' | sed 's/ *$//')
	[[ $got == "$expect" ]]
	check "extract filter '$pat' -> '${expect:-<nothing>}'" $?
done <<'EOF'
fdl1.bin:fdl1.bin
FDL:fdl1.bin
f?l1.bin:fdl1.bin
MODEM.BIN:
nosuch.bin:
EOF

# ------------------------------------------------------------------- -d dir
setup_pair main
mkdir -p "$tmp/b/out"
our_run "$tmp/b" -d out extract main.pac >/dev/null 2>&1
[[ -f $tmp/b/out/fdl1.bin ]]
check "-d DIR: writes into the directory" $?

# The vendor tool requires DIR to exist; we create it.
setup_pair main
our_run "$tmp/b" -d fresh/deep extract main.pac >/dev/null 2>&1
[[ -f $tmp/b/fresh/deep/fdl1.bin ]]
check "-d DIR: creates a missing directory" $?

# ------------------------------------------------------- usage / bad input
for args in "" "bogus x.pac"; do
	our_run "$tmp" $args >"$tmp/o.out" 2>"$tmp/o.err"
	[[ $? == 1 && -s $tmp/o.err ]]
	check "usage: '$args' exits 1 with a message" $?
done
our_run "$tmp" list "$tmp/nope.pac" >/dev/null 2>"$tmp/o.err"
[[ $? == 1 ]] && grep -q 'fopen(input) failed' "$tmp/o.err"
check "missing file: reports fopen(input) failed" $?

if have_ref; then
	setup_pair badentrylen
	ref_run "$tmp/a" list badentrylen.pac >/dev/null 2>"$tmp/r.err"; rrc=$?
	our_run "$tmp/b" list badentrylen.pac >/dev/null 2>"$tmp/o.err"; orc=$?
	[[ $rrc == "$orc" ]] && cmp -s "$tmp/r.err" "$tmp/o.err"
	check "bad entry length: same message and exit code" $?

	setup_pair nomagic
	ref_run "$tmp/a" list nomagic.pac >/dev/null 2>"$tmp/r.err"; rrc=$?
	our_run "$tmp/b" list nomagic.pac >/dev/null 2>"$tmp/o.err"; orc=$?
	[[ $rrc == "$orc" ]] && cmp -s "$tmp/r.err" "$tmp/o.err"
	check "bad magic: same message and exit code" $?
fi

# ------------------------------------------------- deliberate divergence
# The vendor tool refuses a name containing / \ or : (it never writes the
# file), but its exit status depends on whether another entry follows: a
# refusal on the LAST entry leaves it at 0, even though a requested file was
# silently dropped. We always report failure for a refused name.
#
# Unsafe names must never be written by either tool, and stdout must still
# match, so this stays a difference in exit status only.
for f in unsafe_last unsafe_mid unsafe_first colon backslash dotdot onlyunsafe; do
	setup_pair "$f"
	our_run "$tmp/b" extract "$f.pac" >"$tmp/o.out" 2>"$tmp/o.err"; orc=$?

	# The three checks that do not need the vendor tool, so they run always:
	# neither tool may create a file outside the flat directory, the refusal
	# must be reported, and we must exit non-zero for it. That last one is the
	# whole point of this section, so it is asserted here rather than left to
	# the comparison below.
	if [[ -z $(find "$tmp/a" "$tmp/b" -mindepth 2 -type f -name '*.bin' 2>/dev/null) ]]
	then check "unsafe/$f: nothing written to a subdirectory" 0
	else check "unsafe/$f: nothing written to a subdirectory" 1; fi
	grep -q '!!! unsafe filename detected' "$tmp/o.out"
	check "unsafe/$f: reports the refusal" $?
	[[ $orc == 1 ]]
	check "unsafe/$f: we exit 1 on a refused name" $?

	if ! have_ref; then
		note "unsafe/$f: no reference binary"
		continue
	fi

	ref_run "$tmp/a" extract "$f.pac" >"$tmp/r.out" 2>"$tmp/r.err"; rrc=$?

	cmp -s "$tmp/r.out" "$tmp/o.out"
	check "unsafe/$f: stdout identical" $?

	if [[ $f == unsafe_mid || $f == unsafe_first ]]; then
		[[ $rrc == 1 && $orc == 1 ]]
		check "unsafe/$f: both fail (refusal is not the last entry)" $?
	else
		[[ $rrc == 0 && $orc == 1 ]]
		check "unsafe/$f: ref says 0, we say 1 (documented)" $?
	fi
done

echo
echo "pac-tools: $pass passed, $fail failed, $skip skipped"
(( fail == 0 ))
