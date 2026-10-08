#!/usr/bin/env bash
# G2: `write-part-plain NAME FILE` on mock_fdl2. On a non-A/B table with a
# NAME_bak twin, plain `write-part` is spd_dump's load_partition_unify (w_force
# rename + a second copy into NAME_bak). The plain form writes NAME only: no
# REPARTITION frame, NAME_bak untouched, and the same confirm as write-part.
# SPDHOST_STATUS_FILE gets write-NAME=ok|failed per write.
# From no-root/: tests/write-plain-seq.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); [[ -n ${KEEP:-} ]] && echo "tmp=$tmp" || trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
CC=${CC:-gcc}
$CC -O2 -w -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I"$root/tests" \
	"$root/src/main.c" "$root/src/usb.c" "$root/src/usb_list.c" "$root/src/proto.c" "$root/src/dumpcmd.c" \
	"$root/src/writecmd.c" "$root/src/sha256.c" "$root/src/dhtb.c" "$root/src/pac.c" "$root/tests/mock_fdl2.c" -o "$tmp/sh" || exit 1
cp "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin" "$root/fdl/ums9230/infinix/fdl1-dl.bin" \
	"$root/fdl/ums9230/infinix/fdl2-dl.bin" "$tmp/"
cd "$tmp"
LOAD=(fdl fdl1-dl.bin 0x65000800 fdl fdl2-dl.bin 0x9efffe00)
EX=(exec_addr 0x65015f08 custom_exec_no_verify_65015f08.bin)
sh() { local L=$1 o=(); shift; while [[ ${1:-} == --* ]]; do o+=("$1"); shift; done
	MOCK_LOG=sh_$L.seq SPDHOST_STATUS_FILE=$tmp/sh_$L.st timeout 30 ./sh --usb-fd 7 "${o[@]}" \
		"${EX[@]}" "${LOAD[@]}" "$@" 7</dev/null </dev/null >sh_$L.log 2>&1; }
# A typical non-A/B table (KiB rows, divisor 10), MOCK_SLOT empty: not A/B.
printf '%s\n' 'prodnv 5120' 'miscdata 1024' 'misc 1024' 'uboot 1024' 'uboot_bak 1024' 'boot 36864' 'userdata 4194304' > ptn
# Random-looking but fixed: the same frames, escapes and ZLPs on every run.
$CC -O2 -std=c11 "$root/tests/det_bytes.c" -o det_bytes || exit 1
./det_bytes 300000 0x5eed > cboot.bin
export MOCK_PTABLE=$tmp/ptn MOCK_SLOT=

# --yes only here, where the subject is which frames a confirmed write sends.
sh twin --yes parts pt.txt write-part uboot cboot.bin; rc=$?
check "control: write-part uboot on non-A/B takes spd_dump's twin path (2 REPARTITIONs, uboot_bak written, rc $rc)" \
	bash -c "[ $rc = 0 ] && [ $(grep -cE "^SEQ 0b " sh_twin.seq) = 2 ] && grep -q 'write uboot_bak: 300000 bytes' sh_twin.log"
sh plain --yes parts pt.txt write-part-plain uboot cboot.bin; rc=$?
check "write-part-plain uboot: no REPARTITION, no uboot_bak write, uboot written (rc $rc)" \
	bash -c "[ $rc = 0 ] && [ $(grep -cE "^SEQ 0b " sh_plain.seq) = 0 ] && ! grep -q 'write uboot_bak:\|write w_force' sh_plain.log &&
		grep -q 'uboot_bak is left as it is' sh_plain.log && grep -qx 'write-uboot=ok' sh_plain.st"
check "write-part-plain sends one write, to uboot (WRITE_START names uboot, not uboot_bak)" \
	bash -c "[ \$(grep -cE '^SEQ 01 len=(76|80|88) ' sh_plain.seq) = 1 ] && grep -qE '^SEQ 01 len=(76|80|88) 750062006f006f0074000000' sh_plain.seq"
# Same confirm: without --yes or a typed yes, nothing is written.
sh noconf parts pt.txt write-part-plain uboot cboot.bin; rc=$?
check "write-part-plain keeps the typed confirm: no answer, nothing written (rc $rc)" \
	bash -c "[ $rc != 0 ] && [ \$(grep -cE '^SEQ 01 len=(76|80|88) ' sh_noconf.seq) = 0 ] && grep -qx 'write-uboot=started' sh_noconf.st && ! grep -q 'write-uboot=ok' sh_noconf.st"
check "write-part-plain still refuses misc (backup path only)" \
	bash -c "sh() { :; }; cd '$tmp' && MOCK_LOG=m.seq timeout 30 ./sh --usb-fd 7 --yes ${EX[*]} ${LOAD[*]} parts pt.txt write-part-plain misc cboot.bin 7</dev/null </dev/null >m.log 2>&1; [ \$? != 0 ]"
# A data frame that ends on a 512-byte packet boundary is followed by a ZLP
# (usb.c spd_usb_bulk_send). The mock used to read that zero-length transfer as
# a CHECK_BAUD and answer 0x81 over the frame's ACK, so a random cboot.bin whose
# escapes made one frame 64000 bytes failed the write (~7% of runs). This image
# makes the first frame exactly that: 504 0x7e bytes escape to 1008, so
# 1+4+63488+504+2+1 = 64000 = 125*512.
{ head -c 504 /dev/zero | LC_ALL=C tr '\0' '\176'; head -c $((63488 - 504)) /dev/zero; } > zlp.bin
sh zlp --yes parts pt.txt write-part-plain uboot zlp.bin; rc=$?
check "a data frame that fills its last 512-byte packet gets its ZLP and the write still succeeds (rc $rc)" \
	bash -c "[ $rc = 0 ] && grep -B1 -x ZLP sh_zlp.seq | grep -q '^SEQ 02 len=63488 ' &&
		! grep -q 'CHECK_BAUD n=0' sh_zlp.seq && grep -qx 'write-uboot=ok' sh_zlp.st"
# Two writes in one session are reported apart: the second one fails (too big).
head -c 2000000 /dev/zero > big.bin
head -c 262144 /dev/zero > spl.bin
sh two --yes parts pt.txt write-part-plain splloader spl.bin write-part-plain uboot big.bin; rc=$?
check "two writes: write-splloader=ok and write-uboot=failed in the status file (rc $rc)" \
	bash -c "[ $rc != 0 ] && grep -qx 'write-splloader=ok' sh_two.st && grep -qx 'write-uboot=failed' sh_two.st"

echo "write-plain-seq: $pass passed, $fail failed"
(( fail == 0 ))
