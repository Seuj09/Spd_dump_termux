#!/usr/bin/env bash
# C5/C6 (audit6): the docs that ship, and the install commands in them.
#
#  - README describes the meta/ layout and gives a SHA256SUMS check that
#    works (keys are relative to the dump folder, so it runs from there).
#  - FAQ has one "Where do dumps go?" answer, with the same check.
#  - TUTORIAL's install blocks parse and run as pasted: a real tag shape (no
#    `TAG=...-<sha>` redirection syntax error), zip names that match the tag,
#    and the FAQ's plug-in order.
#  - The release zips carry FAQ.md and TUTORIAL.md, and the shipped TUTORIAL
#    is stamped with the build's own short sha.
#
# Usage (from no-root/): tests/docs-release.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

R=$root/README.md F=$root/FAQ.md T=$root/TUTORIAL.md X=$root/scripts/cross-arm32.sh

# ---- C5: README / FAQ describe meta/ and a working check command
check "C5 README: names meta/SHA256SUMS and the check run from the dump folder" \
	grep -qF 'cd /sdcard/Download && sha256sum -c meta/SHA256SUMS' "$R"
check "C5 README: no longer says SHA256SUMS/dump-manifest/partition_list land in the dump folder" \
	bash -c '! grep -q "partition_list.txt\` land in the dump folder" "$1" && ! grep -q "ones to \`SHA256SUMS\` in the dump folder" "$1"' _ "$R"
check "C5 README: dump DIR/meta/dump-manifest.txt" grep -qF 'DIR/meta/dump-manifest.txt' "$R"
check "C5 README: lists the image-only root rule" grep -q 'holds \*\*only\*\* the partition images' "$R"
check "C5 README: PAC extract never deletes the typed folder (no 'cannot overwrite' claim)" \
	bash -c 'grep -q "never deletes or replaces the folder you type" "$1" && ! grep -q "so it cannot overwrite a file you put" "$1"' _ "$R"
check "C5 FAQ: exactly one 'Where do dump(s| files) go?' section" \
	test "$(grep -cE '^### Where do dump(s| files) go\?' "$F")" = 1
check "C5 FAQ: the check command runs from the dump folder" \
	grep -qF 'cd /sdcard/Download && sha256sum -c meta/SHA256SUMS' "$F"
# The command itself, on a dump laid out the way the menu writes it.
d=$tmp/Download; mkdir -p "$d/meta"; echo img >"$d/boot_a.img"
( cd "$d" && sha256sum boot_a.img >meta/SHA256SUMS )
cmd=$(grep -oF 'cd /sdcard/Download && sha256sum -c meta/SHA256SUMS' "$R" | head -1)
check "C5: the README's check command passes on a meta/ dump" \
	bash -c "${cmd//\/sdcard\/Download/$d} >/dev/null"
check "C5: ...and 'cd meta && sha256sum -c SHA256SUMS' really fails (why the README says so)" \
	bash -c "! (cd '$d/meta' && sha256sum -c SHA256SUMS >/dev/null 2>&1)"

# ---- C6: TUTORIAL install commands
blocks=$tmp/install.sh
awk '/^## 2\./{s=1} /^## 3\./{s=0} s && /^```sh/{c=1; next} s && /^```/{c=0} c' "$T" >"$blocks"
check "C6: the install blocks were found (4 TAG/ZIP lines)" \
	test "$(grep -cE '^(TAG|ZIP)=' "$blocks")" = 4
check "C6: the install blocks parse (bash -n)" bash -n "$blocks"
check "C6: no <placeholder> syntax left" bash -c '! grep -q "<" "$1"' _ "$blocks"
check "C6: TAG is spdhost-exp-audit6-<7 hex>" \
	bash -c '[ "$(grep -cE "^TAG=spdhost-exp-audit6-[0-9a-f]{7}$" "$1")" = 2 ]' _ "$blocks"
check "C6: each ZIP is spdhost-arm{64,32}-static-<the TAG's sha>.zip" \
	bash -c 'grep "^TAG=" "$1" | sed "s/.*-//" | sort -u >"$1.t"; grep "^ZIP=" "$1" | sed -E "s/.*-([0-9a-f]{7})\.zip$/\1/" | sort -u >"$1.z"
		[ "$(wc -l <"$1.t")" = 1 ] && cmp -s "$1.t" "$1.z" &&
		grep -qE "^ZIP=spdhost-arm64-static-[0-9a-f]{7}\.zip$" "$1" && grep -qE "^ZIP=spdhost-arm32-static-[0-9a-f]{7}\.zip$" "$1"' _ "$blocks"
check "C6: curl fails on a 404 instead of saving the error page (-f)" \
	bash -c '[ "$(grep -c "curl -fLO" "$1")" = 2 ]' _ "$blocks"
step4=$(awk '/^## 4\./{s=1} /^## 5\./{s=0} s' "$T")
check "C6: step 4 waits for 'Plug the target in NOW' before the keys and the cable" \
	bash -c 'p=${1%%Plug the target in NOW*}; [[ $1 == *"Plug the target in NOW"* && $p != *"plug the cable in"* && ${1#*Plug the target in NOW} == *"plug the cable in"* ]]' _ "$step4"
check "C6: step 4 says the dialog appears on every plug-in, not 'later runs skip it'" \
	bash -c '[[ $1 == *"It appears on **every** plug-in"* && $1 != *"Later runs usually skip the prompt"* ]]' _ "$step4"

# ---- C5/C6: what the cross build ships
check "C5: the cross build copies FAQ.md into the package" grep -qE '^cp .*"\$root/FAQ.md"' "$X"
check "C5: the cross build writes TUTORIAL.md into the package" grep -qE '"\$root/TUTORIAL.md" >"\$pkg/TUTORIAL.md"' "$X"
# Run the cross script's own stamping line against a fake build sha.
stamp=$(grep -E '^sed -E .*TUTORIAL.md' "$X")
mkdir -p "$tmp/pkg"
check "C6: the stamping line exists" test -n "$stamp"
( root=$root pkg=$tmp/pkg short=abc1234; eval "$stamp" )
check "C6: the shipped TUTORIAL names the build's own tag and zips" \
	bash -c 'grep -qx "TAG=spdhost-exp-audit6-abc1234" "$1" && grep -qx "ZIP=spdhost-arm64-static-abc1234.zip" "$1" && grep -qx "ZIP=spdhost-arm32-static-abc1234.zip" "$1"' _ "$tmp/pkg/TUTORIAL.md"
check "C6: ...and changes nothing else" \
	bash -c 'diff <(grep -vE "^(TAG|ZIP)=" "$1") <(grep -vE "^(TAG|ZIP)=" "$2") >/dev/null' _ "$T" "$tmp/pkg/TUTORIAL.md"

echo
echo "docs-release: $pass passed, $fail failed"
(( fail == 0 ))
