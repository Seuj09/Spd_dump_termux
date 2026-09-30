#!/usr/bin/env bash
# Test menu: dump one partition, or reboot into a mode.
# Default loaders: ums9230 Infinix fdl1-dl.bin and fdl2-dl.bin.
set -u

CONFIG="${SPDHOST_MENU_CONFIG:-$HOME/.spdhost-menu.conf}"
DUMP_DIR="${SPDHOST_DUMP_DIR:-$PWD/backup}"
FDL1_ADDR_DEFAULT=0x65000800
FDL2_ADDR_DEFAULT=0x9efffe00

# Prefer PATH, then this package's scripts/ (works from no-root/ or scripts/).
# Always run the wrapper by absolute path so spdhost-usb can resolve ../spdhost via $0.
script_dir=$(cd "$(dirname "$0")" && pwd)
RUNNER=()
if command -v spdhost-usb >/dev/null 2>&1; then
	RUNNER=("$(command -v spdhost-usb)")
else
	for cand in \
		"$script_dir/spdhost-usb" \
		"$PWD/scripts/spdhost-usb" \
		"$PWD/spdhost-usb"
	do
		if [[ -x $cand && -f $cand ]]; then
			RUNNER=("$(cd "$(dirname "$cand")" && printf '%s/%s' "$(pwd)" "$(basename "$cand")")")
			break
		fi
	done
fi
if (( ${#RUNNER[@]} == 0 )); then
	echo "spdhost-usb not found next to this tree or on PATH." >&2
	echo "From no-root/: bash scripts/menu.sh   (optional: cp scripts/spdhost-usb \"\$PREFIX/bin/\")" >&2
	exit 1
fi

FDL1=""
FDL1_ADDR=""
FDL2=""
FDL2_ADDR=""

pause() {
	read -r -p "Press Enter to continue..." _
}

cls() {
	printf '\033[2J\033[H'
}

save_config() {
	umask 077
	cat > "$CONFIG" << EOF
FDL1=$FDL1
FDL1_ADDR=$FDL1_ADDR
FDL2=$FDL2
FDL2_ADDR=$FDL2_ADDR
EOF
}

load_config() {
	local key val
	[[ -f $CONFIG ]] || return 0
	while IFS='=' read -r key val; do
		case $key in
			FDL1|FDL2)
				[[ -n $val && -f $val ]] && printf -v "$key" '%s' "$val"
				;;
			FDL1_ADDR|FDL2_ADDR)
				[[ $val =~ ^0[xX][0-9a-fA-F]+$ ]] && printf -v "$key" '%s' "$val"
				;;
		esac
	done < "$CONFIG"
}

# Release layout is ums9230/infinix/{fdl1-dl.bin,fdl2-dl.bin}.
# This repo keeps that pair under no-root/fdl/ums9230/infinix/.
find_infinix_dir() {
	local script_dir here d
	script_dir=$(cd "$(dirname "$0")" && pwd)
	here=$(pwd)
	for d in \
		"$script_dir/../fdl/ums9230/infinix" \
		"$here/fdl/ums9230/infinix" \
		"$here/ums9230/infinix" \
		"$HOME/spdhost/fdl/ums9230/infinix" \
		"$HOME/Spd_dump_termux/no-root/fdl/ums9230/infinix" \
		"$HOME/spreadtrum_flash_termux/ums9230/infinix"
	do
		if [[ -f $d/fdl1-dl.bin && -f $d/fdl2-dl.bin ]]; then
			(cd "$d" && pwd)
			return 0
		fi
	done
	return 1
}

# Shipped BCB images under no-root/misc/ (phone data, not host ISA / not FDL).
find_misc_dir() {
	local script_dir here d
	script_dir=$(cd "$(dirname "$0")" && pwd)
	here=$(pwd)
	for d in \
		"$script_dir/../misc" \
		"$here/misc" \
		"$HOME/spdhost/misc" \
		"$HOME/Spd_dump_termux/no-root/misc" \
		"$HOME/spreadtrum_flash_termux"
	do
		if [[ -f $d/misc-fastbootd.bin && -f $d/misc-wipe.bin ]]; then
			(cd "$d" && pwd)
			return 0
		fi
	done
	return 1
}

MISC_DIR=""
resolve_misc_dir() {
	if [[ -n ${MISC_DIR:-} && -d $MISC_DIR ]]; then
		return 0
	fi
	MISC_DIR=$(find_misc_dir) || {
		echo "misc BCB directory not found (need misc-fastbootd.bin + misc-wipe.bin)." >&2
		return 1
	}
}

# Offer the shipped Infinix UMS9230 pair only after an explicit chip/model
# confirm, or when SPDHOST_ALLOW_DEFAULT_FDL=1. Never apply silently.
apply_ums9230_infinix_defaults() {
	local dir reply
	# Config (or a prior confirm) already complete — leave it alone.
	if [[ -n ${FDL1:-} && -f $FDL1 && -n ${FDL1_ADDR:-} && -n ${FDL2:-} && -f $FDL2 && -n ${FDL2_ADDR:-} ]]; then
		return 0
	fi
	dir=$(find_infinix_dir) || return 0
	if [[ ${SPDHOST_ALLOW_DEFAULT_FDL:-} == 1 ]]; then
		echo "Using shipped ums9230 Infinix FDL defaults (SPDHOST_ALLOW_DEFAULT_FDL=1)" >&2
	else
		if [[ ! -t 0 ]]; then
			echo "refusing shipped Infinix ums9230 FDL defaults without a TTY;" >&2
			echo "set SPDHOST_ALLOW_DEFAULT_FDL=1 or run option 3 to choose loaders." >&2
			return 0
		fi
		echo "Found shipped FDL pair for Infinix UMS9230:"
		echo "  $dir/fdl1-dl.bin @ $FDL1_ADDR_DEFAULT"
		echo "  $dir/fdl2-dl.bin @ $FDL2_ADDR_DEFAULT"
		echo "A wrong chip or address can brick the phone."
		read -r -p "type yes if this target is Infinix UMS9230: " reply
		if [[ $reply != yes ]]; then
			echo "Defaults not applied. Use option 3 to set loaders for your chip."
			return 0
		fi
	fi
	[[ -n $FDL1_ADDR ]] || FDL1_ADDR=$FDL1_ADDR_DEFAULT
	[[ -n $FDL2_ADDR ]] || FDL2_ADDR=$FDL2_ADDR_DEFAULT
	[[ -n $FDL1 ]] || FDL1=$dir/fdl1-dl.bin
	[[ -n $FDL2 ]] || FDL2=$dir/fdl2-dl.bin
}

ask_addr() {
	local prompt=$1 reply
	while true; do
		read -r -p "$prompt " reply
		if [[ $reply =~ ^0[xX][0-9a-fA-F]+$ ]]; then
			printf '%s\n' "$reply"
			return 0
		fi
		echo "Address must look like 0x65000800" >&2
	done
}

ask_file() {
	local prompt=$1 reply
	while true; do
		read -r -e -p "$prompt " reply
		if [[ -f $reply ]]; then
			printf '%s\n' "$reply"
			return 0
		fi
		echo "No such file: $reply" >&2
	done
}

configure_loaders() {
	echo "Loader files and load addresses for this chip."
	echo "These are the same FDL1/FDL2 pair the rooted menu uses. A wrong address can brick the phone."
	FDL1=$(ask_file "FDL1 file:")
	FDL1_ADDR=$(ask_addr "FDL1 address:")
	FDL2=$(ask_file "FDL2 file:")
	FDL2_ADDR=$(ask_addr "FDL2 address:")
	save_config
	echo "Saved $CONFIG"
}

need_loaders() {
	if [[ -f $FDL1 && -n $FDL1_ADDR && -f $FDL2 && -n $FDL2_ADDR ]]; then
		return 0
	fi
	echo "Set the loader files first."
	configure_loaders
}

ready() {
	echo
	echo "Power the target off. Leave it unplugged. This phone is the USB host (OTG)."
	echo "Press Enter. The next step waits 90 seconds."
	echo "Only after it says 'Plug the target in NOW', hold volume down and connect the cable."
	echo "Tap OK on the permission dialog as soon as it appears."
	echo "The first try often misses the BootROM window. Unplug, run the same action, and plug in again."
	echo "Cold-unplug ≥5 s between sessions. Success once does not make later tries stickier without a replug."
	pause
}

run_session() {
	local -a prefix=(--timeout "${SPDHOST_TIMEOUT:-3000}")
	if [[ ${SPDHOST_VERBOSE:-} == 1 ]]; then
		prefix+=(--verbose)
	fi
	echo "+ ${RUNNER[*]} ${prefix[*]} $*"
	"${RUNNER[@]}" "${prefix[@]}" "$@"
	local rc=$?
	echo "exit $rc"
	return "$rc"
}

# Cached live partition table from the last `parts` run (name + size units).
# Same fields the rooted menu shows as LIST PARTISI, but sizes come from the
# device table (spdhost `parts` / FILE form), not a hardcoded string.
parts_cache_path() {
	mkdir -p "$DUMP_DIR"
	printf '%s\n' "$DUMP_DIR/partition_list.txt"
}

fmt_size() {
	local n=$1
	if [[ ! $n =~ ^[0-9]+$ ]]; then
		printf '%s' "$n"
		return
	fi
	if (( n >= 1073741824 && n % 1073741824 == 0 )); then
		printf '%uG' $((n / 1073741824))
	elif (( n >= 1048576 && n % 1048576 == 0 )); then
		printf '%uM' $((n / 1048576))
	elif (( n >= 1024 && n % 1024 == 0 )); then
		printf '%uK' $((n / 1024))
	else
		printf '%u' "$n"
	fi
}

normalize_part_query() {
	local q=$1
	q=${q##*/}
	q=${q%.img}
	q=${q%.IMG}
	q=${q%.bin}
	q=${q%.BIN}
	q=${q%.raw}
	q=${q%.RAW}
	# bash ${q,,} needs bash 4+; Termux has it
	printf '%s' "${q,,}"
}

# Score how well device partition NAME matches QUERY (already normalized).
# Higher is better. Exact and slot-suffixed matches beat fuzzy contains.
score_part_match() {
	local name=$1 query=$2
	local nl=${#name} ql=${#query}
	local nlow=${name,,}
	[[ -z $query || -z $nlow ]] && { printf '0'; return; }
	if [[ $nlow == "$query" ]]; then
		printf '1000'
		return
	fi
	if [[ $nlow == "${query}_a" ]]; then
		printf '950'
		return
	fi
	if [[ $nlow == "${query}_b" ]]; then
		printf '900'
		return
	fi
	if [[ $nlow == "$query"* ]]; then
		# Prefer shorter names (boot_a over boot_ab_something)
		printf '%d' $((800 - (nl - ql)))
		return
	fi
	if [[ $nlow == *"$query"* ]]; then
		printf '%d' $((500 - (nl - ql)))
		return
	fi
	# Shared prefix length (bootimg vs boot_a still gets a nudge via strip above)
	local i=0
	while (( i < ql && i < nl )) && [[ ${nlow:i:1} == "${query:i:1}" ]]; do
		((i++)) || true
	done
	if (( i >= 3 )); then
		printf '%d' $((200 + i * 10 - (nl - i)))
		return
	fi
	printf '0'
}

# Print "name size" for the best match against PARTS_FILE, or fail.
# Prefer _a over _b when scores tie (active-slot guess without reading misc).
resolve_part_query() {
	local query_raw=$1 parts_file=$2
	local query name size best_name="" best_size="" best_score=0 score
	query=$(normalize_part_query "$query_raw")
	if [[ -z $query || $query == */* || $query == *' '* ]]; then
		echo "Name must be one word, like boot, boot.img, or boot_a." >&2
		return 1
	fi
	if [[ ! -f $parts_file ]]; then
		echo "No partition list at $parts_file" >&2
		return 1
	fi
	while read -r name size _; do
		[[ -z ${name:-} || -z ${size:-} ]] && continue
		[[ $size =~ ^[0-9]+$ ]] || continue
		(( size > 0 )) || continue
		score=$(score_part_match "$name" "$query")
		(( score <= 0 )) && continue
		if (( score > best_score )); then
			best_score=$score
			best_name=$name
			best_size=$size
		elif (( score == best_score && best_score > 0 )); then
			# Tie-break: prefer *_a over *_b over bare
			if [[ ${name,,} == *_a && ${best_name,,} != *_a ]]; then
				best_name=$name
				best_size=$size
			fi
		fi
	done < "$parts_file"
	if [[ -z $best_name ]]; then
		echo "No partition close to '$query_raw' in $parts_file" >&2
		return 1
	fi
	printf '%s %s\n' "$best_name" "$best_size"
}

show_parts_list() {
	local parts_file=$1 name size
	echo "PARTITION LIST (from device parts table):"
	printf '%-28s %12s %14s\n' "NAME" "SIZE" "BYTES"
	echo "------------------------------------------------------------"
	while read -r name size _; do
		[[ -z ${name:-} || -z ${size:-} ]] && continue
		printf '%-28s %12s %14s\n' "$name" "$(fmt_size "$size")" "$size"
	done < "$parts_file"
	echo
	echo "Type a name (boot, boot.img, boot_a), or:"
	echo "  all       — every partition except userdata, cache, blackbox"
	echo "  all_lite  — same, and skip inactive slot (_b when _a exists)"
}

fetch_parts_table() {
	local parts_file
	parts_file=$(parts_cache_path)
	echo "Fetching live partition table into $parts_file"
	ready
	if ! run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$parts_file"; then
		echo "parts failed (exit $?)." >&2
		return 1
	fi
	if [[ ! -s $parts_file ]]; then
		echo "parts wrote an empty list." >&2
		return 1
	fi
	return 0
}

should_skip_bulk() {
	local name=$1 mode=$2
	local nlow=${name,,}
	case $nlow in
		userdata|cache|blackbox) return 0 ;;
	esac
	if [[ $mode == all_lite && $nlow == *_b ]]; then
		# Skip _b when a matching _a exists in the same list.
		local base=${name%_b}
		base=${base%_B}
		if grep -qiE "^${base}_a[[:space:]]" "$(parts_cache_path)" 2>/dev/null; then
			return 0
		fi
	fi
	return 1
}

dump_matched_parts() {
	local mode=$1 parts_file=$2
	local name size out args=() n=0
	mkdir -p "$DUMP_DIR"
	while read -r name size _; do
		[[ -z ${name:-} || -z ${size:-} ]] && continue
		[[ $size =~ ^[0-9]+$ ]] || continue
		(( size > 0 )) || continue
		if should_skip_bulk "$name" "$mode"; then
			echo "skip $name"
			continue
		fi
		out="$DUMP_DIR/${name}.img"
		echo "queue $name size=$(fmt_size "$size") ($size) -> $out"
		args+=(read-part "$name" 0 "$size" "$out")
		((n++)) || true
	done < "$parts_file"
	if (( n == 0 )); then
		echo "Nothing to dump."
		return 1
	fi
	echo "Will dump $n partition(s) in one session."
	ready
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		"${args[@]}" || true
}

dump_partition() {
	local parts_file reply query matched name size out
	need_loaders || return
	cls
	echo "Dump partition(s)"
	echo "Lists the live device table (like rooted menu LIST PARTISI),"
	echo "then matches what you type (boot.img -> boot_a) and uses that size."
	parts_file=$(parts_cache_path)
	if [[ -s $parts_file ]]; then
		echo "Cached list: $parts_file"
		read -r -p "Refresh from device? [y/N]: " reply
		if [[ ${reply,,} == y || ${reply,,} == yes ]]; then
			fetch_parts_table || { pause; return; }
		fi
	else
		fetch_parts_table || { pause; return; }
	fi
	if [[ ! -s $parts_file ]]; then
		echo "No partition list."
		pause
		return
	fi
	cls
	show_parts_list "$parts_file"
	read -r -p "Partition name (or all / all_lite): " query
	if [[ -z ${query:-} ]]; then
		echo "Cancelled."
		pause
		return
	fi
	case ${query,,} in
		all|all_lite)
			dump_matched_parts "${query,,}" "$parts_file"
			pause
			return
			;;
	esac
	matched=$(resolve_part_query "$query" "$parts_file") || {
		pause
		return
	}
	read -r name size <<<"$matched"
	out="$DUMP_DIR/${name}.img"
	echo
	echo "Matched '$query' -> $name  size=$(fmt_size "$size") ($size bytes/units)"
	read -r -e -p "Output file [$out]: " reply
	[[ -n ${reply:-} ]] && out=$reply
	echo "Will read $name at offset 0, size $size, into $out"
	ready
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		read-part "$name" 0 "$size" "$out" || true
	pause
}

list_partitions_menu() {
	need_loaders || return
	cls
	echo "List partitions (live parts table)"
	fetch_parts_table || { pause; return; }
	cls
	show_parts_list "$(parts_cache_path)"
	pause
}

# Fallback/doc: synthesize a 2048-byte misc BCB with dd (menu reboot [2]/[3]
# prefer spdhost reboot-recovery / reboot-fastboot). Kept for inspection.
# recovery:  "boot-recovery"
# fastbootd: "boot-recovery" and, at offset 0x40, "recovery\n--fastboot\n"
write_misc_command() {
	local kind=$1 dest
	dest=$(mktemp "${TMPDIR:-/tmp}/spdhost-misc.XXXXXX")
	dd if=/dev/zero of="$dest" bs=2048 count=1 status=none
	printf 'boot-recovery' | dd of="$dest" conv=notrunc status=none
	if [[ $kind == fastboot ]]; then
		printf 'recovery\n--fastboot\n' | dd of="$dest" bs=1 seek=64 conv=notrunc status=none
	fi
	printf '%s\n' "$dest"
}

# Brick-adjacent: never pass --yes for misc/reboot/wipe. Require a TTY + typed confirm.
confirm_misc_write() {
	local kind=$1 misc=$2 digest reply
	if [[ ! -t 0 ]]; then
		echo "refusing to write misc without a TTY (no silent --yes)" >&2
		return 1
	fi
	digest=$(sha256sum "$misc" | awk '{print $1}')
	echo "About to write 2048 bytes to partition 'misc' ($kind), then reset."
	echo "misc image sha256: $digest"
	echo "Wrong chip/FDL or a mis-click can soft-brick the boot path."
	read -r -p "type yes to write misc: " reply
	if [[ $reply != yes ]]; then
		echo "not confirmed"
		return 1
	fi
	return 0
}

# Louder prompt for wipe BCB (recovery --wipe_data). Does NOT erase persist/userdata partitions.
confirm_wipe_userdata() {
	local misc=$1 digest reply
	if [[ ! -t 0 ]]; then
		echo "refusing wipe-userdata without a TTY (no silent --yes)" >&2
		return 1
	fi
	digest=$(sha256sum "$misc" | awk '{print $1}')
	echo "WARNING: This writes a recovery --wipe_data BCB to misc (2048 bytes), then reset."
	echo "Recovery will ERASE USERDATA on the next boot. It does not erase persist here."
	echo "misc-wipe.bin sha256: $digest"
	echo "Wrong chip/FDL or a mis-click can soft-brick the boot path and destroy user data."
	read -r -p "type yes to erase userdata via recovery: " reply
	if [[ $reply != yes ]]; then
		echo "not confirmed"
		return 1
	fi
	return 0
}

# Typed confirm for in-process reboot-* (spdhost will also prompt; never --yes).
confirm_reboot_cmd() {
	local kind=$1 reply
	if [[ ! -t 0 ]]; then
		echo "refusing $kind without a TTY (no silent --yes)" >&2
		return 1
	fi
	echo "About to run $kind: write exactly 2048 bytes to misc, then reset."
	echo "Wrong chip/FDL or a mis-click can soft-brick the boot path."
	read -r -p "type yes to continue: " reply
	if [[ $reply != yes ]]; then
		echo "not confirmed"
		return 1
	fi
	return 0
}

# Absolute path to the spdhost binary, mirroring scripts/spdhost-usb's own
# resolver, so --self-test runs the same build the wrapper would actually
# launch (not a stale PATH copy from an older install).
resolve_spdhost_bin() {
	local script_dir cand
	script_dir=$(cd "$(dirname "$0")" && pwd)
	for cand in \
		"$script_dir/../spdhost" \
		"$PWD/spdhost" \
		"$PWD/../spdhost" \
		"$(type -P spdhost 2>/dev/null || true)"
	do
		[[ -n $cand && -x $cand && -f $cand ]] || continue
		(cd "$(dirname "$cand")" && printf '%s/%s\n' "$(pwd)" "$(basename "$cand")")
		return 0
	done
	return 1
}

# Safe, read-only self-check: build sanity, environment, this release's
# BootROM-hello behaviour, and — only if a device already answers
# `termux-usb -l` — a short, bounded, non-destructive check-baud probe.
# Never sends fdl/write-part/reboot-*/erase-part. Pass/fail summary at the end.
smoke_test() {
	local ok=1 spdhost_bin arch out rc

	cls
	echo "spdhost smoke test"
	echo "Read-only: no fdl, no partition writes, no reboot. Safe to run any time."
	echo

	echo "== Build =="
	spdhost_bin=$(resolve_spdhost_bin) || spdhost_bin=""
	if [[ -z $spdhost_bin ]]; then
		echo "FAIL  spdhost binary not found next to this tree or on PATH"
		echo "      From no-root/: make"
		ok=0
	else
		echo "spdhost binary: $spdhost_bin"
		arch=$(uname -m)
		echo "device arch: $arch"
		if command -v file >/dev/null 2>&1; then
			echo "binary reports: $(file -b "$spdhost_bin" 2>/dev/null)"
		fi
		if out=$("$spdhost_bin" --self-test 2>&1); then
			echo "PASS  $out"
		else
			echo "FAIL  self-test: $out"
			ok=0
		fi
	fi
	echo

	echo "== This release's BootROM-hello behaviour =="
	echo "  Per-try timeout ramps 250ms -> 3000ms over 6 tries, then holds at 3000ms"
	echo "  (SPDHOST_BROM_NO_RAMP=1 for the old flat-3000ms-every-try behaviour)."
	echo "  Wall is auto-computed to fit all SPDHOST_BROM_TRIES (default 15) unless"
	echo "  SPDHOST_BROM_WALL_MS is set explicitly."
	echo "  clear_halt on bulk IN+OUT now runs after line-state, on the BootROM-hello"
	echo "  path only (SPDHOST_NO_CLEAR_HALT=1 to disable)."
	echo "  Ctrl-C during a hello, read-part, write-part or erase-part now stops"
	echo "  cleanly and releases the USB interface for the next run, instead of"
	echo "  leaving it claimed until a replug."
	echo

	echo "== Environment =="
	if command -v termux-usb >/dev/null 2>&1; then
		echo "PASS  termux-usb found"
	else
		echo "FAIL  termux-usb not found — install Termux:API (F-Droid, same source"
		echo "      as Termux) then: pkg install termux-api"
		ok=0
	fi
	if command -v termux-toast >/dev/null 2>&1 && command -v termux-vibrate >/dev/null 2>&1; then
		echo "PASS  termux-toast + termux-vibrate found (device-found/done/error"
		echo "      notifications on by default; SPD_USB_NOTIFY=0 to disable)"
	else
		echo "note  termux-toast/termux-vibrate not found — notifications silently"
		echo "      skipped, everything else still works"
	fi
	echo

	echo "== Live device probe (read-only) =="
	local devs=""
	if command -v termux-usb >/dev/null 2>&1; then
		devs=$( (command -v timeout >/dev/null 2>&1 && timeout 5 termux-usb -l || termux-usb -l) 2>/dev/null | tr -d '[]",' | awk '/\/dev\/bus\/usb\// {print $1}')
	fi
	if [[ -z $devs ]]; then
		echo "No USB device currently listed by termux-usb -l."
		echo "Connect one in BootROM mode and run this smoke test again to also"
		echo "check live detection — and, if you like, try pressing Ctrl-C partway"
		echo "through: this build stops cleanly instead of needing a replug."
	else
		echo "termux-usb -l lists:"
		printf '  %s\n' $devs
		echo "This will run 'ping' only (no fdl, no writes) with a short, bounded"
		echo "probe: 4 tries, 6s wall, trace on. You can press Ctrl-C at any point"
		echo "to test the clean-stop behaviour; the probe after it will confirm the"
		echo "interface wasn't left busy either way."
		local reply
		read -r -p "Run the probe now? [y/N] " reply
		if [[ ${reply,,} == y ]]; then
			echo "+ SPDHOST_BROM_TRIES=4 SPDHOST_BROM_WALL_MS=6000 SPDHOST_BROM_TRACE=1 ${RUNNER[*]} ping"
			# set -m: run this one foreground job under job control so it
			# gets its own process group and, on a real terminal, temporary
			# terminal ownership — the same thing interactive bash always
			# does for a foreground command. Otherwise a Ctrl-C meant for
			# the probe would also hit menu.sh's own process (they'd share
			# a process group), killing the whole script before the
			# follow-up busy-check below ever got to run.
			set -m
			SPDHOST_BROM_TRIES=4 SPDHOST_BROM_WALL_MS=6000 SPDHOST_BROM_TRACE=1 run_session ping
			rc=$?
			set +m
			echo
			echo "Second short probe, to confirm the interface isn't stuck busy"
			echo "(same outcome expected whether or not you interrupted the first one):"
			SPDHOST_BROM_TRIES=2 SPDHOST_BROM_WALL_MS=3000 run_session ping >/tmp/spdhost-smoke-probe2.$$ 2>&1
			if grep -qi "LIBUSB_ERROR_BUSY\|interface .* is busy" /tmp/spdhost-smoke-probe2.$$; then
				echo "FAIL  interface is busy on the follow-up probe"
				ok=0
			else
				echo "PASS  no busy interface on the follow-up probe"
			fi
			cat /tmp/spdhost-smoke-probe2.$$
			rm -f /tmp/spdhost-smoke-probe2.$$
			(( rc == 0 )) || echo "note  first probe exited $rc — normal if the phone never answered hello"
		else
			echo "Skipped."
		fi
	fi
	echo

	if (( ok )); then
		echo "Smoke test: PASS"
	else
		echo "Smoke test: FAIL — see above"
	fi
	pause
}

reboot_mode() {
	local choice misc
	need_loaders || return
	cls
	echo "Reboot mode"
	echo "[1] system"
	echo "[2] recovery"
	echo "[3] fastbootd"
	echo "[4] power off"
	echo "[5] wipe userdata (via recovery BCB; destructive)"
	read -r -p "Choice: " choice
	case $choice in
		1)
			echo "Normal reset after the loaders."
			ready
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" reset || true
			;;
		2)
			echo "Writes 2048-byte recovery BCB to misc via reboot-recovery, then reset."
			if ! confirm_reboot_cmd reboot-recovery; then
				pause
				return
			fi
			ready
			# No --yes: spdhost prompts again on its TTY confirm path.
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
				reboot-recovery || true
			;;
		3)
			echo "Writes 2048-byte fastbootd BCB to misc via reboot-fastboot, then reset."
			if ! confirm_reboot_cmd reboot-fastboot; then
				pause
				return
			fi
			ready
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
				reboot-fastboot || true
			;;
		4)
			echo "Power off. The target stays off."
			ready
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" power-off || true
			;;
		5)
			resolve_misc_dir || { pause; return; }
			misc="$MISC_DIR/misc-wipe.bin"
			if [[ ! -f $misc ]]; then
				echo "missing $misc" >&2
				pause
				return
			fi
			echo "Wipe userdata via shipped misc-wipe.bin + reset (BCB only; no persist erase)."
			if ! confirm_wipe_userdata "$misc"; then
				pause
				return
			fi
			ready
			# No --yes. spdhost write-part will also require typed yes.
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
				write-part misc "$misc" reset || true
			;;
		*)
			echo "Unchanged."
			;;
	esac
	pause
}

load_config
apply_ums9230_infinix_defaults

while true; do
	cls
	echo "spdhost test menu"
	echo "FDL1: ${FDL1:-unset} ${FDL1_ADDR:-}"
	echo "FDL2: ${FDL2:-unset} ${FDL2_ADDR:-}"
	echo "Dumps go to: $DUMP_DIR"
	echo
	echo "[1] Dump a partition (list + closest match + size)"
	echo "[2] Reboot into a mode"
	echo "[3] Change loader files"
	echo "[4] List partitions only"
	echo "[5] Smoke test (safe checks, no writes)"
	echo "[0] Quit"
	read -r -p "Choice: " choice
	case ${choice:-} in
		1) dump_partition ;;
		2) reboot_mode ;;
		3) configure_loaders; pause ;;
		4) list_partitions_menu ;;
		5) smoke_test ;;
		0) exit 0 ;;
		*) echo "Not a choice."; pause ;;
	esac
done
