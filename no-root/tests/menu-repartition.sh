#!/usr/bin/env bash
# Menu [8]: the XML preview shown before a repartition is confirmed.
#
# Repartitioning rewrites the on-device partition map; a wrong XML bricks the
# phone. The preview is the last thing the user reads before typing `yes`, so
# it has to count and list exactly the entries the C parser will act on.
#
# The bug this guards: the old preview counted with a line pipeline
# (`grep <Partition | grep id= | grep -c size=`), which silently reported
# "No <Partition ...> entries" for a legal XML that puts id="..." and
# size="..." on separate lines inside one tag. A preview that refuses the
# right file is as bad as one that accepts a wrong file.
#
# Usage (from no-root/): tests/menu-repartition.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# Run the preview in a fresh shell: SPDHOST_MENU_LIB=1 loads functions only.
preview() {
	SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true \
		bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
			repartition_xml_preview "$2"; echo "rc=$?"' _ "$root" "$1"
}

echo "== a well-formed XML is accepted and listed =="
cat >"$tmp/ok.xml" <<'X'
<Partitions>
  <Partition id="boot" size="0x4000000" />
  <Partition id="system" size="0x80000000" />
</Partitions>
X
out=$(preview "$tmp/ok.xml")
check "a two-entry XML is accepted" bash -c '[[ $1 == *"rc=0"* ]]' _ "$out"
check "the count is right" bash -c '[[ $1 == *"(2 entries)"* ]]' _ "$out"
check "the first entry is listed" bash -c '[[ $1 == *"id=\"boot\""* ]]' _ "$out"
check "the second entry is listed" bash -c '[[ $1 == *"id=\"system\""* ]]' _ "$out"

echo
echo "== id and size on separate lines inside one tag is still one entry =="
cat >"$tmp/multiline.xml" <<'X'
<Partitions>
  <Partition
      id="boot"
      size="0x4000000" />
  <Partition id="system"
      size="0x80000000" />
</Partitions>
X
out=$(preview "$tmp/multiline.xml")
check "a multi-line tag is not rejected" bash -c '[[ $1 == *"rc=0"* ]]' _ "$out"
check "a multi-line tag is counted" bash -c '[[ $1 == *"(2 entries)"* ]]' _ "$out"
check "its id is still listed" bash -c '[[ $1 == *"id=\"boot\""* ]]' _ "$out"

echo
echo "== size before id is a legal attribute order too =="
cat >"$tmp/order.xml" <<'X'
<Partitions>
  <Partition size="0x4000000" id="boot" />
</Partitions>
X
out=$(preview "$tmp/order.xml")
check "size-then-id counts as an entry" bash -c '[[ $1 == *"(1 entries)"* ]]' _ "$out"
check "and is listed" bash -c '[[ $1 == *"id=\"boot\""* ]]' _ "$out"

echo
echo "== and the things that must be refused still are =="
printf '<Partitions><Partition id="boot" /></Partitions>\n' >"$tmp/nosize.xml"
out=$(preview "$tmp/nosize.xml")
check "a Partition with no size is refused" bash -c '[[ $1 == *"rc=1"* ]]' _ "$out"
check "…with the reason" bash -c '[[ $1 == *"No <Partition"* ]]' _ "$out"

printf '<Partitions></Partitions>\n' >"$tmp/empty.xml"
out=$(preview "$tmp/empty.xml")
check "an empty Partitions list is refused" bash -c '[[ $1 == *"rc=1"* ]]' _ "$out"

printf '<Partition id="boot" size="0x4000000" />\n' >"$tmp/nolist.xml"
out=$(preview "$tmp/nolist.xml")
check "entries with no <Partitions> wrapper are refused" bash -c '[[ $1 == *"rc=1"* ]]' _ "$out"

printf '<Partitions>\n<Partition id="boot" size="0x40" />\n\0\n</Partitions>\n' >"$tmp/nul.xml"
out=$(preview "$tmp/nul.xml")
check "an XML with a NUL byte is refused" bash -c '[[ $1 == *"rc=1"* ]]' _ "$out"
check "…with the reason" bash -c '[[ $1 == *"zero byte"* ]]' _ "$out"

: >"$tmp/zero.xml"
out=$(preview "$tmp/zero.xml")
check "an empty file is refused" bash -c '[[ $1 == *"rc=1"* ]]' _ "$out"

out=$(preview "$tmp/does-not-exist.xml")
check "a missing file is refused" bash -c '[[ $1 == *"rc=1"* ]]' _ "$out"

# 1 MiB + 1 byte, the size the C parser refuses.
{ printf '<Partitions><Partition id="boot" size="0x40" /></Partitions>'; head -c 1048576 /dev/zero | tr '\0' ' '; } >"$tmp/big.xml"
out=$(preview "$tmp/big.xml")
check "an over-1-MiB XML is refused" bash -c '[[ $1 == *"rc=1"* ]]' _ "$out"
check "…with its size" bash -c '[[ $1 == *"over 1 MiB"* ]]' _ "$out"

echo
echo "== R2: a name used twice is refused before any session =="
printf '%s\n' '<Partitions>' '<Partition id="boot" size="4"/>' '<Partition id="boot" size="4"/>' \
	'<Partition id="userdata" size="0xffffffff"/>' '</Partitions>' >"$tmp/dup.xml"
out=$(preview "$tmp/dup.xml")
check "R2: duplicate names are refused" bash -c '[[ $1 == *"rc=1"* && $1 == *"twice: id=\"boot\""* ]]' _ "$out"

echo
echo "== R2: no writable backup folder stops the menu before the session =="
printf '%s\n' '<Partitions>' '<Partition id="boot" size="4"/>' '<Partition id="userdata" size="0xffffffff"/>' '</Partitions>' >"$tmp/r2.xml"
out=$(SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true SPDHOST_PART_XML_DIR= bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
	need_loaders() { :; }; confirm_action() { echo ASKED; return 0; }; ready() { :; }
	run_session() { echo SESSION; }
	repartition_menu <<<"$2"; echo "rc=$?"' _ "$root" "$tmp/r2.xml")
check "R2: empty SPDHOST_PART_XML_DIR refuses, no confirm, no session" \
	bash -c '[[ $1 == *"rc=1"* && $1 == *"pre-repartition backup"* && $1 != *SESSION* && $1 != *ASKED* ]]' _ "$out"
out=$(SPDHOST_MENU_LIB=1 SPDHOST_MENU_RUNNER=/bin/true SPDHOST_PART_XML_DIR=$tmp/bkd bash -c 'source "$1/scripts/menu.sh" >/dev/null 2>&1
	need_loaders() { :; }; confirm_action() { return 0; }; ready() { :; }
	run_session() { echo "SESSION $*"; }
	repartition_menu <<<"$2"; echo "rc=$?"' _ "$root" "$tmp/r2.xml")
check "R2: with a backup folder the session runs repartition (no --yes)" \
	bash -c '[[ $1 == *"SESSION "*"repartition $2"* && $1 != *"--yes"* ]]' _ "$out" "$tmp/r2.xml"

echo
echo "menu-repartition: $pass passed, $fail failed"
(( fail == 0 ))
