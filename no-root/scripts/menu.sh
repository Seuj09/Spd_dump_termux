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
# Release menu "hex mode 2" for ums9230. The stub is not shipped here.
EXEC_ADDR_ALT=0x65015f48
EXEC_ADDR=""
# Images named <partition>.img (release menu "Pasang Partisi" / input/).
# Filled in after this file's path is known: beside fdl/ when the package
# is unzipped, otherwise the directory the menu was started from.
INPUT_DIR=""
# Appended after flash, restore, repartition, set-slot, and dump.
# reset and power-off match the release menu. reboot-recovery and
# reboot-fastboot are the same 2048-byte BCB the reboot menu already sends;
# the slot block at misc+0x800 is past that write. The menu never passes --yes.
BOOT_AFTER=reset

# Prefer this package's own scripts/ over PATH, so an unzipped release never
# picks up an older spdhost-usb installed in $PREFIX/bin. PATH is last resort.
# Always run the wrapper by absolute path so spdhost-usb can resolve ../spdhost via $0.
script_dir=$(cd "$(dirname "$0")" && pwd)
# Package root is the directory that contains fdl/ (parent of scripts/).
# A menu copied into $PREFIX/bin has no fdl next to it, so images stay in
# $PWD/input, which is created before the first prompt.
if [[ -z ${SPDHOST_INPUT_DIR:-} ]]; then
	if [[ -d $script_dir/../fdl ]]; then
		INPUT_DIR=$(cd "$script_dir/.." && pwd)/input
	elif [[ -d $script_dir/fdl ]]; then
		INPUT_DIR=$script_dir/input
	else
		INPUT_DIR=$PWD/input
	fi
else
	INPUT_DIR=$SPDHOST_INPUT_DIR
fi
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
# Empty until option 3 picks a shipped model. ums9230 addresses stay the
# defaults above so an existing Infinix config keeps working.
SOC=""
DEVICE=""

pause() {
	# Explicit return 0: this is a UI delay, not a readiness signal. Without
	# it, pause's own exit status (read's status) becomes this function's
	# implicit return value, and read fails (EOF) whenever stdin is not an
	# interactive terminal. ready() ends with a call to pause(), and every
	# session-starting function now gates on `ready || return 1` — so a
	# non-interactive stdin would make every one of those silently report
	# "not ready" and abort, even though nothing about the device or the
	# exec stub was actually checked at that point. Verified: this is what
	# took tests/menu-dump.sh from 46/47 to 12/47 passing before this line
	# was added back.
	read -r -p "Press Enter to continue..." _
	return 0
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
SOC=$SOC
DEVICE=$DEVICE
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
			SOC)
				[[ $val =~ ^(ums9230|ums512|sc9863a)$ ]] && SOC=$val
				;;
			DEVICE)
				[[ $val =~ ^[A-Za-z0-9._/+-]+$ ]] && DEVICE=$val
				;;
		esac
	done < "$CONFIG"
	# Hex mode's second address depends on the chip. File paths stay as saved.
	if [[ -n $SOC ]]; then
		soc_profile "$SOC" || true
	fi
}

# Release menu addresses. Primary exec stub, then the hex-mode alternate.
# These are the normal download loaders, not the unlock files.
soc_profile() {
	local soc=$1
	case $soc in
		ums9230)
			SOC_FDL1_ADDR=0x65000800
			SOC_FDL2_ADDR=0x9efffe00
			EXEC_ADDR_DEFAULT=0x65015f08
			EXEC_ADDR_ALT=0x65015f48
			;;
		ums512)
			SOC_FDL1_ADDR=0x5500
			SOC_FDL2_ADDR=0x9efffe00
			EXEC_ADDR_DEFAULT=0x3ee8
			EXEC_ADDR_ALT=0x3f48
			;;
		sc9863a)
			SOC_FDL1_ADDR=0x5000
			SOC_FDL2_ADDR=0x9efffe00
			EXEC_ADDR_DEFAULT=0x4ee8
			EXEC_ADDR_ALT=0x4f48
			;;
		*) return 1 ;;
	esac
}

soc_brands() {
	case $1 in
		ums9230) printf '%s\n' infinix itel realme tecno ;;
		sc9863a) printf '%s\n' itel realme ;;
		ums512) printf '%s\n' infinix realme ;;
		*) return 1 ;;
	esac
}

pkg_fdl_root() {
	local d
	d=$(cd "$(dirname "${BASH_SOURCE[0]}")/../fdl" 2>/dev/null && pwd) || return 1
	[[ -d $d ]] || return 1
	printf '%s\n' "$d"
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

configure_loaders_manual() {
	echo "Loader files and load addresses for this chip."
	echo "These are the same FDL1/FDL2 pair the rooted menu uses. A wrong address can brick the phone."
	FDL1=$(ask_file "FDL1 file:")
	FDL1_ADDR=$(ask_addr "FDL1 address:")
	FDL2=$(ask_file "FDL2 file:")
	FDL2_ADDR=$(ask_addr "FDL2 address:")
	save_config
	echo "Saved $CONFIG"
}

# Shipped fdl1-dl.bin + fdl2-dl.bin for one release-menu model.
# Prints two lines: fdl1 path, fdl2 path. Model is empty for the brand pair,
# or a subdirectory name under alternatif/ (the release spelling "alternativ"
# is accepted too).
shipped_fdl_pair() {
	local root=$1 soc=$2 brand=$3 model=$4 dir
	if [[ -n $model ]]; then
		for dir in "$root/$soc/$brand/alternatif/$model" "$root/$soc/$brand/alternativ/$model"; do
			if [[ -f $dir/fdl1-dl.bin && -f $dir/fdl2-dl.bin ]]; then
				printf '%s\n%s\n' "$dir/fdl1-dl.bin" "$dir/fdl2-dl.bin"
				return 0
			fi
		done
		return 1
	fi
	dir=$root/$soc/$brand
	[[ -f $dir/fdl1-dl.bin && -f $dir/fdl2-dl.bin ]] || return 1
	printf '%s\n%s\n' "$dir/fdl1-dl.bin" "$dir/fdl2-dl.bin"
}

# Names of alternatif/ model folders that contain both loaders.
shipped_alt_models() {
	local root=$1 soc=$2 brand=$3 d base
	local -a found=()
	shopt -s nullglob
	for d in "$root/$soc/$brand/alternatif"/*/ "$root/$soc/$brand/alternativ"/*/; do
		[[ -f ${d}fdl1-dl.bin && -f ${d}fdl2-dl.bin ]] || continue
		base=$(basename "$d")
		found+=("$base")
	done
	shopt -u nullglob
	((${#found[@]})) || return 1
	printf '%s\n' "${found[@]}"
}

select_shipped_model() {
	local root soc brand model choice n i label
	local -a brands=() alts=() pair=()
	root=$(pkg_fdl_root) || { echo "No fdl/ directory next to this menu."; return 1; }
	echo "Pick the chip. Addresses match the release menu."
	echo "[1] ums9230   FDL1 0x65000800"
	echo "[2] sc9863a   FDL1 0x5000"
	echo "[3] ums512    FDL1 0x5500"
	echo "[0] Back"
	read -r -p "Choice: " choice
	case $choice in
		0) echo "Back to the menu."; return 0 ;;
		1) soc=ums9230 ;;
		2) soc=sc9863a ;;
		3) soc=ums512 ;;
		*) echo "Unchanged."; return 1 ;;
	esac
	continue_choice "$soc loaders" || return
	mapfile -t brands < <(soc_brands "$soc")
	echo "Pick the brand. Uses that brand's fdl1-dl.bin and fdl2-dl.bin."
	n=1
	for brand in "${brands[@]}"; do
		echo "[$n] $brand"
		n=$((n + 1))
	done
	echo "[0] Back"
	read -r -p "Choice: " choice
	case $choice in
		0) echo "Back to the menu."; return 0 ;;
		''|*[!0-9]*) echo "Unchanged."; return 1 ;;
	esac
	i=$((choice - 1))
	if (( i < 0 || i >= ${#brands[@]} )); then
		echo "Unchanged."
		return 1
	fi
	brand=${brands[$i]}
	continue_choice "$soc $brand" || return
	model=""
	mapfile -t alts < <(shipped_alt_models "$root" "$soc" "$brand" || true)
	if ((${#alts[@]})); then
		echo "Pick the loader pair."
		echo "[1] $brand (main pair)"
		n=2
		for label in "${alts[@]}"; do
			echo "[$n] $label"
			n=$((n + 1))
		done
		echo "[0] Back"
		read -r -p "Choice: " choice
		case $choice in
			0) echo "Back to the menu."; return 0 ;;
			1) model="" ;;
			''|*[!0-9]*) echo "Unchanged."; return 1 ;;
			*)
				i=$((choice - 2))
				if (( i < 0 || i >= ${#alts[@]} )); then
					echo "Unchanged."
					return 1
				fi
				model=${alts[$i]}
				;;
		esac
		continue_choice "$soc $brand ${model:-main}" || return
	fi
	mapfile -t pair < <(shipped_fdl_pair "$root" "$soc" "$brand" "$model") || {
		echo "That pair is not in fdl/."
		return 1
	}
	soc_profile "$soc" || return 1
	echo "  ${pair[0]} @ $SOC_FDL1_ADDR"
	echo "  ${pair[1]} @ $SOC_FDL2_ADDR"
	echo "  exec stub $EXEC_ADDR_DEFAULT"
	echo "A wrong chip or address can brick the phone."
	if ! confirm_action "type yes to use these loaders: "; then
		return 1
	fi
	SOC=$soc
	if [[ -n $model ]]; then
		DEVICE=$brand/$model
	else
		DEVICE=$brand
	fi
	FDL1=${pair[0]}
	FDL2=${pair[1]}
	FDL1_ADDR=$SOC_FDL1_ADDR
	FDL2_ADDR=$SOC_FDL2_ADDR
	EXEC_ADDR=$EXEC_ADDR_DEFAULT
	save_config
	echo "Saved $SOC $DEVICE to $CONFIG"
}

configure_loaders() {
	local choice
	echo "Loader files for this chip. The shipped set is the release menu's"
	echo "fdl1-dl.bin and fdl2-dl.bin for each model. A wrong address can brick the phone."
	echo "[1] Pick a shipped model"
	echo "[2] Type your own loader paths"
	echo "[0] Back"
	read -r -p "Choice: " choice
	case $choice in
		0) echo "Back to the menu."; return 0 ;;
		1) continue_choice "a shipped model" || return
			select_shipped_model ;;
		2) continue_choice "typed loader paths" || return
			configure_loaders_manual ;;
		*) echo "Unchanged." ;;
	esac
}

need_loaders() {
	if [[ -f $FDL1 && -n $FDL1_ADDR && -f $FDL2 && -n $FDL2_ADDR ]]; then
		return 0
	fi
	echo "Set the loader files first."
	configure_loaders
}

ready() {
	local ea
	# Fail before the plug-in wait. run_session checks again.
	ea=$(exec_addr_value) || ea=
	if [[ -n $ea ]]; then
		exec_stub_present "$ea" || return 1
	fi
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

# custom_exec_no_verify_<hex>.bin for exec_addr, same name spdhost looks up.
# Fail here, before the plug-in wait, when the stub is not on disk.
exec_stub_present() {
	local ea=$1 hex name d
	local -a places=()
	hex=$(printf '%x' "$((ea))" 2>/dev/null) || return 1
	name="custom_exec_no_verify_${hex}.bin"
	places+=(
		"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fdl/${SOC:-ums9230}/$name"
		"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fdl/ums9230/$name"
		"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fdl/ums512/$name"
		"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fdl/sc9863a/$name"
		"$PWD/fdl/${SOC:-ums9230}/$name"
		"$PWD/fdl/ums9230/$name"
		"$PWD/$name"
		"$HOME/spdhost/fdl/ums9230/$name"
		"$HOME/Spd_dump_termux/no-root/fdl/ums9230/$name"
	)
	if [[ -n ${FDL1:-} ]]; then
		places+=("$(dirname "$FDL1")/$name" "$(dirname "$FDL1")/../$name")
	fi
	if [[ -n ${RUNNER[0]:-} ]]; then
		places+=("$(dirname "${RUNNER[0]}")/../fdl/ums9230/$name")
	fi
	for d in "${places[@]}"; do
		[[ -f $d ]] && return 0
	done
	echo "missing $name for exec_addr $ea." >&2
	echo "Put it in fdl/ums9230/, or set SPDHOST_EXEC_ADDR=0 to use BSL EXEC." >&2
	return 1
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
		ea=$(exec_addr_value) || ea=
		if [[ -n $ea ]]; then
			exec_stub_present "$ea" || return 1
			set -- exec_addr "$ea" "$@"
		fi
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

# 32-byte bootloader_control from misc+0x800 (spd_dump select_ab). An older
# full misc image (>= 0x820 bytes) is still accepted by slot_from_misc.
slot_misc_path() {
	mkdir -p "$DUMP_DIR"
	printf '%s\n' "$DUMP_DIR/misc-slotinfo.img"
}

SPD_SLOT_OFF=0x800
SPD_SLOT_BYTES=32
SPD_MISC_READ_BYTES=1048576 # fallback when the table has no misc size
SPD_SPLLOADER_BYTES=262144 # spd_dump dumps splloader as 256 KiB (not in the table)
# Shipped misc/misc-wipe.bin (boot-recovery + recovery\n--wipe_data\n at 0x40).
MISC_WIPE_SHA=bd6b67e852d6072e6fb87040f2ac40216d5b661b7fa661e7024569ecf8ddb3a7
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
	local misc=$1 table=$2 sz base=0 b nb s0 s1 p0 p1 t0 t1 ok0 ok1
	[[ -f $misc ]] || return 0
	sz=$(stat -c %s "$misc" 2>/dev/null) || return 0
	if (( sz == SPD_SLOT_BYTES )); then
		base=0
	elif (( sz >= 0x820 )); then
		base=0x800
	else
		return 0
	fi
	if [[ -f $table ]] && ! grep -qE '^uboot_a[[:space:]]' "$table"; then
		return 0
	fi
	read -r nb _ _ s0 _ s1 _ < <(od -An -v -tu1 -j $((base + 9)) -N 7 "$misc")
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

# One session: parts table (units) + 32 bytes at misc+0x800 for the slot.
fetch_parts_table() {
	local raw misc rc sz
	raw=$(parts_cache_path)
	misc=$(slot_misc_path)
	echo "Fetching live partition table into $raw (+ 32-byte slot record)"
	ready || return 1
	rm -f "$raw" "$misc"
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$raw" read-part misc "$SPD_SLOT_OFF" "$SPD_SLOT_BYTES" "$misc"
	rc=$?
	if [[ ! -s $raw ]]; then
		echo "parts failed (exit $rc)." >&2
		return 1
	fi
	sz=$(stat -c %s "$misc" 2>/dev/null || echo 0)
	if (( sz != SPD_SLOT_BYTES )); then
		echo "note: slot read gave $sz of $SPD_SLOT_BYTES bytes; active slot unknown." >&2
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
	run_session --keep-going fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" "${args[@]}" "$BOOT_AFTER"
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

# Same dumper as a live refresh: one spdhost session reads the table, the
# 32-byte slot record, and the partitions. The cached byte table is only a hint.
dump_matched_parts() {
	local mode=$1
	dump_live_session "$mode"
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
	ready || return 1
	run_session --keep-going fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$raw" dump "$target" "$DUMP_DIR" "$BOOT_AFTER"
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

# Release menu "imei": miscdata, prodnv, both fixnv, both runtimenv.
# nv1 names are read from the nv2 partition at offset 512 inside spdhost.
dump_imei_session() {
	local raw rc
	raw=$(parts_cache_path)
	mkdir -p "$DUMP_DIR"
	echo "One session: refresh the table, then dump miscdata prodnv l_fixnv1 l_fixnv2 l_runtimenv1 l_runtimenv2."
	ready || return 1
	rm -f "$DUMP_DIR/dump-manifest.txt"
	run_session --keep-going fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$raw" \
		dump miscdata "$DUMP_DIR" \
		dump prodnv "$DUMP_DIR" \
		dump l_fixnv1 "$DUMP_DIR" \
		dump l_fixnv2 "$DUMP_DIR" \
		dump l_runtimenv1 "$DUMP_DIR" \
		dump l_runtimenv2 "$DUMP_DIR" \
		"$BOOT_AFTER"
	rc=$?
	[[ -s $raw ]] && load_parts_state && echo "table refreshed: $raw (slot ${ACTIVE_SLOT:-unknown})"
	verify_dump_manifest "$rc"
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
		read -r -p "Partition name (or all / all_lite / imei): " query
		if [[ -z ${query:-} ]]; then
			echo "Cancelled."
			pause
			return
		fi
		if [[ ${query,,} == imei ]]; then
			dump_imei_session
			rc=$?
			pause
			return "$rc"
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
	read -r -p "Partition name (or all / all_lite / imei): " query
	if [[ -z ${query:-} ]]; then
		echo "Cancelled."
		pause
		return
	fi
	case ${query,,} in
		imei)
			dump_imei_session
			rc=$?
			pause
			return "$rc"
			;;
		all|all_lite)
			echo "Reading the live table, then dumping ${query,,}."
			dump_live_session "${query,,}"
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
	echo
	echo "Cached match '$query' -> $name  size=$(fmt_size "$size") ($size bytes)"
	echo "The dump re-reads the device. A name without _a/_b follows the live slot."
	target=$(live_dump_target "$query" "$parts_file") || { pause; return 1; }
	dump_live_session "$target"
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

# Brick-adjacent: never pass --yes for misc/reboot/wipe. The menu's typed
# confirm on its own TTY is THE gate. On "yes" it sets MISC_CONFIRM_TOKEN to
# the sha256 of the exact bytes spdhost will write to misc; guarded_misc_session
# passes it as --confirm-token (spdhost hashes what it is about to write and
# refuses on any mismatch). spdhost never prompts again: under termux-usb -e
# its prompt would be invisible (stderr is buffered until exit).
MISC_CONFIRM_TOKEN=

# sha256 of the 2048-byte BCB spdhost builds for reboot-recovery (kind 0) /
# reboot-fastboot (kind 1): "boot-recovery" at 0, "recovery\n--fastboot\n"
# at 0x40 for fastboot, zero elsewhere (same bytes as misc/misc-*.bin).
misc_bcb_sha256() {
	if [[ $1 == reboot-fastboot ]]; then
		{ printf 'boot-recovery'; head -c $((0x40 - 13)) /dev/zero
		  printf 'recovery\n--fastboot\n'; head -c $((0x800 - 0x40 - 20)) /dev/zero; }
	else
		{ printf 'boot-recovery'; head -c $((0x800 - 13)) /dev/zero; }
	fi | sha256sum | awk '{print $1}'
}

# Read one typed answer; "yes" with trailing CR/LF/space/tab accepted.
# Sets MISC_CONFIRM_TOKEN=$2 on yes; prints "menu: not confirmed" otherwise.
menu_typed_yes() {
	local prompt=$1 token=$2 reply
	MISC_CONFIRM_TOKEN=
	if ! read -r -p "$prompt" reply; then
		reply=
	fi
	while [[ $reply == *[$' \t\r\n'] ]]; do reply=${reply%?}; done
	if [[ $reply != yes ]]; then
		echo "menu: not confirmed"
		return 1
	fi
	MISC_CONFIRM_TOKEN=$token
	return 0
}

confirm_misc_write() {
	local kind=$1 misc=$2 digest
	MISC_CONFIRM_TOKEN=
	if [[ ! -t 0 ]]; then
		echo "refusing to write misc without a TTY (no silent --yes)" >&2
		return 1
	fi
	digest=$(sha256sum "$misc" | awk '{print $1}')
	echo "About to write $(stat -c %s "$misc") bytes to partition 'misc' ($kind), then reset."
	echo "misc image sha256: $digest"
	echo "Wrong chip/FDL or a mis-click can soft-brick the boot path."
	menu_typed_yes "type yes to write misc: " "$digest"
}

# Louder prompt for wipe BCB (recovery --wipe_data). Does NOT erase persist/userdata partitions.
confirm_wipe_userdata() {
	local misc=$1 digest
	MISC_CONFIRM_TOKEN=
	if [[ ! -t 0 ]]; then
		echo "refusing wipe-userdata without a TTY (no silent --yes)" >&2
		return 1
	fi
	local sz
	sz=$(stat -c %s "$misc" 2>/dev/null || echo 0)
	if (( sz != 2048 )); then
		echo "refusing wipe: $misc is $sz bytes; a wipe BCB is exactly 2048." >&2
		return 1
	fi
	digest=$(sha256sum "$misc" | awk '{print $1}')
	if [[ $digest != "$MISC_WIPE_SHA" ]]; then
		echo "refusing wipe: $misc sha256 $digest is not the shipped misc-wipe.bin." >&2
		return 1
	fi
	echo "WARNING: This writes a recovery --wipe_data BCB to misc ($sz bytes), then reset."
	echo "Recovery will ERASE USERDATA on the next boot. It does not erase persist here."
	echo "misc-wipe.bin sha256: $digest"
	echo "Wrong chip/FDL or a mis-click can soft-brick the boot path and destroy user data."
	menu_typed_yes "type yes to erase userdata via recovery: " "$digest"
}

# Typed confirm for in-process reboot-recovery / reboot-fastboot.
confirm_reboot_cmd() {
	local kind=$1 digest
	MISC_CONFIRM_TOKEN=
	if [[ ! -t 0 ]]; then
		echo "refusing $kind without a TTY (no silent --yes)" >&2
		return 1
	fi
	digest=$(misc_bcb_sha256 "$kind")
	echo "About to run $kind: write exactly 2048 bytes to misc, then reset."
	echo "BCB sha256: $digest"
	echo "Wrong chip/FDL or a mis-click can soft-brick the boot path."
	menu_typed_yes "type yes to continue: " "$digest"
}

# Navigation only. y/yes runs the option that was just picked. Enter, n, or
# anything else returns to the menu. This does not replace confirm_action
# or confirm_dangerous: those still require the full word before any write.
continue_choice() {
	local what=$1 reply
	echo "Picked: $what"
	if ! read -r -p "y = continue, n = back to the menu [n]: " reply; then
		echo "Back to the menu."
		return 1
	fi
	while [[ $reply == *[$' \t\r\n'] ]]; do reply=${reply%?}; done
	case ${reply,,} in
		y|yes) return 0 ;;
	esac
	echo "Back to the menu."
	return 1
}

# Typed yes for actions that do not write misc (system reboot, power off).
confirm_action() {
	local prompt=$1 reply
	if [[ ! -t 0 ]]; then
		echo "refusing without a TTY (no silent confirm)" >&2
		return 1
	fi
	if ! read -r -p "$prompt" reply; then
		reply=
	fi
	while [[ $reply == *[$' \t\r\n'] ]]; do reply=${reply%?}; done
	if [[ $reply != yes ]]; then
		echo "menu: not confirmed"
		return 1
	fi
}

# Unlock, verity, and FRP. The word yes is not enough. spdhost asks again.
confirm_dangerous() {
	local prompt=$1 reply
	if [[ ! -t 0 ]]; then
		echo "DANGEROUS: refusing without a TTY. Typing yes is not accepted. Nothing sent." >&2
		return 1
	fi
	echo "DANGEROUS. The next step can leave the phone unable to boot or wipe FRP."
	echo "The word yes does nothing here."
	if ! read -r -p "$prompt" reply; then
		reply=
	fi
	while [[ $reply == *[$' \t\r\n'] ]]; do reply=${reply%?}; done
	if [[ $reply != dangerous ]]; then
		echo "menu: not confirmed; nothing sent"
		return 1
	fi
}

# Release-menu file. Not shipped in this tree. The rooted package keeps
# fdl2-cboot.bin next to fdl1-dl.bin (ums9230/infinix/) and gen_spl-unlock
# two directories above that, beside menu.sh. spl-unlock.bin is generated.
find_user_file() {
	local name=$1 d base
	local -a places=()
	base=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	places+=(
		"$PWD/$name"
		"$PWD/ums9230/infinix/$name"
		"$base/$name"
		"$base/../$name"
	)
	if [[ -n ${FDL1:-} ]]; then
		places+=("$(dirname "$FDL1")/$name")
		places+=("$(dirname "$FDL1")/../../$name")
	fi
	for d in "${places[@]}"; do
		if [[ -f $d ]]; then
			(cd "$(dirname "$d")" && printf '%s/%s\n' "$(pwd)" "$(basename "$d")")
			return 0
		fi
	done
	return 1
}

# aarch64 ELF from the release zip. PATH, then the same places as the files.
find_gen_spl_unlock() {
	local p
	p=$(command -v gen_spl-unlock 2>/dev/null || true)
	if [[ -n $p && -x $p ]]; then
		printf '%s\n' "$p"
		return 0
	fi
	p=$(find_user_file gen_spl-unlock || true)
	if [[ -n $p && -x $p ]]; then
		printf '%s\n' "$p"
		return 0
	fi
	return 1
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
# No --yes: the caller already took a typed "yes" (MISC_CONFIRM_TOKEN =
# sha256 of the bytes to write); it is passed once as --confirm-token and
# cleared, so it authorizes exactly this one misc write.
guarded_misc_session() {
	local kind=$1 ts backup raw rc want sz tok=$MISC_CONFIRM_TOKEN
	shift
	MISC_CONFIRM_TOKEN=
	if [[ ! $tok =~ ^[0-9a-f]{64}$ ]]; then
		echo "menu: not confirmed ($kind: no confirm token); nothing written" >&2
		return 1
	fi
	ts=$(date +%Y%m%d-%H%M%S)
	mkdir -p "$DUMP_DIR"
	backup="$DUMP_DIR/misc-before-$ts.img"
	raw=$(parts_cache_path)
	echo "misc will be backed up to $backup first; the write is skipped if that fails."
	ready || return 1
	run_session "--confirm-token=$tok" fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
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
	elif (( rc == 0 )); then
		echo "backup size $sz differs from the table ($want bytes). spdhost exited 0, so the write did happen. Backup kept: $backup" >&2
	else
		echo "misc backup missing or wrong size ($sz of $want bytes): the write was NOT done." >&2
		rm -f "$backup"
		rc=1
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
	echo "[0] Back"
	read -r -p "Choice: " choice
	case $choice in
		0) echo "Back to the menu."; pause; return ;;
		1|2|3|4|5|6) ;;
		*) echo "Unchanged."; pause; return ;;
	esac
	case $choice in
		1) continue_choice "reboot to system" || { pause; return; } ;;
		2) continue_choice "reboot to recovery" || { pause; return; } ;;
		3) continue_choice "reboot to fastbootd" || { pause; return; } ;;
		4) continue_choice "power off" || { pause; return; } ;;
		5) continue_choice "wipe userdata" || { pause; return; } ;;
		6) continue_choice "restore misc from a backup" || { pause; return; } ;;
	esac
	case $choice in
		1)
			echo "Normal reset after the loaders."
			if ! confirm_action "type yes to reboot to system: "; then
				pause
				return
			fi
			ready || { pause; return; }
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" reset
			;;
		2)
			echo "Writes 2048-byte recovery BCB to misc via reboot-recovery, then reset."
			if ! confirm_reboot_cmd reboot-recovery; then
				pause
				return
			fi
			# No --yes: the typed confirm above sets the scoped --confirm-token.
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
			if ! confirm_action "type yes to power off: "; then
				pause
				return
			fi
			ready || { pause; return; }
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
			# No --yes: token = sha256 of misc-wipe.bin, checked by spdhost.
			guarded_misc_session wipe-userdata write-part misc "$misc" reset
			;;
		6)
			restore_misc_menu
			;;
	esac
	pause
}

# Same skips as writecmd junk_file / *_bak, so the menu does not list a file
# the tool will ignore. Prefixes are on the filename, not the stripped name.
part_image_candidate() {
	local base=$1 name
	[[ $base == .* || -z $base ]] && return 1
	case $base in
		*.xml|*.exe|*.txt|*.partial|*.tmp|SHA256SUMS) return 1 ;;
		pgpt*|sprdpart*|fdl*|lk*|0x*|custom_exec*) return 1 ;;
	esac
	name=${base%.*}
	[[ $base == "$name" ]] && name=$base
	case $name in
		*_bak|misc-slotinfo|misc-before-*) return 1 ;;
	esac
	return 0
}

# Release menu option 2: every input/<partition>.img, then BOOT_AFTER.
flash_input_menu() {
	local -a names=() skipped=()
	local f base
	need_loaders || return
	mkdir -p "$INPUT_DIR"
	shopt -s nullglob
	for f in "$INPUT_DIR"/*.bin; do
		mv -n "$f" "${f%.bin}.img"
	done
	for f in "$INPUT_DIR"/*.img; do
		base=$(basename "$f")
		if part_image_candidate "$base"; then
			names+=("${base%.img}")
		else
			skipped+=("$base")
		fi
	done
	shopt -u nullglob
	if (( ${#names[@]} == 0 )); then
		echo "No partition images in $INPUT_DIR."
		echo "That folder is there now. Copy images into it, then choose this again."
		echo "Name each file after the partition: boot.img, vbmeta.img, l_fixnv1.img."
		return 1
	fi
	echo "Flash these images from $INPUT_DIR, then $BOOT_AFTER:"
	for f in "${names[@]}"; do
		echo "  $f"
	done
	if (( ${#skipped[@]} )); then
		echo "Not flashed: ${skipped[*]}"
	fi
	echo "Each file is written under its own name, including an inactive _a or _b image."
	echo "A name that is not on the phone is skipped. The other images are still written."
	echo "An empty image, or one larger than its partition, aborts the flash before anything is sent."
	echo "misc.img, if present, is backed up and verified."
	echo "This flash does not change the active slot and does not erase metadata."
	echo "splloader.img is written up to the live table size. With no splloader row, the file is sent whole (a dump is still 256 KiB)."
	echo "A broken l_fixnv1 image is skipped. A sparse image waits up to 100 seconds per chunk."
	echo "Then: $BOOT_AFTER. recovery/fastbootd writes a 2048-byte BCB after the images."
	echo "A same-size *_bak is written only when the device is not A/B. vbmeta flags are not edited."
	if ! confirm_action "type yes to flash these partitions: "; then
		return 1
	fi
	echo "spdhost asks once more on the terminal before it sends anything."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" write-files "$INPUT_DIR" "$BOOT_AFTER"
}

# Release menu option 4: write_parts of the backup folder.
restore_backup_menu() {
	need_loaders || return
	if [[ ! -d $DUMP_DIR ]]; then
		echo "No backup directory $DUMP_DIR."
		return 1
	fi
	echo "Restore images in $DUMP_DIR (partition-name.img), then $BOOT_AFTER."
	echo "Skipped: *.txt, SHA256SUMS, misc-slotinfo.img, misc-before-*.img, *_bak.img."
	echo "A name that is not on the phone is skipped. The other images are still written."
	echo "A broken l_fixnv1 image is skipped. An empty or oversized image aborts the restore before anything is sent."
	echo "splloader.img is written up to the live table size (a dump of it is still 256 KiB)."
	echo "userdata.img in this folder is written back. Inactive _a/_b images are skipped."
	echo "The active slot is written back after the files."
	echo "super.img without metadata.img erases metadata when that partition is on the phone."
	echo "Then: $BOOT_AFTER. recovery/fastbootd writes a 2048-byte BCB after the images."
	if ! confirm_action "type yes to restore this backup: "; then
		return 1
	fi
	echo "spdhost asks once more on the terminal before it sends anything."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" write-parts "$DUMP_DIR" "$BOOT_AFTER"
}

repartition_menu() {
	local xml
	need_loaders || return
	read -r -p "Partition XML path: " xml
	if [[ -z ${xml:-} || ! -f $xml ]]; then
		echo "No such file."
		return 1
	fi
	echo "Repartition replaces the on-device partition map. A wrong XML can brick the phone."
	echo "Entries:"
	grep -E 'Partition id=' "$xml" || true
	if ! confirm_action "type yes to repartition from this XML: "; then
		return 1
	fi
	echo "spdhost asks once more on the terminal before it sends the table."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		repartition "$xml" "$BOOT_AFTER"
}

set_slot_menu() {
	local which
	need_loaders || return
	echo "Set the active A/B slot. This rewrites 32 bytes at misc+0x800"
	echo "and then rewrites the whole misc partition (backup + read-back)."
	echo "[1] slot a"
	echo "[2] slot b"
	echo "[0] Back"
	read -r -p "Choice: " which
	case $which in
		0) echo "Back to the menu."; return 0 ;;
		1) which=a ;;
		2) which=b ;;
		*) echo "Unchanged."; return 1 ;;
	esac
	continue_choice "set the active slot to $which" || return
	if ! confirm_action "type yes to set the active slot to $which: "; then
		return 1
	fi
	echo "spdhost asks once more on the terminal after it has read misc."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" set-active "$which" "$BOOT_AFTER"
}

boot_after_menu() {
	local choice
	echo "What to do after a flash, restore, repartition, slot change, or dump."
	echo "Same four endings as the release menu."
	echo "Recovery and fastbootd write the 2048-byte BCB after the other work, then reset."
	echo "misc+0x800 (the slot) is past that 2048-byte write, so the slot stays."
	echo "Now: $BOOT_AFTER"
	echo "[1] system (reset)"
	echo "[2] recovery"
	echo "[3] fastbootd"
	echo "[4] power off"
	echo "[0] Back"
	read -r -p "Choice: " choice
	local next
	case $choice in
		0) echo "Back to the menu."; return ;;
		1) next=reset ;;
		2) next=reboot-recovery ;;
		3) next=reboot-fastboot ;;
		4) next=power-off ;;
		*) echo "Unchanged ($BOOT_AFTER)."; return ;;
	esac
	continue_choice "after flash/restore: $next" || return
	BOOT_AFTER=$next
	echo "After flash/restore/dump: $BOOT_AFTER."
}

hex_mode_menu() {
	local cur alt
	cur=$(exec_addr_value || true)
	echo "exec_addr now: ${cur:-disabled}."
	echo "Chip ${SOC:-ums9230}: primary stub $EXEC_ADDR_DEFAULT, second $EXEC_ADDR_ALT."
	echo "The second file is custom_exec_no_verify_$(printf '%x' "$((EXEC_ADDR_ALT))").bin."
	if exec_stub_present "$EXEC_ADDR_ALT"; then
		alt=$EXEC_ADDR_ALT
		if [[ ${cur,,} == "${alt,,}" ]]; then
			EXEC_ADDR=$EXEC_ADDR_DEFAULT
		else
			EXEC_ADDR=$alt
		fi
		save_config
		echo "exec_addr is now $(exec_addr_value)."
	else
		echo "Second stub is not on disk. Staying on $EXEC_ADDR_DEFAULT."
		# A saved alt address with no stub would fail every later session.
		if [[ ${cur,,} == "${EXEC_ADDR_ALT,,}" ]]; then
			EXEC_ADDR=$EXEC_ADDR_DEFAULT
			save_config
			echo "Saved exec_addr $EXEC_ADDR_DEFAULT."
		fi
	fi
}

# Release-menu unlock. fdl2-cboot.bin and spl-unlock.bin are not shipped.
# A missing dump does not continue into the erase. --dangerous is not passed.
unlock_bootloader_menu() {
	local cboot unlock genbin= work spl uboot slotf rc erase_rc=0
	cboot=$(find_user_file fdl2-cboot.bin || true)
	unlock=$(find_user_file spl-unlock.bin || true)
	genbin=$(find_gen_spl_unlock || true)
	if [[ -z $cboot || ( -z $unlock && -z $genbin ) ]]; then
		echo "DANGEROUS unlock: nothing sent."
		if [[ -z $cboot ]]; then
			echo "Missing fdl2-cboot.bin."
			echo "The release package has it next to fdl1-dl.bin (ums9230/infinix/) and in the menu directory."
			echo "This tree does not ship that file and does not invent it."
		fi
		if [[ -z $unlock && -z $genbin ]]; then
			echo "Missing spl-unlock.bin and gen_spl-unlock."
			echo "The release package has gen_spl-unlock beside its menu.sh. It builds spl-unlock.bin from the splloader backup."
			echo "This tree does not ship either file."
		fi
		return 1
	fi
	if [[ -z $unlock ]]; then
		echo "spl-unlock.bin is missing. $genbin runs after the backup, before the erase."
	else
		genbin=
	fi
	echo "DANGEROUS: Unlock BootLoader."
	echo "This follows the release menu: back up splloader and uboot, erase splloader"
	echo "and splloader_bak, write fdl2-cboot.bin to uboot, send spl-unlock.bin as FDL1"
	echo "(no FDL2), read 64 bytes at miscdata+8192, then write the backup back."
	echo "After the erase the phone will not boot until that last write."
	echo "Hold volume down and stay in download mode between the pauses."
	if ! confirm_dangerous "type dangerous to unlock the bootloader: "; then
		return 1
	fi
	need_loaders || return 1
	work=$PWD/backup_spl
	mkdir -p "$work"
	spl=$work/splloader.img
	if [[ ! -s $spl ]] || ! uboot=$(unlock_pick_uboot "$work"); then
		echo "Backing up splloader and uboot into $work. Nothing is erased in this session."
		echo "splloader is read as 256 KiB, the size the release menu's r splloader uses."
		ready || return 1
		rm -f "$work/dump-manifest.txt"
		if ! run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
			parts "$(parts_cache_path)" \
			read-part splloader 0 262144 "$spl" \
			dump uboot "$work" reset; then
			echo "Backup failed. splloader was not erased. Nothing further sent."
			return 1
		fi
		if [[ ! -s $spl ]] || ! uboot=$(unlock_pick_uboot "$work"); then
			echo "Backup files are missing. splloader was not erased. Nothing further sent."
			return 1
		fi
	else
		echo "Reusing $spl and $uboot. The erase still runs."
	fi
	if [[ -n $genbin ]]; then
		cp -f "$spl" "$work/splloader.bin"
		if ! ( cd "$work" && "$genbin" splloader.bin ); then
			echo "gen_spl-unlock failed. splloader was not erased."
			return 1
		fi
		unlock=$work/spl-unlock.bin
		if [[ ! -s $unlock ]]; then
			echo "gen_spl-unlock did not write spl-unlock.bin. splloader was not erased."
			return 1
		fi
	fi
	echo "DANGEROUS: next session erases splloader and splloader_bak, then reset."
	echo "spdhost asks for the word dangerous once. That answer covers both erases."
	echo "Any other answer sends nothing."
	echo "The backup stays in $work."
	pause || return 1
	ready || return 1
	erase_rc=0
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		danger-erase splloader danger-erase splloader_bak reset || erase_rc=$?
	if (( erase_rc != 0 )); then
		echo "Erase session failed (exit $erase_rc)."
		echo "The unlock loader is skipped. The last session still writes $work back."
	fi
	if (( erase_rc == 0 )); then
	echo "Next session writes $cboot onto uboot (the active slot name)."
	echo "spdhost asks you to type yes for that write."
	echo "A file larger than the uboot partition is refused, and the backup is written back."
	pause || return 1
	ready || return 1
	rc=0
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" write-part uboot "$cboot" reset || rc=$?
	if [[ $rc != 0 ]]; then
		echo "Modified uboot was not written (exit $rc). Skipping the unlock loader."
	else
		echo "Next session sends spl-unlock.bin as FDL1 and does not load FDL2."
		echo "The release menu treats a disconnect ('perangkat dilepas') as success."
		pause || return 1
		ready || return 1
		run_session fdl "$unlock" "$FDL1_ADDR" || \
			echo "Unlock loader returned non-zero. Continuing to the status read."
		echo "Next session reads 64 bytes at miscdata offset 8192."
		echo "Release-menu note: 64 zero bytes means locked; 32 bytes of text plus two 16-byte hashes means unlocked."
		echo "This tool prints the bytes. It does not decide the lock state beyond that note."
		pause || return 1
		ready || return 1
		slotf=$work/unlock-status.bin
		run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
			read-part miscdata 8192 64 "$slotf" reset || \
			echo "Status read failed."
		unlock_describe_status "$slotf"
	fi
	fi
	echo "Last session writes the dumped splloader and uboot back, then reset."
	echo "parts runs first so uboot is the active slot name, not the bare word uboot."
	echo "spdhost asks you to type yes for each of those writes."
	pause || return 1
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" \
		write-part splloader "$spl" write-part uboot "$uboot" reset
}

unlock_pick_uboot() {
	local d=$1 tag name pick=
	# The manifest names the image this dump actually wrote. An older
	# uboot_a.img left in the folder must not win over a new uboot.img.
	if [[ -f $d/dump-manifest.txt ]]; then
		while read -r tag name _; do
			[[ $tag == ok ]] || continue
			case $name in
				uboot|uboot_a|uboot_b)
					if [[ -s $d/$name.img ]]; then
						pick=$d/$name.img
					fi
					;;
			esac
		done < "$d/dump-manifest.txt"
	fi
	if [[ -n $pick ]]; then
		printf '%s\n' "$pick"
		return 0
	fi
	if [[ -s $d/uboot.img ]]; then printf '%s\n' "$d/uboot.img"; return 0; fi
	if [[ -s $d/uboot_a.img ]]; then printf '%s\n' "$d/uboot_a.img"; return 0; fi
	if [[ -s $d/uboot_b.img ]]; then printf '%s\n' "$d/uboot_b.img"; return 0; fi
	return 1
}

unlock_describe_status() {
	local f=$1 n
	if [[ ! -f $f ]]; then
		echo "No status file. Not calling the phone locked or unlocked."
		return 0
	fi
	n=$(wc -c < "$f" | tr -d ' ')
	echo "Status file: $f ($n bytes)."
	if [[ $n == 64 ]] && cmp -s "$f" <(dd if=/dev/zero bs=64 count=1 status=none 2>/dev/null); then
		echo "Release-menu note: 64 zero bytes means locked."
	elif [[ $n == 64 ]]; then
		echo "Release-menu note: 32 bytes of text plus two 16-byte hashes means unlocked."
		od -An -tx1 -N 64 "$f"
	else
		echo "Short or unexpected read. Not calling the phone locked or unlocked."
		od -An -tx1 -N 64 "$f" 2>/dev/null || true
	fi
}

verity_menu() {
	local which
	echo "DANGEROUS: dm-verity, the same byte spd_dump writes."
	echo "verity 0 writes 0x01 at offset 0x7B of vbmeta (the active slot name)."
	echo "verity 1 writes 0x00 at 0x7B of vbmeta, vbmeta_system, vbmeta_vendor,"
	echo "vbmeta_system_ext, vbmeta_product, and vbmeta_odm. A missing name is skipped."
	echo "This is not the AVB flag byte at offset 0x78. The whole partition is rewritten."
	echo "A partition over 64MB is refused and nothing is written."
	echo "[1] disable (verity 0)"
	echo "[2] enable (verity 1)"
	echo "[0] Back"
	read -r -p "Choice: " which
	case $which in
		0) echo "Back to the menu."; return 0 ;;
		1) which=0 ;;
		2) which=1 ;;
		*) echo "Unchanged. Nothing sent."; return 1 ;;
	esac
	continue_choice "verity $which" || return
	if ! confirm_dangerous "type dangerous to run verity $which: "; then
		return 1
	fi
	need_loaders || return 1
	echo "spdhost asks for the word dangerous again before it patches vbmeta."
	echo "Then: reset."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" verity "$which" reset
}

frp_reset_menu() {
	local out
	echo "DANGEROUS: Reset FRP."
	echo "Reads the whole persist partition (or persist_a / persist_b for the active slot)"
	echo "into a backup file, checks that file's size, then erases that partition, then reset."
	echo "A failed or short read does not erase. Factory reset still does not erase persist."
	echo "erase-part persist stays refused."
	echo "A persist image over 512MB is refused."
	if ! confirm_dangerous "type dangerous to reset FRP: "; then
		return 1
	fi
	need_loaders || return 1
	mkdir -p "$DUMP_DIR"
	out=$DUMP_DIR/persist-before-$(date +%Y%m%d-%H%M%S).img
	echo "Backup: $out"
	echo "spdhost asks for the word dangerous again before the read."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" frp-reset "$out" reset
}

extra_menu() {
	local choice
	echo "Extra"
	echo "[1] Factory reset (recovery wipe BCB; already on reboot menu)"
	echo "[2] Set active slot (a/b)"
	echo "[3] Power off"
	echo "[4] DANGEROUS: verity (vbmeta byte 0x7B; type the word dangerous)"
	echo "[5] DANGEROUS: reset FRP (backup persist, then erase it)"
	echo "[6] Reboot recovery"
	echo "[7] Reboot fastbootd"
	echo "[8] DANGEROUS: unlock bootloader (erases splloader until the last step)"
	echo "[9] Hex mode (exec_addr $EXEC_ADDR_DEFAULT / $EXEC_ADDR_ALT)"
	echo "[10] Boot mode after flash / restore (now: $BOOT_AFTER)"
	echo "[0] Back"
	read -r -p "Choice: " choice
	case $choice in
		0) echo "Back to the menu."; return ;;
		1) continue_choice "factory reset" || return ;;
		2) continue_choice "set the active slot" || return ;;
		3) continue_choice "power off" || return ;;
		4) continue_choice "verity" || return ;;
		5) continue_choice "FRP reset" || return ;;
		6) continue_choice "reboot to recovery" || return ;;
		7) continue_choice "reboot to fastbootd" || return ;;
		8) continue_choice "unlock the bootloader" || return ;;
		9) continue_choice "hex mode" || return ;;
		10) continue_choice "boot mode after flash / restore" || return ;;
		*) echo "Unchanged."; return ;;
	esac
	case $choice in
		1)
			echo "Factory reset is reboot menu [5]: shipped misc-wipe.bin, no persist erase."
			reboot_mode
			;;
		2) set_slot_menu ;;
		3)
			if confirm_action "type yes to power off: "; then
				ready || return
				run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" power-off
			fi
			;;
		4) verity_menu ;;
		5) frp_reset_menu ;;
		6)
			if confirm_reboot_cmd reboot-recovery; then
				guarded_misc_session reboot-recovery reboot-recovery
			fi
			;;
		7)
			if confirm_reboot_cmd reboot-fastboot; then
				guarded_misc_session reboot-fastboot reboot-fastboot
			fi
			;;
		8) unlock_bootloader_menu ;;
		9) hex_mode_menu ;;
		10) boot_after_menu ;;
	esac
}

# Test hook: SPDHOST_MENU_LIB=1 + `source menu.sh` loads functions only.
if [[ ${SPDHOST_MENU_LIB:-} == 1 ]]; then
	return 0 2>/dev/null || exit 0
fi

load_config
apply_ums9230_infinix_defaults
mkdir -p "$INPUT_DIR" || echo "Could not create $INPUT_DIR" >&2

while true; do
	cls
	echo "spdhost test menu"
	echo "wrapper: ${RUNNER[0]}"
	echo "FDL1: ${FDL1:-unset} ${FDL1_ADDR:-}"
	echo "FDL2: ${FDL2:-unset} ${FDL2_ADDR:-}"
	echo "Dumps go to: $DUMP_DIR"
	echo "Flash input: $INPUT_DIR"
	echo "After flash/restore: $BOOT_AFTER"
	echo
	echo "[1] Dump a partition (list + closest match + size, or imei)"
	echo "[2] Reboot into a mode"
	echo "[3] Change loader files (shipped models, or your own paths)"
	echo "[4] List partitions only"
	echo "[5] Smoke test (safe checks, no writes)"
	echo "[6] Flash images from $INPUT_DIR"
	echo "[7] Restore a backup folder"
	echo "[8] Repartition from XML"
	echo "[9] Extra (slot, hex mode, DANGEROUS unlock / verity / FRP)"
	echo "[0] Quit"
	echo "After a number: y continues, n goes back."
	read -r -p "Choice: " choice
	case ${choice:-} in
		1) continue_choice "dump a partition" || { pause; continue; }
			dump_partition ;;
		2) continue_choice "reboot into a mode" || { pause; continue; }
			reboot_mode ;;
		3) continue_choice "change loader files" || { pause; continue; }
			configure_loaders; pause ;;
		4) continue_choice "list partitions" || { pause; continue; }
			list_partitions_menu ;;
		5) continue_choice "smoke test" || { pause; continue; }
			smoke_test ;;
		6) continue_choice "flash images" || { pause; continue; }
			flash_input_menu; pause ;;
		7) continue_choice "restore a backup" || { pause; continue; }
			restore_backup_menu; pause ;;
		8) continue_choice "repartition" || { pause; continue; }
			repartition_menu; pause ;;
		9) continue_choice "extra menu" || { pause; continue; }
			extra_menu; pause ;;
		0) continue_choice "quit" && exit 0
			pause ;;
		*) echo "Not a choice."; pause ;;
	esac
done
