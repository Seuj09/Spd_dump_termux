#!/usr/bin/env bash
# P0-3: the --events FD|PATH channel (README "Event channel").
#
# The gate is that events never block or slow the transport. A full mock
# session (BootROM -> FDL1 -> FDL2, parts, misc-backup, read-part,
# write-part-plain, reset on tests/mock_fdl2.c) runs with events off and
# with every kind of reader: a file, a pipe that is read, a pipe nobody
# reads, a pipe whose reader closed, a slow reader and a FIFO with no reader.
# The USB frame trace, the files, the status file, the output and the exit
# status must match events-off exactly, and the timings must stay within
# run-to-run noise. Then the event stream itself: format, order, the
# per-command results, dropped-event accounting, and the status-file mirror.
#
# Usage (from no-root/): tests/events.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
nope() { ! "$@"; }
command -v python3 >/dev/null || { echo "events: SKIP (no python3)"; exit 0; }

CC=${CC:-gcc}
$CC -O2 -w -std=c11 -D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I"$root/tests" \
	"$root/src/main.c" "$root/src/plan.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/events.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
$CC -O2 -Wall -Wextra -std=c11 -DSPD_EV_TEST -I"$root/src" "$root/tests/events_unit.c" "$root/src/events.c" -o "$tmp/eu" || exit 1
make -C "$root" spdhost >"$tmp/make.log" 2>&1 || { tail -20 "$tmp/make.log"; echo "events: build failed"; exit 1; }
bin=$root/spdhost
R=$root/tests/events_reader.py
C=$root/tests/events_check.py
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
printf '%s\n' 'prodnv 5120' 'miscdata 1024' 'misc 1024' 'uboot 1024' 'uboot_bak 1024' 'boot 36864' 'userdata 4194304' > ptn
head -c 600000 /dev/urandom > img.bin
export MOCK_PTABLE=$tmp/ptn MOCK_SLOT=
EX=(exec_addr 0x65015f08 "$tmp/custom_exec_no_verify_65015f08.bin")
LOAD=(fdl "$tmp/fdl1-dl.bin" 0x65000800 fdl "$tmp/fdl2-dl.bin" 0x9efffe00)
# --yes only because the subject here is the transport, not the confirm.
SESSION=(--yes "${EX[@]}" "${LOAD[@]}" parts pt.txt misc-backup mb.img read-part boot 0 0x500000 b.bin
	write-part-plain uboot "$tmp/img.bin" reset)
FILES=(m.seq st o.log mb.img b.bin pt.txt sprdpart.bin)

# run DIR MODE [extra spdhost options...]: one session in DIR.
#   MODE off | file | fifo, or a reader mode (all never closed slow) on fd 9
run() {
	local d=$1 m=$2; shift 2
	rm -rf "$d"; mkdir -p "$d"
	( cd "$d"
	case $m in
	off)  MOCK_LOG=m.seq SPDHOST_STATUS_FILE=$PWD/st timeout 60 python3 "$R" all ev -- ../sh --usb-fd 7 "$@" "${SESSION[@]}" ;;
	file) MOCK_LOG=m.seq SPDHOST_STATUS_FILE=$PWD/st timeout 60 python3 "$R" all ev -- ../sh --usb-fd 7 --events "$PWD/e.jsonl" "$@" "${SESSION[@]}" ;;
	fifo) mkfifo nobody
	      MOCK_LOG=m.seq SPDHOST_STATUS_FILE=$PWD/st timeout 60 python3 "$R" all ev -- ../sh --usb-fd 7 --events "$PWD/nobody" "$@" "${SESSION[@]}" ;;
	*)    MOCK_LOG=m.seq SPDHOST_STATUS_FILE=$PWD/st timeout 60 python3 "$R" "$m" ev -- ../sh --usb-fd 7 --events 9 "$@" "${SESSION[@]}" ;;
	esac 7</dev/null </dev/null >o.log 2>&1
	[[ -f ev.rc ]] || echo "rc=timeout sec=60" > ev.rc )
}
rcof() { sed 's/ sec=.*//' "$1/ev.rc"; }
secof() { sed 's/.* sec=//' "$1/ev.rc"; }
same() { # DIR_A DIR_B: every transport-visible output identical
	local f
	[[ "$(rcof "$1")" == "$(rcof "$2")" ]] || return 1
	for f in "${FILES[@]}"; do cmp -s "$1/$f" "$2/$f" || { echo "  differs: $f" >&2; return 1; }; done
}

echo "== the transport does not notice the reader =="
run off off
check "control: events-off session ends rc=0 with every file" \
	bash -c '[ "$(sed "s/ sec=.*//" off/ev.rc)" = rc=0 ] && for f in "$@"; do [ -s off/$f ] || exit 1; done' _ "${FILES[@]}"
check "events off: no event file, the status file still written" bash -c '[ ! -e off/e.jsonl ] && grep -qx reset=ack off/st'
for m in file all never closed slow; do
	run "$m" "$m"
	check "$m reader: same rc ($(rcof "$m")), USB frame trace, files, status file and output as events off" same off "$m"
done
run fifo fifo
check "FIFO with no reader: one 'events off' note, never waits (rc $(rcof fifo))" \
	bash -c '[ "$(sed "s/ sec=.*//" fifo/ev.rc)" = rc=0 ] && grep -q "^events: .*nobody: .*; events off$" fifo/o.log'
check "FIFO with no reader: otherwise identical to events off" \
	bash -c 'grep -v "^events: " fifo/o.log > fifo/o2.log && cp fifo/o2.log fifo/o.log' && same off fifo
check "closed reader: no SIGPIPE death (rc 0, not -13)" test "$(rcof closed)" = rc=0
check "a never-read pipe drops events: what sat in the pipe is whole lines from start" \
	bash -c 'python3 "$1" account never/ev >never/acct && head -c 40 never/ev | grep -q "\"seq\":1,.*\"ev\":\"start\"" && [ "$(wc -l < never/ev)" -lt "$(wc -l < file/e.jsonl)" ]' _ "$C"
# Whether the end line finds room at exit depends on the reader; when it
# does, account also checks delivered + end.dropped == end.seq.
check "a slow reader: events lost, lines whole, seq gaps == dropped notices (end accounts for all when it gets through)" \
	bash -c 'python3 "$1" account slow/ev >slow/acct && { grep -q "dropped=[1-9]" slow/acct || [ "$(wc -l < slow/ev)" -lt "$(wc -l < file/e.jsonl)" ]; }' _ "$C"
check "a pipe that is read sees exactly what the file got (same events, nothing dropped)" \
	bash -c 'diff <(python3 "$1" summary all/ev) <(python3 "$1" summary file/e.jsonl) >/dev/null && python3 "$1" account all/ev | grep -q "dropped=0 end=yes"' _ "$C"
echo "  never: $(cat never/acct); slow: $(cat slow/acct)"

echo "== the event stream =="
python3 "$C" summary file/e.jsonl > file/sum 2>file/sum.err
check "file: every line a JSON object with the envelope, seq 1..N with no gaps" \
	bash -c 'python3 "$1" account file/e.jsonl | grep -qx "delivered=$(wc -l < file/e.jsonl) dropped=0 end=yes"' _ "$C"
cat > want.sum <<'EOS'
start protocol=1 dirty=unknown sha=unknown
session usb=fd
stage brom
cmd exec_addr start
cmd exec_addr ok
cmd fdl start
hello brom try=1/15 ver ms
progress loader TMP/fdl1-dl.bin 61624/61624
hello loader try=1/10 ver
stage fdl1
cmd fdl ok
cmd fdl start
progress loader TMP/fdl2-dl.bin 1040008/1040008
stage fdl2
cmd fdl ok
cmd parts start
cmd parts ok
cmd misc-backup start
progress read misc 1048576/1048576
status misc-bytes=1048576
cmd misc-backup ok
cmd read-part start
progress read boot 5242880/5242880
cmd read-part ok
cmd write-part-plain start
status write-uboot=started
progress write uboot 600000/600000
status write-uboot=ok
cmd write-part-plain ok
cmd reset start
status reset=ack
cmd reset ok
end rc=0 dropped=0
EOS
sed -i "s#TMP#$tmp#" want.sum
check "file: the events, in order (start, session, stages, cmd start/ok, hello tries, progress, status, end)" \
	bash -c 'diff want.sum file/sum >&2'
check "status events mirror the status file line for line" \
	bash -c 'diff <(sed -n "s/^status //p" file/sum) file/st >&2'
check "progress: bytes rise to the total, at most one per MiB plus the last" \
	python3 -c '
import json,sys
ev=[json.loads(l) for l in open("file/e.jsonl")]
boot=[e["done"] for e in ev if e["ev"]=="progress" and e["name"]=="boot"]
sys.exit(not (boot==sorted(boot) and boot[-1]==5242880 and len(boot)<=6 and all(e["total"]==5242880 for e in ev if e["ev"]=="progress" and e["name"]=="boot")))'
check "the start event carries pid, protocol, build_sha, build_dirty; t is ms from start" \
	python3 -c '
import json,sys
ev=[json.loads(l) for l in open("file/e.jsonl")]
s=ev[0]; sys.exit(not (s["ev"]=="start" and isinstance(s["pid"],int) and s["protocol"]==1 and "build_sha" in s and "build_dirty" in s and all(b["t"]>=a["t"] for a,b in zip(ev,ev[1:]))))'
run app file
run app2 file
cat app/e.jsonl app2/e.jsonl > app2/e2.jsonl
( cd app2 && MOCK_LOG=m2.seq SPDHOST_STATUS_FILE=$PWD/st2 timeout 60 ../sh --usb-fd 7 --events "$tmp/app2/e2.jsonl" "${SESSION[@]}" 7</dev/null </dev/null >/dev/null 2>&1 )
check "PATH is appended to, not truncated (two runs, two start..end streams), mode 0600" \
	bash -c '[ "$(grep -c "\"ev\":\"start\"" app2/e2.jsonl)" = 3 ] && [ "$(grep -c "\"ev\":\"end\"" app2/e2.jsonl)" = 3 ] && [ "$(stat -c %a app/e.jsonl)" = 600 ]'

# A failed command, with and without --keep-going; and a run that exit()s.
kg() { # DIR OPTS...: read-part boot fails at READ_START, then read-part misc
	local d=$1; shift
	rm -rf "$d"; mkdir -p "$d"
	( cd "$d" && MOCK_FAIL_START=boot MOCK_LOG=m.seq SPDHOST_STATUS_FILE=$PWD/st timeout 60 ../sh --usb-fd 7 "$@" \
		"${EX[@]}" "${LOAD[@]}" read-part boot 0 0x1000 b.bin read-part misc 0 0x1000 m.bin 7</dev/null </dev/null >o.log 2>&1; echo $? > rc )
}
kg kg-off --keep-going
kg kg-on --keep-going --events "$tmp/kg-on/e.jsonl"
check "--keep-going: read-part boot failed, read-part misc ok, end rc=1; trace and rc as events off" \
	bash -c 'python3 "$1" summary kg-on/e.jsonl > kg-on/sum && grep -A1 -x "cmd read-part start" kg-on/sum | head -2 | tail -1 | grep -qx "cmd read-part failed" && tail -2 kg-on/sum | head -1 | grep -qx "cmd read-part ok" && tail -1 kg-on/sum | grep -qx "end rc=1 dropped=0" && cmp -s kg-off/m.seq kg-on/m.seq && cmp -s kg-off/rc kg-on/rc' _ "$C"
kg st-off
kg st-on --events "$tmp/st-on/e.jsonl"
check "a failing command ends the run: cmd read-part failed, end rc=1, trace and rc as events off" \
	bash -c 'python3 "$1" summary st-on/e.jsonl > st-on/sum && tail -2 st-on/sum | tr "\n" "|" | grep -qx "cmd read-part failed|end rc=1 dropped=0|" && cmp -s st-off/m.seq st-on/m.seq && cmp -s st-off/rc st-on/rc && [ "$(cat st-on/rc)" = 1 ]' _ "$C"
"$bin" --dry-run --events "$tmp/ex.jsonl" fdl "$tmp/no-such.bin" 0x65000800 >/dev/null 2>&1; rc=$?
check "a run that exit()s mid-command still ends the stream: end rc=-1 (exit $rc)" \
	bash -c '[ "$1" != 0 ] && tail -1 ex.jsonl | grep -q "\"ev\":\"end\",\"rc\":-1,"' _ "$rc"

echo "== non-blocking writes (events.c directly) =="
"$tmp/eu" fill > fill.out 2>fill.err
check "nobody reads a 4096-byte pipe: 200 events never wait (worst $(sed 's/.*=//' fill.err) ms)" \
	bash -c '[ "$(sed "s/.*=//" fill.err)" -le 5 ]'
check "dropped accounting: one dropped notice before the next line that gets through, seq gaps == count, end.dropped == total" \
	bash -c 'python3 "$1" account fill.out | grep -q "end=yes" && grep -q "\"ev\":\"dropped\",\"count\":[1-9]" fill.out && [ "$(grep -c "\"ev\":\"dropped\"" fill.out)" = 1 ] && grep -A1 "\"ev\":\"dropped\"" fill.out | tail -1 | grep -q "after0"' _ "$C"
check "reader closed (EPIPE): no SIGPIPE death, the run goes on" bash -c '"$1" epipe | grep -qx "epipe alive"' _ "$tmp/eu"
check "socket nobody reads: send never waits, the socket's flags are left alone" \
	bash -c 'o=$("$1" sock) && [[ $o == *flags_same=1* ]] && [ "${o#*worst_ms=}" != "${o#*worst_ms=}x" ] && [ "$(echo "$o" | sed "s/.*worst_ms=\([0-9]*\).*/\1/")" -le 5 ]' _ "$tmp/eu"
check "pipe FD: a private non-blocking descriptor; the caller's flags never change; FD_CLOEXEC set" \
	bash -c '[ "$("$1" flags)" = "flags before_nb=0 during_nb=0 after_nb=0 cloexec=1 private=1 private_nb=1 lines=2" ]' _ "$tmp/eu"
check "no private descriptor (fallback): O_NONBLOCK on the shared one while on, put back at the end" \
	bash -c '[ "$("$1" fallback)" = "fallback before_nb=0 during_nb=1 after_nb=0 cloexec=1 private=0 private_nb=1 lines=2" ]' _ "$tmp/eu"
check "no private descriptor and the fd is spdhost's stdout: events off, stdout's flags untouched" \
	bash -c '"$1" stdout 2>&1 >/dev/null | tr "\n" "|" | grep -qx "events: fd [0-9]*: no private descriptor .* is spdhost.s stdout/stderr; events off|stdout off=1 flags_same=1|"' _ "$tmp/eu"
check "O_NONBLOCK cannot be set (forced): events off, never a blocking channel" \
	bash -c '"$1" setfl 2>&1 | tr "\n" "|" | grep -qx "events: fd [0-9]*: cannot make writes non-blocking; events off|setfl off=1 flags_same=1|"' _ "$tmp/eu"
"$tmp/eu" long > long.out
check "an over-long event becomes a well-formed truncated marker; strings are JSON-escaped" \
	bash -c 'python3 "$1" schema long.out && grep -q "\"ev\":\"status\",\"truncated\":true}" long.out && python3 -c "import json,sys; e=[json.loads(l) for l in open(\"long.out\")]; sys.exit(e[2][\"key\"]!=\"a\\\"b\\\\c\\n\\x01\")"' _ "$C"

"$tmp/eu" utf8 > utf8.out
check "UTF-8: every line strict UTF-8 JSON; non-ASCII kept, invalid bytes become U+FFFD" \
	python3 -c '
import json,sys
e=[json.loads(l.decode("utf-8","strict")) for l in open("utf8.out","rb")]
v={x.get("key"):x.get("value") for x in e if x["ev"]=="status"}
sys.exit(not (v["ok"]=="/sdcard/\u00e9t\u00e9/\u4e2d\U0001f600.bin" and v["bad"]=="x\ufffd\ufffdy"+"\ufffd"*8))'
check "a cut string ends on a character boundary with a \u2026 mark (q[96] mid-character, long non-ASCII loader path)" \
	python3 -c '
import json,sys
e=[json.loads(l.decode("utf-8","strict")) for l in open("utf8.out","rb")]
v={x.get("key"):x.get("value") for x in e if x["ev"]=="status"}
p=[x["name"] for x in e if x["ev"]=="progress"][0]
sys.exit(not (v["cut96"]=="a"*86+"\u2026" and p.startswith("/sdcard/\u4e2d") and p.endswith("\u4e2d\u2026") and v["fit"]=="abcdefghijklm" and v["fit1"]=="abcdefg\u2026"))'
nd="$tmp/$(printf 'r\xc3\xa9p\xff')"; mkdir -p "$nd"; cp fdl1-dl.bin "$nd/fdl1-$(printf '\xe4\xb8\xad').bin"
"$bin" --events "$tmp/u8.jsonl" --dry-run "${EX[@]}" fdl "$nd/fdl1-$(printf '\xe4\xb8\xad').bin" 0x65000800 >/dev/null 2>&1
check "spdhost: a non-ASCII / invalid-byte FDL path gives a strict-UTF-8 progress event" \
	python3 -c '
import json,sys
e=[json.loads(l.decode("utf-8","strict")) for l in open("u8.jsonl","rb")]
p=[x["name"] for x in e if x["ev"]=="progress"]
sys.exit(not (len(p)==1 and "r\u00e9p\ufffd/fdl1-\u4e2d.bin" in p[0]))'

echo "== timing: a slow or absent reader leaves hello and transfer timing alone =="
# BootROM ignores 4 hellos; each timeout takes its real time (MOCK_SLEEP_TIMEOUT).
export_hello() { MOCK_HELLO_MISS=4 MOCK_SLEEP_TIMEOUT=1 SPDHOST_BROM_TIMEOUT_MIN=40 SPDHOST_BROM_TIMEOUT=80 \
	SPDHOST_BROM_TIMEOUT_RAMP=3 SPDHOST_BROM_PAUSE_MS=20 SPDHOST_BROM_TRACE=1 "$@"; }
hello_ms() { # MODE N: N runs, print the median @ms of the try that got VER
	local m=$1 n=$2 k ev
	for ((k = 0; k < n; k++)); do
		rm -rf h; mkdir h
		if [[ $m == off ]]; then ev=(); else ev=(--events 9); fi
		( cd h && export_hello env MOCK_LOG=m.seq timeout 60 python3 "$R" "${m/off/all}" ev -- ../sh --usb-fd 7 "${ev[@]}" "${EX[@]}" "${LOAD[@]}" 7</dev/null </dev/null >o.log 2>&1 )
		sed -n 's/^brom: try 5 of 15 recv n=.* @\([0-9]*\)ms$/\1/p' h/o.log
		[[ $m == all ]] && cp h/ev hello-all.ev
		cp h/m.seq "hello-$m.seq"
	done | sort -n | awk '{a[NR]=$1} END{print (NR ? a[int((NR+1)/2)] : -1)}'
}
h_off=$(hello_ms off 5); h_never=$(hello_ms never 5); h_slow=$(hello_ms slow 5); h_all=$(hello_ms all 3)
echo "  hello VER at try 5, median ms: off=$h_off never=$h_never slow=$h_slow read=$h_all"
check "hello: 4 timed-out tries then VER, off and on (median $h_off ms)" bash -c '[ "$1" -gt 100 ]' _ "$h_off"
for m in never slow all; do
	v=h_$m
	check "hello timing with a $m reader within noise of events off (|${!v} - $h_off| <= 25 ms)" \
		bash -c 'd=$(($1 - $2)); [ ${d#-} -le 25 ]' _ "${!v}" "$h_off"
	check "hello frame trace with a $m reader identical to events off" cmp -s hello-off.seq "hello-$m.seq"
done
check "hello events: tries 1-4 timeout, try 5 ver, each with ms" \
	bash -c 'python3 "$1" summary hello-all.ev | grep "^hello brom" | tr "\n" "|" | grep -qx "hello brom try=1/15 timeout ms|hello brom try=2/15 timeout ms|hello brom try=3/15 timeout ms|hello brom try=4/15 timeout ms|hello brom try=5/15 ver ms|"' _ "$C"
med_sec() { # MODE: median wall seconds of 5 full sessions
	local m=$1 k
	for k in 1 2 3 4 5; do run "t-$m" "$m" >/dev/null; secof "t-$m"; done | sort -n | sed -n 3p
}
s_off=$(med_sec off); s_file=$(med_sec file); s_never=$(med_sec never); s_slow=$(med_sec slow)
echo "  full session median s: off=$s_off file=$s_file never=$s_never slow=$s_slow"
for m in file never slow; do
	v=s_$m
	check "full session with a $m reader within noise of events off (${!v} <= 1.5 x $s_off + 0.15 s)" \
		python3 -c 'import sys; sys.exit(not float(sys.argv[1]) <= 1.5*float(sys.argv[2]) + 0.15)' "${!v}" "$s_off"
done

echo "== dry-run, caps, offline commands, bad arguments =="
dry=(--dry-run "${EX[@]}" "${LOAD[@]}")
"$bin" "${dry[@]}" >dry-off.out 2>/dev/null
"$bin" --events "$tmp/dry.jsonl" "${dry[@]}" >dry-on.out 2>/dev/null
check "--dry-run: DRY frames on stdout identical with events on" cmp -s dry-off.out dry-on.out
check "--dry-run: the session event says usb=dry" grep -q '"ev":"session","usb":"dry"' dry.jsonl
python3 "$R" never dry-never.ev -- "$bin" --events 9 "${dry[@]}" >dry-never.out 2>/dev/null
check "--dry-run with a never-read pipe: DRY frames identical" cmp -s dry-off.out dry-never.out
# MED-1: the events fd a dup of spdhost's own stdout (3>&1), stdout read
# late: stdout must still get every DRY line (it blocks as it always did);
# only events may be dropped. 2>&1 the same for stderr.
"$bin" "${dry[@]}" >dry-ref.out 2>dry-ref.err
"$bin" --events 3 "${dry[@]}" 3>&1 2>/dev/null | (sleep 2; cat) > dry-dup1.out
check "--events 3 3>&1 with a late stdout reader: DRY output byte-identical once event lines are taken out ($(grep -c '^DRY' dry-dup1.out)/$(grep -c '^DRY' dry-ref.out) DRY lines)" \
	python3 -c '
import re,sys,json
a=open("dry-dup1.out","rb").read()
ev=re.findall(rb"\{\"v\":1,[^\n]*\n",a)
rest=re.sub(rb"\{\"v\":1,[^\n]*\n",b"",a)
[json.loads(l) for l in ev]
sys.exit(not (rest==open("dry-ref.out","rb").read() and len(ev)>=1))'
"$bin" --events 3 "${dry[@]}" 2>&1 >/dev/null 3>&2 | (sleep 2; cat) > dry-dup2.out
check "--events 3 3>&2 with a late stderr reader: stderr byte-identical once event lines are taken out" \
	python3 -c '
import re,sys
a=open("dry-dup2.out","rb").read()
sys.exit(not re.sub(rb"\{\"v\":1,[^\n]*\n",b"",a)==open("dry-ref.err","rb").read())'
dup() { # NAME [--events 3]: a mock session, stdout to a late reader, fd 3 = stdout
	local n=$1; shift
	( MOCK_LOG=$n.seq SPDHOST_STATUS_FILE=$PWD/$n.st timeout 60 ./sh --usb-fd 7 "$@" "${SESSION[@]}" \
		7</dev/null </dev/null 3>&1 2>"$n.err" | (sleep 1; cat) > "$n.out"; echo "${PIPESTATUS[0]}" > "$n.rc" )
}
rm -f dupoff.* dupon.*
dup dupoff; dup dupon --events 3
check "mock session with --events 3 3>&1: rc, USB frame trace, status file, stderr and stdout (less event lines) as events off" \
	bash -c '[ "$(cat dupon.rc)" = 0 ] && cmp -s dupoff.rc dupon.rc && cmp -s dupoff.seq dupon.seq && cmp -s dupoff.st dupon.st && cmp -s dupoff.err dupon.err && grep -q "\"ev\":\"start\"" dupon.out && diff <(grep -v "^{\"v\":1," dupon.out) dupoff.out >/dev/null'
# LOW-5: the events fd may not be the USB fd.
for a in "--usb-fd 7 --events 7" "--usb-fd 7 --events 8"; do
	"$bin" $a --dry-run ping 7</dev/null 8<&7 >/dev/null 2>e.err; rc=$?
	check "'$a' (8 a dup of 7) refused: exit 2, bad --events: is the USB fd" bash -c '[ "$1" = 2 ] && grep -q "^bad --events: [0-9]* is the USB fd" "$2"' _ "$rc" e.err
done
TERMUX_USB_FD=7 "$bin" --events 7 --dry-run ping 7</dev/null >/dev/null 2>e.err; rc=$?
check "TERMUX_USB_FD=7 --events 7 refused (exit 2)" bash -c '[ "$1" = 2 ] && grep -q "^bad --events: 7 is the USB fd" "$2"' _ "$rc" e.err
"$bin" caps > caps.out
check "caps lists cap=events" grep -qx cap=events caps.out
"$bin" --events "$tmp/caps.jsonl" caps >/dev/null 2>&1
"$bin" --events "$tmp/caps.jsonl" pack-slot >/dev/null 2>&1
"$bin" --events "$tmp/caps.jsonl" --self-test >/dev/null 2>&1
"$bin" --events "$tmp/caps.jsonl" unpac >/dev/null 2>&1
check "caps, --self-test and offline tools never open the events PATH" test ! -e caps.jsonl
for a in 1 2 77 '' 1234567890; do
	"$bin" --events "$a" caps >/dev/null 2>e.err; rc=$?
	check "--events '$a' refused (exit 2, bad --events)" bash -c '[ "$1" = 2 ] && grep -q "^bad --events" "$2"' _ "$rc" e.err
done
check "--help documents --events" bash -c '"$1" --help 2>&1 | grep -q "^  --events FD|PATH"' _ "$bin"
check "no environment knob for events (plan wiring is --events only)" \
	nope grep -nE 'getenv\("SPDHOST_EVENTS' "$root/src/main.c" "$root/src/plan.c" "$root/src/events.c" "$root/src/proto.c"
check "SPDHOST_STATUS_FILE code path untouched (fopen append, key=value)" \
	bash -c 'grep -q "fprintf(f, \"%s=%s\\\\n\", key, val);" "$1/src/main.c" && grep -q "fopen(p, \"a\")" "$1/src/main.c"' _ "$root"

echo
echo "events: $pass passed, $fail failed"
(( fail == 0 ))
