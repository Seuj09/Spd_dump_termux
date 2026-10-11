#!/usr/bin/env bash
# P0-6: `spdhost loaders check|list|verify`, fdl/index, menu.sh on the core
# check, and the deterministic fdl-pack-<sha7>.zip.
#
# The chip/pair/stub rules (A7, audit6 C3) used to live only in menu.sh. The
# core now owns them so the menu and the app share one implementation:
#   - two loaders of two chips are not a pair (refused);
#   - a chip given by the caller must be the one the loaders are;
#   - FDL1/FDL2 addresses are a function of the chip;
#   - the exec stub must be the chip's, go with its FDL1 address, and be the
#     indexed bytes for that address;
#   - a file at an indexed path must carry the indexed sha256; a shipped
#     fdl2-cboot/stub/fdl2 is never accepted as something else;
#   - a refusal in the menu changes nothing (globals and config roll back).
# Everything is offline: no libusb call (trap build), no USB, no writes.
#
# Usage (from no-root/): tests/loaders-check.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }

cc=${CC:-cc}
make -C "$root" spdhost >"$tmp/make.log" 2>&1 || { tail -20 "$tmp/make.log"; echo "loaders-check: build failed"; exit 1; }
bin=$root/spdhost
F=$root/fdl
U9=$F/ums9230

lc() { "$bin" loaders check "$@" 2>"$tmp/lc.err"; }
verdict() { # expected-rc expected-verdict ARGS...
	local want_rc=$1 want=$2 out rc; shift 2
	out=$(lc "$@"); rc=$?
	[[ $rc == "$want_rc" && $'\n'$out$'\n' == *$'\n'"verdict=$want"$'\n'* && $out == loaders_format=1$'\n'* && $out == *$'\n'end ]]
}
reason() { lc "$@" | sed -n 's/^reason=//p'; }

echo "== fdl/index =="
check "fdl/index is current with the fdl/ tree (gen-fdl-index.sh --check)" \
	bash -c '"$1/scripts/gen-fdl-index.sh" --check "$1/fdl" >/dev/null' _ "$root"
check "every shipped file is indexed" \
	bash -c '[ "$(grep -c "^file " "$1/fdl/index")" = "$(find "$1/fdl" -type f ! -name index | wc -l)" ]' _ "$root"
out=$("$bin" loaders verify); rc=$?
check "loaders verify: the shipped tree matches its index (rc 0)" bash -c '[ "$1" = 0 ] && grep -qx verdict=ok <<<"$2" && grep -qx bad=0 <<<"$2"' _ "$rc" "$out"
check "loaders verify: 20 pairs, 65 files" bash -c 'grep -qx pairs=20 <<<"$1" && grep -qx files=65 <<<"$1"' _ "$out"
out=$("$bin" loaders list); rc=$?
check "loaders list: rc 0, one pair line per shipped pair, ends with end" \
	bash -c '[ "$1" = 0 ] && [ "$(grep -c "^pair " <<<"$2")" = 20 ] && [ "$(tail -1 <<<"$2")" = end ]' _ "$rc" "$out"
check "loaders list: infinix/hot12pro is listed with absolute paths and both sha256" \
	bash -c 'grep -qE "^pair ums9230 infinix/hot12pro /.*/alternatif/hot12pro/fdl1-dl.bin /.*fdl2-dl.bin [0-9a-f]{64} [0-9a-f]{64}$" <<<"$1"' _ "$out"
check "loaders list: the soc table is ums9230/ums512/sc9863a with the menu's addresses" \
	bash -c 'grep -qx "soc ums9230 fdl1=0x65000800 fdl2=0x9efffe00 stub=0x65015f08 stub_alt=0x65015f48" <<<"$1" &&
		grep -qx "soc ums512 fdl1=0x5500 fdl2=0x9efffe00 stub=0x3ee8 stub_alt=0x3f48" <<<"$1" &&
		grep -qx "soc sc9863a fdl1=0x5000 fdl2=0x9efffe00 stub=0x4ee8 stub_alt=0x4f48" <<<"$1"' _ "$out"
# The menu's soc_profile table and the core's must agree.
check "menu.sh soc_profile uses the same addresses as fdl/index" \
	bash -c 'for r in "ums9230 0x65000800 0x65015f08 0x65015f48" "ums512 0x5500 0x3ee8 0x3f48" "sc9863a 0x5000 0x4ee8 0x4f48"; do
		set -- $r; grep -A4 "^		$1)$" "'"$root"'/scripts/menu.sh" | grep -q "SOC_FDL1_ADDR=$2" || exit 1
		grep -A4 "^		$1)$" "'"$root"'/scripts/menu.sh" | grep -q "EXEC_ADDR_DEFAULT=$3" || exit 1
		grep -A5 "^		$1)$" "'"$root"'/scripts/menu.sh" | grep -q "EXEC_ADDR_ALT=$4" || exit 1; done'

echo "== every shipped pair passes, with both of its chip's stubs =="
nok=0 nbad=0
while read -r _ soc model f1 f2 _; do
	case $soc in ums9230) a1=0x65000800 s1=0x65015f08 s2=0x65015f48 ;; ums512) a1=0x5500 s1=0x3ee8 s2=0x3f48 ;; sc9863a) a1=0x5000 s1=0x4ee8 s2=0x4f48 ;; esac
	for ea in "" "$s1" "$s2" 0; do
		args=(); [[ -n $ea ]] && args=(--exec "$ea")
		out=$(lc "${args[@]}" "$f1" "$a1" "$f2" 0x9efffe00); rc=$?
		if [[ $rc == 0 ]] && grep -qx "pair=$soc/$model" <<<"$out" && grep -qx "soc=$soc" <<<"$out"; then
			nok=$((nok + 1))
		else
			nbad=$((nbad + 1)); echo "  pair $soc $model exec ${ea:-default}: rc=$rc"; fi
	done
done < <("$bin" loaders list | grep '^pair ')
check "all 20 shipped pairs x {default, stub, alt stub, no stub} pass with pair=<soc>/<model> ($nok ok)" test "$nbad" = 0 -a "$nok" = 80
out=$(lc "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00)
check "default stub is the chip's primary, found in fdl/<chip>/ and indexed" \
	bash -c 'grep -qx exec=0x65015f08 <<<"$1" && grep -q "^stub=.*/fdl/ums9230/custom_exec_no_verify_65015f08.bin$" <<<"$1" && grep -qx stub_id=index <<<"$1"' _ "$out"
out=$(lc --exec 0 "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00)
check "--exec 0 means no stub (exec=none)" bash -c 'grep -qx exec=none <<<"$1" && ! grep -q ^stub= <<<"$1"' _ "$out"
check "same sha shipped twice for one chip (realme/tecno fdl1) still identifies" \
	verdict 0 ok "$U9/tecno/fdl1-dl.bin" 0x65000800 "$U9/tecno/fdl2-dl.bin" 0x9efffe00

echo "== chip / pair refusals (A7, B2-6.1, audit6 C3) =="
check "chip-mixed pair (ums9230 FDL1 + sc9863a FDL2) is refused, rc 1" \
	verdict 1 refuse "$U9/infinix/fdl1-dl.bin" 0x65000800 "$F/sc9863a/realme/fdl2-dl.bin" 0x9efffe00
check "...reason says not a pair" has "$(reason "$U9/infinix/fdl1-dl.bin" 0x65000800 "$F/sc9863a/realme/fdl2-dl.bin" 0x9efffe00)" "not a pair: FDL1 is ums9230's and FDL2 is sc9863a's"
check "...and the refusal is also on stderr" grep -q "^loaders: refusing: not a pair" "$tmp/lc.err"
check "--soc that is not the loaders' chip is refused" \
	verdict 1 refuse --soc ums512 "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00
check "--soc none (another chip) with fdl/<chip> loaders is refused" \
	verdict 1 refuse --soc none "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00
check "FDL1 at another chip's address is refused" \
	verdict 1 refuse "$U9/infinix/fdl1-dl.bin" 0x5000 "$U9/infinix/fdl2-dl.bin" 0x9efffe00
check "FDL2 at a wrong address is refused (G9)" \
	verdict 1 refuse "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9f000000
check "a shipped fdl2-cboot.bin as FDL2 is refused (it is a uboot image, not a loader)" \
	has "$(reason "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-cboot.bin" 0x9efffe00)" "is a shipped cboot, not an fdl2"
check "FDL1/FDL2 swapped is refused (a shipped fdl2 is not an fdl1)" \
	verdict 1 refuse "$U9/infinix/fdl2-dl.bin" 0x65000800 "$U9/infinix/fdl1-dl.bin" 0x9efffe00
check "a shipped exec stub as FDL1 is refused" \
	verdict 1 refuse "$U9/custom_exec_no_verify_65015f08.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00
out=$(lc "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/realme/fdl2-dl.bin" 0x9efffe00); rc=$?
check "two shipped models of one chip: allowed (rc 0) but pair=mixed with a warning" \
	bash -c '[ "$1" = 0 ] && grep -qx pair=mixed <<<"$2" && grep -q "^warning=FDL1 and FDL2 are shipped loaders of different ums9230 models" <<<"$2"' _ "$rc" "$out"

echo "== exec stub =="
check "another chip's stub address is refused (ums512 stub, ums9230 loaders)" \
	has "$(reason --exec 0x3ee8 "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00)" "is ums512's stub but the loaders are ums9230's"
printf 'A' >"$tmp/p1.bin"; printf 'B' >"$tmp/p2.bin"
check "M4: sc9863a stub with FDL1 at 0x65000800 (plain files) is refused" \
	has "$(reason --exec 0x4ee8 "$tmp/p1.bin" 0x65000800 "$tmp/p2.bin" 0x9efffe00)" "goes with FDL1 at 0x5000"
check "an address no chip ships a stub for is refused without --stub" \
	has "$(reason --soc none --exec 0x1234 "$tmp/p1.bin" 0x5000 "$tmp/p2.bin" 0x9efffe00)" "no shipped chip's stub address"
check "the alt stub's file passed for the primary address is refused" \
	has "$(reason --exec 0x65015f08 --stub "$U9/custom_exec_no_verify_65015f48.bin" "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00)" "is the 0x65015f48 stub, not 0x65015f08"
check "another chip's stub file is refused" \
	verdict 1 refuse --exec 0x65015f08 --stub "$F/ums512/custom_exec_no_verify_3ee8.bin" "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00
check "--stub needs --exec" bash -c '"$1" loaders check --stub x a 0x1 b 0x2 >/dev/null 2>&1; [ $? = 2 ]' _ "$bin"

echo "== integrity: a copied pack with a tampered or missing file =="
cp -r "$F" "$tmp/pack"
printf 'X' >>"$tmp/pack/ums9230/infinix/fdl2-dl.bin"
check "a modified loader at an indexed path is refused" \
	has "$(reason --index "$tmp/pack/index" "$tmp/pack/ums9230/infinix/fdl1-dl.bin" 0x65000800 "$tmp/pack/ums9230/infinix/fdl2-dl.bin" 0x9efffe00)" "does not match fdl/index"
printf 'X' >>"$tmp/pack/ums9230/custom_exec_no_verify_65015f08.bin"
check "a modified exec stub at its indexed path is refused" \
	has "$(reason --index "$tmp/pack/index" "$tmp/pack/ums9230/realme/fdl1-dl.bin" 0x65000800 "$tmp/pack/ums9230/realme/fdl2-dl.bin" 0x9efffe00)" "exec stub:"
rm "$tmp/pack/sc9863a/itel/fdl1-dl.bin"
out=$("$bin" loaders verify --index "$tmp/pack/index"); rc=$?
check "loaders verify on the tampered pack: rc 1, mismatch x2 + missing x1 listed" \
	bash -c '[ "$1" = 1 ] && grep -qx verdict=refuse <<<"$2" && grep -qx bad=3 <<<"$2" &&
		grep -qx "mismatch ums9230/infinix/fdl2-dl.bin" <<<"$2" && grep -qx "missing sc9863a/itel/fdl1-dl.bin" <<<"$2"' _ "$rc" "$out"
printf 'L' >"$tmp/empty-ish"; : >"$tmp/empty"
check "an empty loader file is refused" has "$(reason --soc ums9230 "$tmp/empty" 0x65000800 "$tmp/empty-ish" 0x9efffe00)" "is empty"
check "a missing loader file is refused" has "$(reason --soc ums9230 "$tmp/nope" 0x65000800 "$tmp/empty-ish" 0x9efffe00)" "cannot open"
check "a directory as a loader is refused" has "$(reason --soc ums9230 "$tmp" 0x65000800 "$tmp/empty-ish" 0x9efffe00)" "not a regular file"

echo "== the index itself is checked =="
mkidx() { cp "$F/index" "$tmp/i.idx"; sed -i "$1" "$tmp/i.idx"; }
ib() { lc --index "$tmp/i.idx" "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00 | sed -n 's/^reason=//p'; }
mkidx 's/^soc ums9230 fdl1=0x65000800/soc ums9230 fdl1=0x5000/'
check "an index whose soc table disagrees with the build is refused" has "$(ib)" "addresses disagree with this spdhost build"
mkidx '/^end$/d'
check "a truncated index (no end) is refused" has "$(ib)" "no end line"
mkidx 's#ums9230/infinix/fdl1-dl.bin$#../../etc/passwd#'
check "an index path with .. is refused" has "$(ib)" "bad path"
mkidx '0,/^file / s/^file \([0-9a-f]*\) fdl1 /file \1 fdl1 /; 0,/ fdl1 ums9230 0x65000800 / s/ fdl1 ums9230 0x65000800 / fdl1 ums9230 0x5000 /'
check "an index row with an fdl1 at the wrong address is refused" has "$(ib)" "is not ums9230's"
mkidx '1,4s/^spdhost-fdl-index 1$/spdhost-fdl-index 2/'
check "an unknown index format is refused" has "$(ib)" "not an spdhost fdl index"
mkidx '$a\
garbage line'
check "text after end is refused" has "$(ib)" "text after end"
check "loaders list/verify refuse a bad index (rc 1)" bash -c '"$1" loaders verify --index "$2" >/dev/null 2>&1; [ $? = 1 ]' _ "$bin" "$tmp/i.idx"

echo "== no index: identity by path only =="
mkdir -p "$tmp/noidx"; cp "$bin" "$tmp/noidx/spdhost"
out=$(cd "$tmp/noidx" && ./spdhost loaders check "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00 --exec 0); rc=$?
check "no fdl/index next to the binary: index=none, identity from the fdl/<chip>/ path, still ok" \
	bash -c '[ "$1" = 0 ] && grep -qx index=none <<<"$2" && grep -qx fdl1_id=path <<<"$2" && grep -qx soc=ums9230 <<<"$2"' _ "$rc" "$out"
out=$(cd "$tmp/noidx" && ./spdhost loaders check "$U9/infinix/fdl1-dl.bin" 0x65000800 "$F/sc9863a/itel/fdl2-dl.bin" 0x9efffe00 --exec 0 2>/dev/null); rc=$?
check "no index: a path-named chip mix is still refused" bash -c '[ "$1" = 1 ] && grep -q "not a pair" <<<"$2"' _ "$rc" "$out"
check "loaders list with no index anywhere: rc 1 with a message" \
	bash -c 'cd "$1" && ./spdhost loaders list >/dev/null 2>"$1/e"; [ $? = 1 ] && grep -q "no fdl/index" "$1/e"' _ "$tmp/noidx"

echo "== plain (unshipped) files =="
out=$(lc --soc ums9230 "$tmp/p1.bin" 0x65000800 "$tmp/p2.bin" 0x9efffe00); rc=$?
check "unshipped files with an explicit chip: ok, id=none, pair=unknown" \
	bash -c '[ "$1" = 0 ] && grep -qx fdl1_id=none <<<"$2" && grep -qx pair=unknown <<<"$2" && grep -qx exec=0x65015f08 <<<"$2"' _ "$rc" "$out"
out=$(lc --soc none "$tmp/p1.bin" 0x5000 "$tmp/p2.bin" 0x9f000000); rc=$?
check "another chip with an unusual FDL2 address: ok with a warning, no stub" \
	bash -c '[ "$1" = 0 ] && grep -qx exec=none <<<"$2" && grep -q "^warning=FDL2 address 0x9f000000 is not 0x9efffe00" <<<"$2"' _ "$rc" "$out"
out=$(lc "$tmp/p1.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00); rc=$?
check "one shipped + one unshipped: ok, pair=partial with a warning" \
	bash -c '[ "$1" = 0 ] && grep -qx pair=partial <<<"$2" && grep -q "^warning=only one of" <<<"$2"' _ "$rc" "$out"

echo "== usage =="
for a in "" "check" "check a 0x1 b" "check a zz b 0x1" "check --soc ums9999 a 0x1 b 0x1" "check --bogus a 0x1 b 0x1" "frob" "list extra" "check --soc a --soc b x 0x1 y 0x1"; do
	# shellcheck disable=SC2086
	"$bin" loaders $a >/dev/null 2>&1; rc=$?
	check "usage: 'loaders $a' exits 2" test "$rc" = 2
done
check "'--' ends the options (menu passes it before the paths)" \
	verdict 0 ok --soc ums9230 -- "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-dl.bin" 0x9efffe00
check "--dry-run in front changes nothing (menu.sh calls it that way)" \
	bash -c '"$1" --dry-run loaders check "$2" 0x65000800 "$3" 0x9efffe00 | grep -qx verdict=ok' _ "$bin" "$U9/infinix/fdl1-dl.bin" "$U9/infinix/fdl2-dl.bin"
check "caps lists loaders-check" bash -c '"$1" caps | grep -qx cap=loaders-check' _ "$bin"

echo "== offline: no libusb call at all (trap build) =="
srcs=("$root"/src/{main,usb,usb_list,proto,dumpcmd,writecmd,sha256,dhtb,pac,events,plan,loaders}.c)
wraps=-Wl,--wrap=libusb_init,--wrap=libusb_init_context,--wrap=libusb_wrap_sys_device,--wrap=libusb_open_device_with_vid_pid
if $cc -O1 -w -std=c11 -D_FILE_OFFSET_BITS=64 $(pkg-config --cflags libusb-1.0 2>/dev/null) \
	-o "$root/.loaders-trapped" "${srcs[@]}" "$root/tests/libusb_trap.c" "$wraps" \
	$(pkg-config --libs libusb-1.0 2>/dev/null || echo -lusb-1.0) 2>"$tmp/trap.log"; then
	mv "$root/.loaders-trapped" "$tmp/trapped"
	"$tmp/trapped" ping >/dev/null 2>"$tmp/t0.err"
	check "(the trap works: a device command hits it)" grep -q '^TRAP ' "$tmp/t0.err"
	for sub in "check --index $F/index $U9/infinix/fdl1-dl.bin 0x65000800 $U9/infinix/fdl2-dl.bin 0x9efffe00" \
		"check --index $F/index $U9/infinix/fdl1-dl.bin 0x65000800 $F/sc9863a/itel/fdl2-dl.bin 0x9efffe00" \
		"list --index $F/index" "verify --index $F/index"; do
		# shellcheck disable=SC2086
		"$tmp/trapped" loaders $sub >/dev/null 2>"$tmp/t1.err"
		check "loaders ${sub%% *}: no libusb call" bash -c '! grep -q TRAP "$1"' _ "$tmp/t1.err"
	done
else
	rm -f "$root/.loaders-trapped"
	bad "trapped build failed: $(tail -3 "$tmp/trap.log")"
fi

echo "== menu.sh switches to the core check =="
mkdir -p "$tmp/input" "$tmp/dump"
cat >"$tmp/runner" <<R
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/runner.argv"
exit 0
R
chmod +x "$tmp/runner"
menu_run() { # CONFFILE FN [ARGS...]
	local conf=$1; shift
	(
		export SPDHOST_MENU_LIB=1 SPDHOST_MENU_CONFIG=$conf
		export SPDHOST_INPUT_DIR=$tmp/input SPDHOST_DUMP_DIR=$tmp/dump
		export SPDHOST_MENU_RUNNER=$tmp/runner
		# shellcheck source=/dev/null
		source "$root/scripts/menu.sh" >/dev/null 2>&1
		load_config
		"$@"
	)
}
good_conf() {
	cat >"$1" <<EOF
FDL1=$U9/infinix/fdl1-dl.bin
FDL1_ADDR=0x65000800
FDL2=$U9/infinix/fdl2-dl.bin
FDL2_ADDR=0x9efffe00
EXEC_ADDR=0x65015f08
SOC=ums9230
EOF
}
good_conf "$tmp/good.conf"
menu_run "$tmp/good.conf" need_loaders >"$tmp/o" 2>&1
check "need_loaders: the shipped Infinix pair passes the core check" test $? = 0
# A saved config whose FDL2 is the model's fdl2-cboot.bin: every bash check
# passes (same chip folder, right addresses); only the core knows the bytes.
sed "s#^FDL2=.*#FDL2=$U9/infinix/fdl2-cboot.bin#" "$tmp/good.conf" >"$tmp/cboot.conf"
out=$(menu_run "$tmp/cboot.conf" need_loaders 2>&1); rc=$?
check "need_loaders: fdl2-cboot.bin as FDL2 is refused by the core (rc 1)" \
	bash -c '[ "$1" = 1 ] && [[ $2 == *"Refusing: FDL2: "*"is a shipped cboot, not an fdl2."* ]]' _ "$rc" "$out"
# The same refusal stops a session before the runner is called.
rm -f "$tmp/runner.argv"
sess() { need_loaders && run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" check-baud; }
menu_run "$tmp/cboot.conf" sess >/dev/null 2>&1
check "...and no session runs (the runner was never called)" test ! -e "$tmp/runner.argv"
menu_run "$tmp/good.conf" sess >/dev/null 2>&1
check "...while the good pair reaches the runner with the stub in front" \
	bash -c 'grep -q "^--timeout [0-9]* exec_addr 0x65015f08 .*custom_exec_no_verify_65015f08.bin fdl " "$1"' _ "$tmp/runner.argv"

# Manual entry [1] with fdl2-cboot as FDL2: refused by the core, and the C3
# roll-back puts every global back (nothing saved, the next session sends the
# previous pair).
manual_probe() {
	configure_loaders_manual
	printf 'RC=%s\n' "$?"
	printf 'G FDL2=%s SOC=%s EXEC_ADDR=%s S1=%s ED=%s\n' "$FDL2" "$SOC" "$EXEC_ADDR" "$SOC_FDL1_ADDR" "$EXEC_ADDR_DEFAULT"
}
good_conf "$tmp/m.conf"
cp "$tmp/m.conf" "$tmp/m.orig"
out=$(printf '%s\n' "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/infinix/fdl2-cboot.bin" 0x9efffe00 1 |
	menu_run "$tmp/m.conf" manual_probe 2>&1)
check "manual [1]: the core refusal is shown with 'Nothing saved'" \
	bash -c '[[ $1 == *"Refusing: FDL2: "*"shipped cboot"* && $1 == *"Nothing saved."* && $1 == *"RC=1"* ]]' _ "$out"
check "manual [1]: every global rolled back (C3)" has "$out" "G FDL2=$U9/infinix/fdl2-dl.bin SOC=ums9230 EXEC_ADDR=0x65015f08 S1=0x65000800 ED=0x65015f08"
check "manual [1]: the config file is unchanged" cmp -s "$tmp/m.conf" "$tmp/m.orig"
out=$(printf '%s\n' "$U9/realme/fdl1-dl.bin" 0x65000800 "$U9/realme/fdl2-dl.bin" 0x9efffe00 1 |
	menu_run "$tmp/m.conf" manual_probe 2>&1)
check "manual [1]: a good shipped pair is saved" bash -c '[[ $1 == *"RC=0"* ]] && grep -qx "FDL2=$2" "$3"' _ "$out" "$U9/realme/fdl2-dl.bin" "$tmp/m.conf"
out=$(printf '%s\n' "$U9/infinix/fdl1-dl.bin" 0x65000800 "$U9/realme/fdl2-dl.bin" 0x9efffe00 1 |
	menu_run "$tmp/m.conf" manual_probe 2>&1)
check "manual [1]: two models of one chip are saved with the core's note" \
	bash -c '[[ $1 == *"RC=0"* && $1 == *"loaders: note: FDL1 and FDL2 are shipped loaders of different ums9230 models"* ]]' _ "$out"

# A tampered package: select_shipped_model refuses before the confirm and
# restores the chip globals.
mkdir -p "$tmp/pkg"; cp -r "$root/scripts" "$tmp/pkg/scripts"; cp -r "$F" "$tmp/pkg/fdl"; cp "$bin" "$tmp/pkg/spdhost"
printf 'X' >>"$tmp/pkg/fdl/ums512/realme/fdl1-dl.bin"
pick_probe() {
	select_shipped_model ums512
	printf 'RC=%s S1=%s ED=%s SOC=%s\n' "$?" "${SOC_FDL1_ADDR:-}" "$EXEC_ADDR_DEFAULT" "${SOC:-}"
}
pkg_run() {
	(
		export SPDHOST_MENU_LIB=1 SPDHOST_MENU_CONFIG=$tmp/p.conf SPDHOST_INPUT_DIR=$tmp/input
		export SPDHOST_DUMP_DIR=$tmp/dump SPDHOST_MENU_RUNNER=$tmp/runner
		export SPDHOST_BIN=$tmp/pkg/spdhost
		# shellcheck source=/dev/null
		source "$tmp/pkg/scripts/menu.sh" >/dev/null 2>&1
		load_config
		pick_probe
	)
}
good_conf "$tmp/p.conf"
out=$(printf '%s\n' y 2 y yes | pkg_run 2>&1)
check "shipped model with a tampered loader: refused before the confirm" \
	bash -c '[[ $1 == *"Refusing: FDL1: "*"does not match fdl/index"*"Nothing changed."* && $1 != *"type yes to use these loaders"* ]]' _ "$out"
check "...and the chip globals are restored (still ums9230's)" has "$out" "RC=1 S1=0x65000800 ED=0x65015f08 SOC=ums9230"
out=$(printf '%s\n' y 1 y yes | pkg_run 2>&1)
# The confirm needs a TTY, so here it is declined: the pair must still be
# offered (it passed the check), and declining restores the chip globals.
check "the untampered ums512 infinix pair in the same package passes and is offered" \
	bash -c '[[ $1 == *"ums512/infinix/fdl1-dl.bin @ 0x5500"* && $1 == *"exec stub 0x3ee8"* && $1 != *"Refusing"* ]]' _ "$out"
check "...and declining it restores the chip globals" has "$out" "RC=1 S1=0x65000800 ED=0x65015f08 SOC=ums9230"

# Older spdhost (no loaders check): the bash checks stand, nothing breaks.
cat >"$tmp/oldbin" <<'O'
#!/usr/bin/env bash
echo "unknown command" >&2; exit 2
O
chmod +x "$tmp/oldbin"
SPDHOST_BIN=$tmp/oldbin menu_run "$tmp/cboot.conf" need_loaders >/dev/null 2>&1; rc=$?
check "an spdhost without the check (older build): need_loaders falls back to the bash checks (rc 0)" test "$rc" = 0
check "menu.sh calls the check as '--dry-run loaders check' (an old build never opens USB)" \
	grep -q '"\$bin" --dry-run loaders check' "$root/scripts/menu.sh"

echo "== fdl-pack-<sha7>.zip =="
"$root/scripts/fdl-pack.sh" "$tmp/p1" abc1234 >/dev/null 2>"$tmp/fp.err"; rc1=$?
"$root/scripts/fdl-pack.sh" "$tmp/p2" abc1234 >/dev/null 2>&1
check "fdl-pack.sh builds fdl-pack-abc1234.zip + .sha256 (rc 0)" \
	bash -c '[ "$1" = 0 ] && [ -s "$2/fdl-pack-abc1234.zip" ] && (cd "$2" && sha256sum -c fdl-pack-abc1234.zip.sha256 >/dev/null)' _ "$rc1" "$tmp/p1"
check "the pack is deterministic (two builds, one sha256)" cmp -s "$tmp/p1/fdl-pack-abc1234.zip" "$tmp/p2/fdl-pack-abc1234.zip"
mkdir -p "$tmp/unz"
python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$tmp/p1/fdl-pack-abc1234.zip" "$tmp/unz"
check "the unpacked pack verifies against its own index" bash -c '"$1" loaders verify --index "$2/fdl/index" >/dev/null' _ "$bin" "$tmp/unz"
check "the pack holds exactly the fdl/ tree (66 entries incl. index)" \
	bash -c '[ "$(python3 -c "import sys,zipfile; print(len(zipfile.ZipFile(sys.argv[1]).namelist()))" "$1")" = 66 ]' _ "$tmp/p1/fdl-pack-abc1234.zip"
check "a pair from the unpacked pack checks ok against the pack's index" \
	verdict 0 ok --index "$tmp/unz/fdl/index" "$tmp/unz/fdl/ums512/infinix/fdl1-dl.bin" 0x5500 "$tmp/unz/fdl/ums512/infinix/fdl2-dl.bin" 0x9efffe00
cp -r "$F" "$tmp/stale"; printf 'X' >>"$tmp/stale/ums512/infinix/fdl1-dl.bin"
check "gen-fdl-index.sh --check catches a stale index (rc 1)" \
	bash -c '"$1/scripts/gen-fdl-index.sh" --check "$2" >/dev/null 2>&1; [ $? = 1 ]' _ "$root" "$tmp/stale"
check "fdl-pack.sh refuses a stale index" \
	bash -c 'mkdir -p "$2/r/scripts" && cp "$1"/scripts/{fdl-pack.sh,gen-fdl-index.sh} "$2/r/scripts/" && cp -r "$2/stale" "$2/r/fdl" && ! "$2/r/scripts/fdl-pack.sh" "$2/r/out" x >/dev/null 2>&1' _ "$root" "$tmp"
check "cross-both.sh builds the pack and lists it in SHA256SUMS" \
	bash -c 'grep -q "fdl-pack.sh\" \"\$out\" \"\$short\"" "$1/scripts/cross-both.sh" && grep -q "fdl-pack-\"\$short\".zip >SHA256SUMS" "$1/scripts/cross-both.sh"' _ "$root"
check "build.yml publishes fdl-pack-<sha7>.zip and its .sha256" \
	bash -c 'grep -q "\"dist/fdl-pack-\$short.zip\"" "$1/../.github/workflows/build.yml" && grep -q "\"dist/fdl-pack-\$short.zip.sha256\"" "$1/../.github/workflows/build.yml"' _ "$root"

echo "== hard OUT: transport untouched =="
check "usb.c/proto.c know nothing of the loaders check" \
	bash -c '! grep -qi "loaders_check\|spd_loaders" "$1/src/usb.c" "$1/src/proto.c"' _ "$root"

echo
echo "loaders-check: $pass passed, $fail failed"
(( fail == 0 ))
