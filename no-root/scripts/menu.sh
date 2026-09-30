#!/usr/bin/env bash
# Test menu: dump one partition, or reboot into a mode.
# Default loaders: ums9230 Infinix fdl1-dl.bin and fdl2-dl.bin.
set -u

CONFIG="${SPDHOST_MENU_CONFIG:-$HOME/.spdhost-menu.conf}"
DUMP_DIR="${SPDHOST_DUMP_DIR:-$PWD/backup}"
FDL1_ADDR_DEFAULT=0x65000800
FDL2_ADDR_DEFAULT=0x9efffe00
# BootROM exec_addr (spd_dump's no-verify stub path; see TERMUX.md). With it,
# FDL1 is started by fdl/ums9230/custom_exec_no_verify_65015f08.bin instead of
# BSL_CMD_EXEC_DATA, which the Infinix BootROM signature-checks and hangs on.
# SPDHOST_EXEC_ADDR=0 (or off) disables; any 0x... overrides. Also EXEC_ADDR=
# in the menu config. Environment wins over config.
EXEC_ADDR_DEFAULT=0x65015f08
EXEC_ADDR=""

# Prefer this package's own scripts/ over PATH, so an unzipped release never
# picks up an older spdhost-usb installed in $PREFIX/bin. PATH is last resort.
# Always run the wrapper by absolute path so spdhost-usb can resolve ../spdhost via $0.
script_dir=$(cd "$(dirname "$0")" && pwd)
RUNNER=()
# Test hook: SPDHOST_MENU_RUNNER=/path/to/runner replaces spdhost-usb (tests/menu-dump.sh).
if [[ -n ${SPDHOST_MENU_RUNNER:-} ]]; then
	RUNNER=("$SPDHOST_MENU_RUNNER")
fi
for cand in \
	"$script_dir/spdhost-usb" \
	"$PWD/scripts/spdhost-usb" \
	"$PWD/spdhost-usb"
do
	(( ${#RUNNER[@]} )) && break
	if [[ -x $cand && -f $cand ]]; then
		RUNNER=("$(cd "$(dirname "$cand")" && printf '%s/%s' "$(pwd)" "$(basename "$cand")")")
		break
	fi
done
if (( ${#RUNNER[@]} == 0 )) && command -v spdhost-usb >/dev/null 2>&1; then
	RUNNER=("$(command -v spdhost-usb)")
	echo "note: using spdhost-usb from PATH (${RUNNER[0]}); package copy not found" >&2
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
EXEC_ADDR=$EXEC_ADDR
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
			EXEC_ADDR)
				[[ $val =~ ^(0[xX][0-9a-fA-F]+|0|off)$ ]] && EXEC_ADDR=$val
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

# Effective exec_addr: env SPDHOST_EXEC_ADDR, else config EXEC_ADDR, else
# default. Prints nothing when disabled (0/off/empty).
exec_addr_value() {
	local v
	if [[ -n ${SPDHOST_EXEC_ADDR+set} ]]; then
		v=$SPDHOST_EXEC_ADDR
	elif [[ -n $EXEC_ADDR ]]; then
		v=$EXEC_ADDR
	else
		v=$EXEC_ADDR_DEFAULT
	fi
	case $v in
		''|0|off|OFF|0x0|0X0) return 0 ;;
	esac
	printf '%s\n' "$v"
}

run_session() {
	local -a prefix=(--timeout "${SPDHOST_TIMEOUT:-3000}")
	local ea
	if [[ ${SPDHOST_VERBOSE:-} == 1 ]]; then
		prefix+=(--verbose)
	fi
	# Optional chunk size (decimal or 0x hex), e.g. SPDHOST_STEP=0xf800.
	if [[ -n ${SPDHOST_STEP:-} ]]; then
		prefix+=(--step "$SPDHOST_STEP")
	fi
	# Leading --flags from the caller (e.g. --keep-going) are spdhost options.
	while [[ ${1:-} == --* ]]; do
		prefix+=("$1")
		shift
	done
	# Every BootROM fdl flow starts with FDL1: put exec_addr in front of it.
	if [[ ${1:-} == fdl ]]; then
		ea=$(exec_addr_value)
		[[ -n $ea ]] && set -- exec_addr "$ea" "$@"
	fi
	echo "+ ${RUNNER[*]} ${prefix[*]} $*"
	"${RUNNER[@]}" "${prefix[@]}" "$@"
	local rc=$?
	echo "exit $rc"
	return "$rc"
}

# Cached live partition table from the last `parts` run, exactly as spdhost
# wrote it: "name units". Units are NOT bytes (KiB on eMMC); see
# parts_units_to_bytes. The byte table used for dumping is parts_bytes_path.
parts_cache_path() {
	mkdir -p "$DUMP_DIR"
	printf '%s\n' "$DUMP_DIR/partition_list.txt"
}

parts_bytes_path() {
	mkdir -p "$DUMP_DIR"
	printf '%s\n' "$DUMP_DIR/partition_bytes.txt"
}

# misc as read by the parts session (1048576 bytes, like spd_dump's
# "saving slot info" dump_partition(io, "misc", 0, 1048576, "misc.bin")).
slot_misc_path() {
	mkdir -p "$DUMP_DIR"
	printf '%s\n' "$DUMP_DIR/misc-slotinfo.img"
}

SPD_MISC_READ_BYTES=1048576
SPD_SPLLOADER_BYTES=262144 # spd_dump dumps splloader as 256 KiB (not in the table)
ACTIVE_SLOT=""
PARTS_SHIFT=""

# spd_dump partition_list() (common.c ~1106-1116): READ_PARTITION sizes are
# units. divisor starts at 10 and drops until every non-zero entry >> divisor
# is non-zero; bytes = units << (20 - divisor). eMMC tables are KiB (shift 10).
# RAW (units) -> OUT (bytes). Always derived from RAW, so it is idempotent.
parts_units_to_bytes() {
	local raw=$1 out=$2 name size div=10 tmp
	while read -r name size _; do
		[[ $size =~ ^[0-9]+$ ]] && (( size > 0 )) || continue
		while (( div > 0 && (size >> div) == 0 )); do ((div--)); done
	done < "$raw"
	tmp=$(mktemp "$out.XXXXXX") || return 1
	while read -r name size _; do
		[[ -n ${name:-} && $size =~ ^[0-9]+$ ]] || continue
		printf '%s %s\n' "$name" $(( size << (20 - div) ))
	done < "$raw" > "$tmp" && mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
	PARTS_SHIFT=$((20 - div))
}

# Active slot from misc bootloader_control at 0x800, as spd_dump select_ab():
# nb_slot (byte 0x809 & 7) must be 2; slot_info[i] is byte 0x80c+2i
# (priority:4 tries_remaining:3 successful_boot:1); ab_compare_slots(b, a) < 0
# -> b, else a. No uboot_a in the table -> not A/B (selected_ab = 0).
# Prints a, b, or nothing (unknown / not A/B).
slot_from_misc() {
	local misc=$1 table=$2 sz b nb s0 s1 p0 p1 t0 t1 ok0 ok1
	[[ -f $misc ]] || return 0
	sz=$(stat -c %s "$misc" 2>/dev/null) || return 0
	(( sz >= 0x820 )) || return 0
	if [[ -f $table ]] && ! grep -qE '^uboot_a[[:space:]]' "$table"; then
		return 0
	fi
	read -r nb _ _ s0 _ s1 _ < <(od -An -v -tu1 -j $((0x809)) -N 7 "$misc")
	[[ -n ${s1:-} ]] || return 0
	(( (nb & 7) == 2 )) || return 0
	p0=$((s0 & 15)); t0=$(((s0 >> 4) & 7)); ok0=$((s0 >> 7))
	p1=$((s1 & 15)); t1=$(((s1 >> 4) & 7)); ok1=$((s1 >> 7))
	if (( p0 != p1 )); then b=$((p0 - p1))
	elif (( ok0 != ok1 )); then b=$((ok0 - ok1))
	else b=$((t0 - t1)); fi
	if (( b < 0 )); then printf 'b'; else printf 'a'; fi
}

# Rebuild the byte table + active slot from the cached raw table and misc.
load_parts_state() {
	local raw bytes
	raw=$(parts_cache_path)
	bytes=$(parts_bytes_path)
	[[ -s $raw ]] || return 1
	parts_units_to_bytes "$raw" "$bytes" || return 1
	ACTIVE_SLOT=$(slot_from_misc "$(slot_misc_path)" "$bytes")
	return 0
}

fmt_size() {
	local n=$1 i=0 d=1 t
	local -a u=(B K M G T)
	if [[ ! $n =~ ^[0-9]+$ ]]; then
		printf '%s' "$n"
		return
	fi
	while (( i < 4 && n >= d * 1024 )); do
		d=$((d * 1024))
		((i++))
	done
	if (( i == 0 )); then
		printf '%dB' "$n"
	elif (( n % d == 0 )); then
		printf '%d%s' $((n / d)) "${u[i]}"
	else
		t=$(( (n * 10 + d / 2) / d ))
		printf '%d.%d%s' $((t / 10)) $((t % 10)) "${u[i]}"
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
	# Active slot (from misc, like spd_dump) outranks the other one; a if unknown.
	if [[ $nlow == "${query}_${ACTIVE_SLOT:-a}" ]]; then
		printf '950'
		return
	fi
	if [[ $nlow == "${query}_a" || $nlow == "${query}_b" ]]; then
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

# Print "name bytes" for the best match against PARTS_FILE (byte table), or fail.
# Ties prefer the active slot (ACTIVE_SLOT from misc), else _a.
# "splloader" is not in the table; spd_dump reads it as 256 KiB.
resolve_part_query() {
	local query_raw=$1 parts_file=$2
	local query name size best_name="" best_size="" best_score=0 score pref=${ACTIVE_SLOT:-a}
	query=$(normalize_part_query "$query_raw")
	if [[ -z $query || $query == */* || $query == *' '* ]]; then
		echo "Name must be one word, like boot, boot.img, or boot_a." >&2
		return 1
	fi
	if [[ ! -f $parts_file ]]; then
		echo "No partition list at $parts_file" >&2
		return 1
	fi
	if [[ $query == splloader ]] && ! grep -qE '^splloader[[:space:]]' "$parts_file"; then
		printf '%s %s\n' splloader "$SPD_SPLLOADER_BYTES"
		return 0
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
			if [[ ${name,,} == *_$pref && ${best_name,,} != *_$pref ]]; then
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
	echo "PARTITION LIST (from device parts table; units << ${PARTS_SHIFT:-?} = bytes):"
	printf '%-28s %12s %14s\n' "NAME" "SIZE" "BYTES"
	echo "------------------------------------------------------------"
	if ! grep -qE '^splloader[[:space:]]' "$parts_file"; then
		printf '%-28s %12s %14s\n' "splloader (fixed)" "$(fmt_size "$SPD_SPLLOADER_BYTES")" "$SPD_SPLLOADER_BYTES"
	fi
	while read -r name size _; do
		[[ -z ${name:-} || -z ${size:-} ]] && continue
		printf '%-28s %12s %14s\n' "$name" "$(fmt_size "$size")" "$size"
	done < "$parts_file"
	echo
	if [[ -n $ACTIVE_SLOT ]]; then
		echo "Active slot (from misc): $ACTIVE_SLOT"
	else
		echo "Active slot: unknown / not A/B (all_lite keeps both slots, like spd_dump)"
	fi
	echo "Type a name (boot, boot.img, boot_a, splloader), or:"
	echo "  all       — splloader + every partition except userdata, cache, blackbox"
	echo "  all_lite  — same, and skip the inactive slot"
}

# One session: parts table (units) + misc 1048576 bytes for the slot.
fetch_parts_table() {
	local raw misc rc sz
	raw=$(parts_cache_path)
	misc=$(slot_misc_path)
	echo "Fetching live partition table into $raw (+ misc slot info)"
	ready
	rm -f "$raw" "$misc"
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$raw" read-part misc 0 "$SPD_MISC_READ_BYTES" "$misc"
	rc=$?
	if [[ ! -s $raw ]]; then
		echo "parts failed (exit $rc)." >&2
		return 1
	fi
	sz=$(stat -c %s "$misc" 2>/dev/null || echo 0)
	if (( sz != SPD_MISC_READ_BYTES )); then
		echo "note: misc read gave $sz of $SPD_MISC_READ_BYTES bytes; active slot unknown." >&2
		rm -f "$misc"
	fi
	load_parts_state || { echo "could not convert $raw to bytes" >&2; return 1; }
	echo "parts: units -> bytes (shift $PARTS_SHIFT, like spd_dump); slot: ${ACTIVE_SLOT:-unknown}"
	return 0
}

should_skip_bulk() {
	local name=$1 mode=$2
	local nlow=${name,,}
	# spd_dump r all/all_lite: memcmp prefix blackbox / cache / userdata.
	case $nlow in
		blackbox*|cache*|userdata*) return 0 ;;
	esac
	if [[ $mode == all_lite ]]; then
		[[ $ACTIVE_SLOT == a && $nlow == *_b ]] && return 0
		[[ $ACTIVE_SLOT == b && $nlow == *_a ]] && return 0
	fi
	return 1
}

# SHA256SUMS entry name: path relative to DUMP_DIR when inside it.
record_sha256() {
	local f=$1 sums="$DUMP_DIR/SHA256SUMS" key digest tmp
	key=$f
	[[ $key == "$DUMP_DIR"/* ]] && key=${key#"$DUMP_DIR"/}
	digest=$(sha256sum "$f" | awk '{print $1}') || return 1
	if [[ -f $sums ]]; then
		tmp=$(mktemp "$sums.XXXXXX") || return 1
		awk -v k="$key" '{ n = $0; sub(/^[0-9a-f]+  /, "", n); if (n != k) print }' "$sums" > "$tmp" && mv "$tmp" "$sums"
	fi
	printf '%s  %s\n' "$digest" "$key" >> "$sums"
	echo "ok   $key $(fmt_size "$(stat -c %s "$f")") sha256 $digest"
}

# Run one session reading every queued (name, bytes, out) with --keep-going,
# then verify each file is exactly the expected size. Good files get a
# SHA256SUMS line; short ones become OUT.partial. Returns nonzero on any failure.
DQ_NAMES=()
DQ_SIZES=()
DQ_OUTS=()
run_dump_queue() {
	local i n=${#DQ_NAMES[@]} rc sz out args=() failed=()
	for (( i = 0; i < n; i++ )); do
		out=${DQ_OUTS[i]}
		rm -f "$out.partial" "$out.prev"
		[[ -e $out ]] && mv -f "$out" "$out.prev"
		args+=(read-part "${DQ_NAMES[i]}" 0 "${DQ_SIZES[i]}" "$out")
	done
	run_session --keep-going fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" "${args[@]}"
	rc=$?
	echo
	echo "Verifying $n file(s) (size == expected, then sha256 -> $DUMP_DIR/SHA256SUMS)"
	for (( i = 0; i < n; i++ )); do
		out=${DQ_OUTS[i]}
		sz=$(stat -c %s "$out" 2>/dev/null || echo -1)
		if (( sz == DQ_SIZES[i] )); then
			record_sha256 "$out" && rm -f "$out.prev" && continue
		fi
		failed+=("${DQ_NAMES[i]}")
		if (( sz >= 0 )); then
			mv -f "$out" "$out.partial"
			echo "FAIL ${DQ_NAMES[i]}: got $sz of ${DQ_SIZES[i]} bytes -> $out.partial"
		else
			echo "FAIL ${DQ_NAMES[i]}: no file (expected ${DQ_SIZES[i]} bytes)"
		fi
		[[ -e $out.prev ]] && mv -f "$out.prev" "$out" && echo "     previous $out kept"
	done
	if (( ${#failed[@]} )); then
		echo "FAILED (${#failed[@]} of $n): ${failed[*]}"
		(( rc != 0 )) || rc=1
		return "$rc"
	fi
	if (( rc != 0 )); then
		echo "all $n file(s) complete, but spdhost exited $rc"
		return "$rc"
	fi
	echo "all $n file(s) complete"
	return 0
}

dump_matched_parts() {
	local mode=$1 parts_file=$2
	local name size out
	mkdir -p "$DUMP_DIR"
	DQ_NAMES=() DQ_SIZES=() DQ_OUTS=()
	if [[ $mode == all_lite && -z $ACTIVE_SLOT ]]; then
		echo "note: active slot unknown; all_lite keeps both slots (spd_dump selected_ab=0)"
	fi
	# spd_dump r all / all_lite: splloader (256 KiB) first.
	if ! grep -qE '^splloader[[:space:]]' "$parts_file"; then
		DQ_NAMES+=(splloader) DQ_SIZES+=("$SPD_SPLLOADER_BYTES") DQ_OUTS+=("$DUMP_DIR/splloader.img")
		echo "queue splloader size=$(fmt_size "$SPD_SPLLOADER_BYTES") ($SPD_SPLLOADER_BYTES) -> $DUMP_DIR/splloader.img"
	fi
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
		DQ_NAMES+=("$name") DQ_SIZES+=("$size") DQ_OUTS+=("$out")
	done < "$parts_file"
	if (( ${#DQ_NAMES[@]} == 0 )); then
		echo "Nothing to dump."
		return 1
	fi
	echo "Will dump ${#DQ_NAMES[@]} partition(s) in one session (keeps going on errors)."
	ready
	run_dump_queue
}

# Check what one `parts RAW dump TARGET DUMP_DIR` session produced, using
# DUMP_DIR/dump-manifest.txt from spdhost ("start NAME BYTES FILE", then
# "ok NAME" / "fail NAME"). Every started entry must have an ok line AND a file
# of exactly BYTES; good ones go to SHA256SUMS, others are listed as failed
# (spdhost leaves a short read as NAME.img.partial and keeps an older NAME.img).
verify_dump_manifest() {
	local rc=$1 man="$DUMP_DIR/dump-manifest.txt" tag name bytes file sz n=0
	local -a failed=()
	local -A okset=()
	if [[ ! -f $man ]]; then
		echo "FAILED: spdhost wrote no $man (session exit $rc)"
		(( rc != 0 )) || rc=1
		return "$rc"
	fi
	while read -r tag name _; do
		[[ $tag == ok ]] && okset[$name]=1
	done < "$man"
	echo
	echo "Verifying (size == expected, then sha256 -> $DUMP_DIR/SHA256SUMS)"
	while read -r tag name bytes file; do
		case $tag in
			missing) failed+=("$name(not in live table)"); continue ;;
			start) ;;
			*) continue ;;
		esac
		((n++))
		file="$DUMP_DIR/$file"
		sz=$(stat -c %s "$file" 2>/dev/null || echo -1)
		if [[ -n ${okset[$name]:-} ]] && (( sz == bytes )); then
			record_sha256 "$file" || failed+=("$name")
			continue
		fi
		failed+=("$name")
		if [[ -f $file.partial ]]; then
			echo "FAIL $name: got $(stat -c %s "$file.partial") of $bytes bytes -> $file.partial"
		elif [[ -z ${okset[$name]:-} ]]; then
			echo "FAIL $name: read did not complete (expected $bytes bytes)"
		else
			echo "FAIL $name: $file is $sz bytes, expected $bytes"
		fi
		[[ -e $file && -z ${okset[$name]:-} ]] && echo "     $file is an OLDER copy, not from this session"
	done < "$man"
	if (( ${#failed[@]} )); then
		echo "FAILED (${#failed[@]} of $n): ${failed[*]}"
		(( rc != 0 )) || rc=1
		return "$rc"
	fi
	if (( rc != 0 )); then
		echo "all $n file(s) complete, but spdhost exited $rc"
		return "$rc"
	fi
	echo "all $n file(s) complete"
	return 0
}

# Refresh + dump in ONE spdhost-usb session: exec_addr + fdl + fdl + parts +
# dump TARGET. spdhost takes names/sizes from the table it just read (units ->
# bytes and slot exactly like spd_dump), so FDL2 never drops between the two.
# TARGET: all, all_lite, splloader, or a partition name (NAME or NAME without
# the slot suffix: spdhost adds the live active slot).
dump_live_session() {
	local target=$1 raw rc
	raw=$(parts_cache_path)
	mkdir -p "$DUMP_DIR"
	rm -f "$DUMP_DIR/dump-manifest.txt" "$(slot_misc_path)"
	echo "One session: refresh the partition table, then dump '$target' (keeps going on errors)."
	ready
	run_session --keep-going fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$raw" dump "$target" "$DUMP_DIR"
	rc=$?
	if [[ -s $raw ]]; then
		load_parts_state && echo "table refreshed: $raw (slot ${ACTIVE_SLOT:-unknown})"
	fi
	verify_dump_manifest "$rc"
}

# Name to hand spdhost `dump`: fuzzy-match against the cached table when there
# is one (boot.img -> boot_a); drop a slot suffix the user did not type so the
# live active slot is used. Without a cache, pass the normalized name.
live_dump_target() {
	local query=$1 parts_file=$2 q m name
	q=$(normalize_part_query "$query")
	case $q in all|all_lite|splloader) printf '%s\n' "$q"; return 0 ;; esac
	if [[ -s $parts_file ]] && m=$(resolve_part_query "$query" "$parts_file" 2>/dev/null); then
		read -r name _ <<<"$m"
		if [[ $name == *_[ab] && $q != *_[ab] ]]; then
			name=${name%_[ab]}
		fi
		printf '%s\n' "$name"
		return 0
	fi
	if [[ -z $q || $q == */* || $q == *' '* ]]; then
		echo "Name must be one word, like boot, boot.img, or boot_a." >&2
		return 1
	fi
	printf '%s\n' "$q"
}

dump_partition() {
	local parts_file raw reply query matched name size out refresh=0 target rc
	need_loaders || return
	cls
	echo "Dump partition(s)"
	echo "Lists the live device table (like rooted menu LIST PARTISI),"
	echo "then matches what you type (boot.img -> boot_<active slot>) and uses that size."
	raw=$(parts_cache_path)
	parts_file=$(parts_bytes_path)
	if [[ -s $raw ]]; then
		echo "Cached list: $raw"
		read -r -p "Refresh from device? [y/N]: " reply
		[[ ${reply,,} == y || ${reply,,} == yes ]] && refresh=1
	else
		echo "No cached partition list: the table is read in the same session as the dump."
		refresh=1
	fi
	if (( refresh )); then
		# Ask first, then ONE session reads the table and dumps (no FDL2 drop).
		if [[ -s $raw ]] && load_parts_state; then
			cls
			echo "(cached list below; sizes and slot are re-read from the device)"
			show_parts_list "$parts_file"
		else
			echo "Type a partition name (boot, boot.img, boot_a, splloader), or all / all_lite."
		fi
		read -r -p "Partition name (or all / all_lite): " query
		if [[ -z ${query:-} ]]; then
			echo "Cancelled."
			pause
			return
		fi
		target=$(live_dump_target "$query" "$parts_file") || { pause; return 1; }
		echo "Will dump '$target' using the live table."
		dump_live_session "$target"
		rc=$?
		pause
		return "$rc"
	fi
	if ! load_parts_state || [[ ! -s $parts_file ]]; then
		echo "No partition list."
		pause
		return 1
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
			rc=$?
			pause
			return "$rc"
			;;
	esac
	matched=$(resolve_part_query "$query" "$parts_file") || {
		pause
		return 1
	}
	read -r name size <<<"$matched"
	out="$DUMP_DIR/${name}.img"
	echo
	echo "Matched '$query' -> $name  size=$(fmt_size "$size") ($size bytes)"
	read -r -e -p "Output file [$out]: " reply
	[[ -n ${reply:-} ]] && out=$reply
	echo "Will read $name at offset 0, size $size bytes, into $out"
	ready
	DQ_NAMES=("$name") DQ_SIZES=("$size") DQ_OUTS=("$out")
	run_dump_queue
	rc=$?
	pause
	return "$rc"
}

list_partitions_menu() {
	need_loaders || return
	cls
	echo "List partitions (live parts table)"
	fetch_parts_table || { pause; return; }
	cls
	show_parts_list "$(parts_bytes_path)"
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
	echo "About to write $(stat -c %s "$misc") bytes to partition 'misc' ($kind), then reset."
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

# Misc write guarded in ONE session: parts (live misc size) + misc-backup
# backup/misc-before-<ts>.img (spdhost reads all of misc, writes the file,
# reads the file back; any failure ends the session BEFORE the write) + the
# write command (spdhost reads misc back and compares: written bytes equal,
# rest unchanged; mismatch -> no reset) + reset. Then the menu re-checks the
# backup size against the table and records its sha256 in SHA256SUMS.
# No --yes: the caller already took a typed "yes" and spdhost asks again.
guarded_misc_session() {
	local kind=$1 ts backup raw rc want sz
	shift
	ts=$(date +%Y%m%d-%H%M%S)
	mkdir -p "$DUMP_DIR"
	backup="$DUMP_DIR/misc-before-$ts.img"
	raw=$(parts_cache_path)
	echo "misc will be backed up to $backup first; the write is skipped if that fails."
	ready
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$raw" misc-backup "$backup" "$@"
	rc=$?
	load_parts_state >/dev/null 2>&1
	want=$(awk '$1 == "misc" { print $2; exit }' "$(parts_bytes_path)" 2>/dev/null)
	[[ $want =~ ^[0-9]+$ ]] || want=$SPD_MISC_READ_BYTES
	sz=$(stat -c %s "$backup" 2>/dev/null || echo -1)
	if (( sz == want )); then
		record_sha256 "$backup"
		echo "To restore misc later (typed confirm, no --yes):"
		echo "  bash scripts/spdhost-usb fdl <fdl1> $FDL1_ADDR fdl <fdl2> $FDL2_ADDR write-part misc $backup reset"
		echo "  (or menu [2] -> [6] restore misc from a backup)"
	else
		echo "misc backup missing or wrong size ($sz of $want bytes): the write was NOT done." >&2
		rm -f "$backup"
		(( rc != 0 )) || rc=1
	fi
	if (( rc != 0 )); then
		echo "$kind FAILED (exit $rc). Read the spdhost lines above: no reset happens after a failed backup or a misc read-back mismatch."
	else
		echo "$kind: misc written, read back and verified, then reset."
	fi
	return "$rc"
}

restore_misc_menu() {
	local f reply
	local -a list=()
	mapfile -t list < <(ls -1t "$DUMP_DIR"/misc-before-*.img 2>/dev/null)
	if (( ${#list[@]} == 0 )); then
		echo "No $DUMP_DIR/misc-before-*.img backups."
		return 1
	fi
	echo "misc backups (newest first):"
	local i
	for i in "${!list[@]}"; do
		echo "  [$((i + 1))] ${list[i]}  $(stat -c %s "${list[i]}") bytes"
	done
	read -r -p "Restore which? [1]: " reply
	reply=${reply:-1}
	[[ $reply =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#list[@]} )) || { echo "Unchanged."; return 1; }
	f=${list[reply - 1]}
	if [[ -f $DUMP_DIR/SHA256SUMS ]] && grep -q " ${f##*/}\$" "$DUMP_DIR/SHA256SUMS"; then
		( cd "$DUMP_DIR" && grep " ${f##*/}\$" SHA256SUMS | sha256sum -c --quiet ) || { echo "sha256 mismatch for $f; refusing." >&2; return 1; }
		echo "sha256 OK (SHA256SUMS)"
	else
		echo "note: $f has no SHA256SUMS line"
	fi
	confirm_misc_write "restore $(basename "$f")" "$f" || return 1
	guarded_misc_session "restore misc" write-part misc "$f" reset
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
	echo "[6] restore misc from a backup (backup/misc-before-*.img)"
	echo "misc writes ([2],[3],[5],[6]) back up misc first and verify it after."
	read -r -p "Choice: " choice
	case $choice in
		1)
			echo "Normal reset after the loaders."
			ready
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" reset
			;;
		2)
			echo "Writes 2048-byte recovery BCB to misc via reboot-recovery, then reset."
			if ! confirm_reboot_cmd reboot-recovery; then
				pause
				return
			fi
			# No --yes: spdhost prompts again on its TTY confirm path.
			guarded_misc_session reboot-recovery reboot-recovery
			;;
		3)
			echo "Writes 2048-byte fastbootd BCB to misc via reboot-fastboot, then reset."
			if ! confirm_reboot_cmd reboot-fastboot; then
				pause
				return
			fi
			guarded_misc_session reboot-fastboot reboot-fastboot
			;;
		4)
			echo "Power off. The target stays off."
			ready
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" power-off
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
			# No --yes. spdhost write-part will also require typed yes.
			guarded_misc_session wipe-userdata write-part misc "$misc" reset
			;;
		6)
			restore_misc_menu
			;;
		*)
			echo "Unchanged."
			;;
	esac
	pause
}

# Test hook: SPDHOST_MENU_LIB=1 + `source menu.sh` loads functions only.
if [[ ${SPDHOST_MENU_LIB:-} == 1 ]]; then
	return 0 2>/dev/null || exit 0
fi

load_config
apply_ums9230_infinix_defaults

while true; do
	cls
	echo "spdhost test menu"
	echo "wrapper: ${RUNNER[0]}"
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
