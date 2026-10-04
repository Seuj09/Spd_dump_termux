#!/usr/bin/env bash
# Test menu: dump one partition, or reboot into a mode.
# Loaders, addresses and the exec stub come from the chip/brand picked in
# option 3 (ums9230, ums512, sc9863a); no chip chosen = no exec stub.
set -u

CONFIG="${SPDHOST_MENU_CONFIG:-$HOME/.spdhost-menu.conf}"
# Filled in once this file's path is known. SPDHOST_DUMP_DIR wins, then a
# DUMP_DIR already set by the caller (tests), then shared storage, then
# backup/ beside fdl/.
DUMP_DIR_FROM_ENV="${SPDHOST_DUMP_DIR:-${DUMP_DIR:-}}"
DUMP_DIR="$DUMP_DIR_FROM_ENV"
INPUT_DIR_FROM_ENV="${SPDHOST_INPUT_DIR:-}"
# Where the images live, when shared storage is in play: <base>/Download,
# the phone's own download folder -- so a file a browser saved or a file
# manager copied is already where the tool reads, and a dump is already where
# the user looks for it. auto = shared storage if Termux can see it, package
# folders otherwise. SPDHOST_STORAGE= overrides the saved config, the way the
# other SPDHOST_ variables do; the config is only consulted when it is unset.
STORAGE_MODE=${SPDHOST_STORAGE:-auto}
case $STORAGE_MODE in
	auto|shared|package) ;;
	*)
		echo "note: SPDHOST_STORAGE=$STORAGE_MODE is not auto/shared/package; using auto." >&2
		STORAGE_MODE=auto
		;;
esac
STORAGE_MODE_FROM_ENV=${SPDHOST_STORAGE:-}
# The folder under the shared-storage base. Android's own download folder is
# "Download" (no s); the menu reads images from it and writes dumps to it.
SPDHOST_SHARED_NAME=Download
STORAGE_USED=""
# Set once apply_storage_mode has run and the folders were created; the menu
# prints it so the paths on screen are never a guess.
INPUT_DIR_PKG=""
DUMP_DIR_PKG=""
FDL1_ADDR_DEFAULT=0x65000800
FDL2_ADDR_DEFAULT=0x9efffe00
# BootROM exec_addr (spd_dump's no-verify stub path; see TERMUX.md). With it,
# FDL1 is started by fdl/ums9230/custom_exec_no_verify_65015f08.bin instead of
# BSL_CMD_EXEC_DATA, which the Infinix BootROM signature-checks and hangs on.
# SPDHOST_EXEC_ADDR=0 (or off) disables; any 0x... overrides. Also EXEC_ADDR=
# in the menu config. Environment wins over config. With no chip chosen (SOC
# unset) and neither set, there is NO stub (exec_addr_value).
EXEC_ADDR_DEFAULT=0x65015f08
# Release menu "hex mode 2" for ums9230. Both stubs ship (fdl/ums9230/
# custom_exec_no_verify_65015f08.bin and _65015f48.bin, byte-identical to the
# release package's copies); menu [9] switches between them.
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
# $PWD/input, which is created before the first prompt. These two are kept:
# the storage switch has to be able to come back here.
if [[ -d $script_dir/../fdl ]]; then
	INPUT_DIR_PKG=$(cd "$script_dir/.." && pwd)/input
	DUMP_DIR_PKG=$(cd "$script_dir/.." && pwd)/backup
elif [[ -d $script_dir/fdl ]]; then
	INPUT_DIR_PKG=$script_dir/input
	DUMP_DIR_PKG=$script_dir/backup
else
	INPUT_DIR_PKG=$PWD/input
	DUMP_DIR_PKG=$PWD/backup
fi
INPUT_DIR=${INPUT_DIR_FROM_ENV:-$INPUT_DIR_PKG}
DUMP_DIR=${DUMP_DIR_FROM_ENV:-$DUMP_DIR_PKG}
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

# Run a command under a wall-clock limit.
#
# `timeout` is used when present. The fallback is a bash watchdog rather than a
# bare exec, because termux-usb -l can block forever when the Termux:API app is
# missing or was killed by battery optimisation, and a bare fallback would turn
# a diagnostic probe into an unbounded hang. Never write this as
# `command -v timeout && timeout 5 cmd || cmd`: when the bounded call is present
# but merely *fails*, that form runs the unbounded one anyway.
bounded() {
	local t=$1 pid wd rc
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$t" "$@"
		return $?
	fi
	"$@" &
	pid=$!
	( sleep "$t"; kill -TERM "$pid" 2>/dev/null ) &
	wd=$!
	wait "$pid" 2>/dev/null
	rc=$?
	kill -TERM "$wd" 2>/dev/null
	wait "$wd" 2>/dev/null
	return $rc
}

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

# --------------------------------------------------------------- shared storage
# On a phone the images a user actually has -- a browser download, something a
# file manager copied, a zip another app extracted -- are on shared storage
# (/sdcard), and Termux cannot see any of it until `termux-setup-storage` has
# been run once and the permission allowed. So the flash and dump folders are
# picked like this:
#
#   SPDHOST_INPUT_DIR / SPDHOST_DUMP_DIR   wins outright (tests, power users)
#   STORAGE=package                        the folders beside fdl/ in the package
#   STORAGE=auto (default)                 <shared>/Download when shared
#                                          storage is visible and writable, the
#                                          package folders when it is not
#   STORAGE=shared                         shared storage, and say so when it
#                                          is missing instead of silently
#                                          using the package
#
# One folder, both directions: dumps are written to Download and flashes read
# from it, so the file menu [1] just wrote is the file menu [6] will flash.
#
# Nothing here is required: a phone with no storage permission keeps working
# out of the package, which is the only layout that needs no Android grant.

# The base directory Termux can actually read/write, or nothing. A plain -d is
# not enough: /sdcard is a mount point that exists whether or not the app has
# been granted storage, and a listing is what fails when it has not.
shared_storage_base() {
	local b
	# An explicit SPDHOST_SHARED_DIR is the whole answer, working or not:
	# a caller that names one path does not want the search falling through
	# to /sdcard behind its back. It is also how a test says "pretend this
	# phone has no shared storage" (point it at a path that is not there).
	if [[ -n ${SPDHOST_SHARED_DIR:-} ]]; then
		b=$SPDHOST_SHARED_DIR
		[[ -d $b && -w $b ]] && ls "$b" >/dev/null 2>&1 || return 1
		printf '%s\n' "$b"
		return 0
	fi
	for b in "$HOME/storage/shared" /sdcard /storage/emulated/0; do
		[[ -d $b ]] || continue
		ls "$b" >/dev/null 2>&1 || continue
		[[ -w $b ]] || continue
		printf '%s\n' "$b"
		return 0
	done
	return 1
}

# <base>/Download, the one folder this tool reads images from and writes dumps
# to. A file manager can find it, and a browser download already lands in it.
shared_storage_root() {
	local base
	base=$(shared_storage_base) || return 1
	printf '%s/%s\n' "${base%/}" "$SPDHOST_SHARED_NAME"
}

# Recompute INPUT_DIR/DUMP_DIR from STORAGE_MODE and create the folder.
# Called at startup, and again when the storage switch changes the mode.
# Both point at the same folder unless the caller overrode one of them.
apply_storage_mode() {
	local root
	INPUT_DIR=${INPUT_DIR_FROM_ENV:-$INPUT_DIR_PKG}
	DUMP_DIR=${DUMP_DIR_FROM_ENV:-$DUMP_DIR_PKG}
	STORAGE_USED=""
	[[ $STORAGE_MODE == package ]] && return 0
	root=$(shared_storage_root) || root=""
	if [[ -z $root ]]; then
		if [[ $STORAGE_MODE == shared ]]; then
			echo "note: STORAGE=shared, but Termux cannot see shared storage." >&2
			echo "      Run termux-setup-storage once and allow the permission;" >&2
			echo "      using the package folders for now." >&2
		fi
		return 0
	fi
	if ! mkdir -p "$root" 2>/dev/null; then
		echo "note: could not create $root; using the package folders." >&2
		return 0
	fi
	[[ -n $INPUT_DIR_FROM_ENV ]] || INPUT_DIR=$root
	[[ -n $DUMP_DIR_FROM_ENV ]] || DUMP_DIR=$root
	STORAGE_USED=$root
	return 0
}

# One line for the header: which layout is in use and where it is.
storage_describe() {
	if [[ -n $INPUT_DIR_FROM_ENV || -n $DUMP_DIR_FROM_ENV ]]; then
		printf 'set by SPDHOST_INPUT_DIR / SPDHOST_DUMP_DIR'
		return
	fi
	if [[ -n $STORAGE_USED ]]; then
		printf 'shared storage (%s)' "$STORAGE_USED"
	elif [[ $STORAGE_MODE == package ]]; then
		printf 'package folders (STORAGE=package)'
	elif [[ $STORAGE_MODE == shared ]]; then
		printf 'package folders: shared storage is not visible (STORAGE=shared)'
	else
		printf 'package folders, no shared storage'
	fi
}

# [15] Switch between the two layouts. Writes the choice to the menu config
# and re-applies it now, so the paths change without a restart.
storage_switch_menu() {
	local choice root
	echo "Where the flash and dump folders live."
	echo "  flash: $INPUT_DIR"
	echo "  dump:  $DUMP_DIR"
	echo "  now:   $(storage_describe)"
	echo
	root=$(shared_storage_root) || root=""
	if [[ -n $root ]]; then
		echo "[1] Shared storage: $root  (dumps land here; flashes read here)"
	else
		echo "[1] Shared storage: not visible. Run termux-setup-storage and allow it."
	fi
	echo "[2] Package folders: $INPUT_DIR_PKG and $DUMP_DIR_PKG"
	echo "[0] Back"
	read -r -p "Choice: " choice
	case ${choice:-} in
		1)
			STORAGE_MODE=shared
			;;
		2)
			STORAGE_MODE=package
			;;
		0|'') echo "Unchanged."; return 0 ;;
		*) echo "Not a choice."; return 1 ;;
	esac
	if [[ -n $INPUT_DIR_FROM_ENV || -n $DUMP_DIR_FROM_ENV ]]; then
		echo "note: SPDHOST_INPUT_DIR / SPDHOST_DUMP_DIR is set and still wins."
	fi
	apply_storage_mode
	mkdir -p "$INPUT_DIR" 2>/dev/null || echo "note: could not create $INPUT_DIR" >&2
	mkdir -p "$DUMP_DIR" 2>/dev/null || echo "note: could not create $DUMP_DIR" >&2
	save_config
	echo "Flash folder: $INPUT_DIR"
	echo "Dump folder:  $DUMP_DIR"
	echo "Saved to $CONFIG."
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
BOOT_AFTER=$BOOT_AFTER
STORAGE=$STORAGE_MODE
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
			BOOT_AFTER)
				# Allowlist, not a free-form word: this value is passed to
				# run_session as a command argument.
				[[ $val =~ ^(reset|reboot-recovery|reboot-fastboot|power-off)$ ]] && BOOT_AFTER=$val
				;;
			STORAGE)
				# Allowlist: this picks between two path layouts, and
				# anything else is not a third one. SPDHOST_STORAGE=
				# wins over what is saved here.
				[[ -z $STORAGE_MODE_FROM_ENV && $val =~ ^(auto|shared|package)$ ]] && STORAGE_MODE=$val
				;;
		esac
	done < "$CONFIG"
	# Hex mode's second address depends on the chip. File paths stay as saved.
	# config_chip_check then repairs (or refuses) a chip/address mix.
	if [[ -n $SOC ]]; then
		soc_profile "$SOC" || true
	fi
	config_chip_check
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

# SoC named by a loader path, or nothing. This tree stores loaders as
# fdl/<soc>/[<brand>/[alternatif/<model>/]]... (see shipped_fdl_pair), so the
# first segment under fdl/ is the chip the bytes belong to. A typed path that
# does not have that shape names no chip.
path_soc() {
	local p=$1 seg
	[[ -n $p ]] || return 0
	case $p in
		*/fdl/*) seg=${p#*/fdl/} ;;
		fdl/*)   seg=${p#fdl/} ;;
		*) return 0 ;;
	esac
	seg=${seg%%/*}
	case $seg in ums9230|ums512|sc9863a) printf '%s\n' "$seg" ;; esac
	return 0
}

# SoC whose exec stub is at this address, or nothing. The table is spelled out
# rather than read from soc_profile's globals, because soc_profile overwrites
# them for whichever chip was asked for last and this is called to compare one
# address against every chip at once.
exec_soc_name() {
	local a=$1
	a=${a,,}
	a=${a#0x}
	case $a in
		65015f08|65015f48) printf '%s\n' ums9230 ;;
		3ee8|3f48)          printf '%s\n' ums512 ;;
		4ee8|4f48)          printf '%s\n' sc9863a ;;
	esac
	return 0
}

# The saved config keeps the chip and its loader addresses as independent
# fields, but FDL1_ADDR, FDL2_ADDR and the exec stub address are all a pure
# function of the chip. A file left over from another chip can therefore name
# one chip and carry another's addresses -- ums9230 Infinix loaders with
# sc9863a's 0x5000/0x4ee8 -- which sends a loader and a stub built for
# different chips. That is a brick, so it is caught here, before any session.
#
# The loader path decides, because it is evidence: a path naming a different
# known chip than SOC is refused outright (guessing which field is stale is how
# you brick a phone -- pick option 3 instead), and when SOC is empty the path
# supplies the chip instead of leaving the question open. When the paths name
# no chip, SOC wins. Either way each address field the file got wrong is
# replaced, with a note.
CONFIG_CHIP_ERROR=""
config_chip_check() {
	local ps1 ps2 ps soc_f1 soc_f2
	CONFIG_CHIP_ERROR=""
	ps1=$(path_soc "${FDL1:-}")
	ps2=$(path_soc "${FDL2:-}")
	# Two loaders from two different chips are already a mixed pair, whether or
	# not SOC agrees with one of them. Nothing can be derived from that, so it
	# is refused the same way.
	if [[ -n $ps1 && -n $ps2 && $ps1 != "$ps2" ]]; then
		CONFIG_CHIP_ERROR="FDL1 is ${ps1}'s and FDL2 is ${ps2}'s"
		{
			echo "config $CONFIG is inconsistent:"
			echo "  FDL1=$FDL1"
			echo "  FDL2=$FDL2"
			echo "The two loader paths name different chips (${ps1} and ${ps2}), so they are not a pair."
			echo "Refusing all sessions until that is fixed: option 3 re-picks the loaders."
		} >&2
		return 0
	fi
	ps=${ps1:-$ps2}	# the chip the paths name, if any
	if [[ -n ${SOC:-} ]]; then
		soc_profile "$SOC" || return 0 # unknown chip: leave the file's values alone
		if [[ -n $ps && $ps != "$SOC" ]]; then
			CONFIG_CHIP_ERROR="SOC=$SOC but the loaders are $ps"
			{
				echo "config $CONFIG is inconsistent:"
				echo "  SOC=$SOC"
				echo "  FDL1=${FDL1:-none}"
				echo "  FDL2=${FDL2:-none}"
				echo "The loader path says these loaders are $ps's, so using them with $SOC's addresses would send a loader and an exec stub for different chips."
				echo "Refusing all sessions until that is fixed: option 3 re-picks the loaders."
			} >&2
			return 0
		fi
	elif [[ -n $ps ]]; then
		# No chip in the config, but the loader path names one. Adopt it: the
		# addresses below are then checked against the chip the loaders really
		# are, instead of nothing being checked at all.
		soc_profile "$ps" || return 0
		SOC=$ps
		echo "config: no chip was set; the loader path says these are $ps's, so that is the chip now." >&2
	else
		return 0	# no chip anywhere: nothing to derive the addresses from
	fi
	soc_f1=$SOC_FDL1_ADDR
	soc_f2=$SOC_FDL2_ADDR
	if [[ -n ${FDL1_ADDR:-} && ${FDL1_ADDR,,} != "${soc_f1,,}" ]]; then
		echo "config: FDL1_ADDR=$FDL1_ADDR is not $SOC's $soc_f1; using $soc_f1." >&2
		FDL1_ADDR=$soc_f1
	fi
	if [[ -n ${FDL2_ADDR:-} && ${FDL2_ADDR,,} != "${soc_f2,,}" ]]; then
		echo "config: FDL2_ADDR=$FDL2_ADDR is not $SOC's $soc_f2; using $soc_f2." >&2
		FDL2_ADDR=$soc_f2
	fi
	# 0/off is a deliberate "no exec stub", not a stale address, so it stands.
	case ${EXEC_ADDR,,} in
		''|0|0x0|off) ;;
		*)
			if [[ ${EXEC_ADDR,,} != "${EXEC_ADDR_DEFAULT,,}" &&
			      ${EXEC_ADDR,,} != "${EXEC_ADDR_ALT,,}" ]]; then
				echo "config: EXEC_ADDR=$EXEC_ADDR is not $SOC's $EXEC_ADDR_DEFAULT; using $EXEC_ADDR_DEFAULT." >&2
				EXEC_ADDR=$EXEC_ADDR_DEFAULT
			fi
			;;
	esac
	return 0
}

soc_brands() {
	case $1 in
		# universal is appended LAST on purpose: the numeric brand index is
		# what select_shipped_model maps a choice back to, and tests (and
		# muscle memory) depend on 1=infinix staying 1=infinix.
		ums9230) printf '%s\n' infinix itel realme tecno universal ;;
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
		"$HOME/spreadtrum_flash_termux/misc"
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
	local dir reply ps1 ps2
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
	# What goes into the session has to be one chip end to end. A loader already
	# set for a different chip must not be kept alongside the ums9230 pair, and
	# the addresses are not back-filled field by field either: SOC, the exec
	# stub and both addresses all follow from the ums9230 pair the user just
	# confirmed (select_shipped_model assigns them the same way).
	ps1=$(path_soc "${FDL1:-}")
	ps2=$(path_soc "${FDL2:-}")
	if [[ -n $ps1 && $ps1 != ums9230 ]] || [[ -n $ps2 && $ps2 != ums9230 ]]; then
		echo "${FDL1:-}/$FDL2 are ${ps1:-$ps2} loaders, not ums9230 ones." >&2
		echo "Use option 3 to set the loaders for your chip." >&2
		return 0
	fi
	[[ -n $FDL1 ]] || FDL1=$dir/fdl1-dl.bin
	[[ -n $FDL2 ]] || FDL2=$dir/fdl2-dl.bin
	FDL1_ADDR=$FDL1_ADDR_DEFAULT
	FDL2_ADDR=$FDL2_ADDR_DEFAULT
	if soc_profile ums9230; then
		SOC=ums9230
		EXEC_ADDR=$EXEC_ADDR_DEFAULT
	fi
	CONFIG_CHIP_ERROR=""
}

# Apply the shipped "universal" set: the generic ums9230 loaders, for a phone
# whose model the user does not know. Same guard rails as select_shipped_model:
# the addresses are a function of the chip, so all five fields move together.
wizard_apply_universal() {
	local root pair=()
	root=$(pkg_fdl_root) || { echo "No fdl/ directory next to this menu." >&2; return 1; }
	mapfile -t pair < <(shipped_fdl_pair "$root" ums9230 universal || true)
	if ((${#pair[@]} != 2)); then
		echo "The universal ums9230 loaders are missing from fdl/ums9230/universal/." >&2
		return 1
	fi
	soc_profile ums9230 || return 1
	echo "  ${pair[0]} @ $SOC_FDL1_ADDR"
	echo "  ${pair[1]} @ $SOC_FDL2_ADDR"
	echo "  exec stub $EXEC_ADDR_DEFAULT"
	echo "A wrong chip or address can brick the phone."
	if ! confirm_action "type yes to use the universal loaders: "; then
		return 1
	fi
	FDL1=${pair[0]}
	FDL2=${pair[1]}
	FDL1_ADDR=$SOC_FDL1_ADDR
	FDL2_ADDR=$SOC_FDL2_ADDR
	SOC=ums9230
	DEVICE=universal
	EXEC_ADDR=$EXEC_ADDR_DEFAULT
	CONFIG_CHIP_ERROR=""
	save_config
	echo "Saved $SOC $DEVICE to $CONFIG"
}

# Asked once at startup, before the menu, when no loaders are configured yet.
# The user's own words: the menu starts by asking for the phone details and
# the FDLs, with the generic set offered as "universal".
#
# Silent when it must be:
#   - a complete config is already saved, so this is a first-run question only;
#   - SPDHOST_ALLOW_DEFAULT_FDL=1 asks for the old non-interactive default;
#   - stdin is not a terminal, so a piped or </dev/null run reaches the menu
#     and its "Input closed" exit instead of blocking on a prompt.
setup_wizard() {
	local choice
	if [[ -n ${FDL1:-} && -f $FDL1 && -n ${FDL1_ADDR:-} &&
	      -n ${FDL2:-} && -f $FDL2 && -n ${FDL2_ADDR:-} ]]; then
		return 0
	fi
	if [[ ${SPDHOST_ALLOW_DEFAULT_FDL:-} == 1 ]]; then
		apply_ums9230_infinix_defaults
		return 0
	fi
	[[ -t 0 ]] || return 0
	echo "Phone setup. Which loaders does this phone use?"
	if [[ -n ${FDL1:-} || -n ${FDL2:-} ]]; then
		echo "  now: FDL1=${FDL1:-unset} FDL2=${FDL2:-unset} chip=${SOC:-unset} (${DEVICE:-no model})"
	else
		echo "  now: no loaders set"
	fi
	echo "[1] universal (generic ums9230; try this if you do not know the model)"
	echo "[2] pick a shipped model by chip and brand"
	echo "[3] type my own loader paths and addresses"
	echo "[0] skip for now (it asks again next time; menu [3] also sets this)"
	echo "Until a loader pair is saved, every session that needs one will ask"
	echo "for it. Set SPDHOST_ALLOW_DEFAULT_FDL=1 to apply the shipped Infinix"
	echo "pair silently instead of asking at all."
	if ! read -r -p "Choice [1]: " choice; then
		echo "Skipped (no input)."
		return 0
	fi
	case ${choice:-1} in
		1) wizard_apply_universal ;;
		2) select_shipped_model ;;
		3) configure_loaders_manual ;;
		0) echo "Skipped. Menu [3] sets the loaders later." ;;
		*) echo "Not a choice. Skipped; menu [3] sets the loaders later." ;;
	esac
	return 0
}

# Both askers return 1 on EOF (Ctrl-D, or stdin that is not a terminal) instead
# of re-prompting: read leaves the variable empty at EOF, so the old loop treated
# a closed stdin as an endless run of invalid answers and spun forever.
ask_addr() {
	local prompt=$1 reply
	while true; do
		if ! read -r -p "$prompt " reply; then
			echo "Cancelled (no input)." >&2
			return 1
		fi
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
		if ! read -r -e -p "$prompt " reply; then
			echo "Cancelled (no input)." >&2
			return 1
		fi
		if [[ -f $reply ]]; then
			printf '%s\n' "$reply"
			return 0
		fi
		echo "No such file: $reply" >&2
	done
}

configure_loaders_manual() {
	local choice ea nf1 na1 nf2 na2 ps1 ps2 cur who
	echo "Loader files and load addresses for this chip."
	echo "These are the same FDL1/FDL2 pair the rooted menu uses. A wrong address can brick the phone."
	# Collect into locals and commit only once all four answers are in: an
	# abort part-way (Ctrl-D) used to leave FDL1/FDL2/addresses half-updated,
	# and the save_config below then wrote that half-state over a working config.
	nf1=$(ask_file "FDL1 file:") || return 1
	na1=$(ask_addr "FDL1 address:") || return 1
	nf2=$(ask_file "FDL2 file:") || return 1
	na2=$(ask_addr "FDL2 address:") || return 1
	# L6: the chip question is mandatory. It used to default (Enter) to
	# "keep whatever stub is set", which with no chip saved meant the ums9230
	# stub 0x65015f08 -- sent before FDL1 on any chip. Now every answer names
	# a chip, or says outright that there is no stub.
	echo "Which chip are these loaders for? This picks the exec stub."
	echo "A stub from the wrong chip is sent before FDL1 and can brick the phone."
	echo "[1] ums9230 (FDL1 0x65000800)   [2] sc9863a (FDL1 0x5000)   [3] ums512 (FDL1 0x5500)"
	echo "[4] another chip: no exec stub (plain BSL EXEC)"
	while true; do
		if ! read -r -p "Choice (required): " choice; then
			echo "Cancelled (no input); nothing saved." >&2
			return 1
		fi
		case $choice in
			1|2|3|4) break ;;
			*) echo "Pick 1, 2, 3 or 4." >&2 ;;
		esac
	done
	case $choice in
		1) soc_profile ums9230 ;;
		2) soc_profile sc9863a ;;
		3) soc_profile ums512 ;;
	esac
	# M4: FDL1's address is a function of the chip; a mix is refused, not saved.
	if [[ $choice != 4 && $(( na1 )) != $(( SOC_FDL1_ADDR )) ]]; then
		echo "Refusing: FDL1 address $na1 does not go with that chip (its FDL1 loads at $SOC_FDL1_ADDR)." >&2
		echo "Nothing saved. Use option 3's shipped models, or type the chip's own address." >&2
		return 1
	fi
	FDL1=$nf1
	FDL1_ADDR=$na1
	FDL2=$nf2
	FDL2_ADDR=$na2
	case $choice in
		1) SOC=ums9230; EXEC_ADDR=$EXEC_ADDR_DEFAULT ;;
		2) SOC=sc9863a; EXEC_ADDR=$EXEC_ADDR_DEFAULT ;;
		3) SOC=ums512; EXEC_ADDR=$EXEC_ADDR_DEFAULT ;;
		4) SOC=""; EXEC_ADDR=0 ;;
	esac
	ea=$(exec_addr_value || true)
	# Last chance to notice a mix, before it is written to the config and used.
	# Both the path and the exec stub can name a chip; nothing here is refused
	# (the user typed these values), so it is said out loud instead.
	ps1=$(path_soc "$nf1")
	ps2=$(path_soc "$nf2")
	if [[ -n $ps1 && -n $ps2 && $ps1 != "$ps2" ]]; then
		echo "warning: $nf1 is ${ps1}'s and $nf2 is ${ps2}'s." >&2
	fi
	ps1=${ps1:-$ps2}
	who=$(exec_soc_name "$ea")
	if [[ -n $ps1 && -n $SOC && $SOC != "$ps1" ]]; then
		echo "warning: the loaders are ${ps1}'s but you picked $SOC." >&2
	fi
	if [[ -n $ps1 && -n $who && $who != "$ps1" ]]; then
		echo "warning: exec_addr ${ea} is ${who}'s stub but the loaders are ${ps1}'s." >&2
	fi
	CONFIG_CHIP_ERROR=""
	save_config
	echo "Saved $CONFIG (chip ${SOC:-unset}, exec ${ea:-disabled})"
}

# Shipped fdl1-dl.bin + fdl2-dl.bin for one release-menu model.
# Prints two lines: fdl1 path, fdl2 path. Model is empty for the brand pair,
# or a subdirectory name under alternatif/ (the release spelling "alternativ"
# is accepted too).
shipped_fdl_pair() {
	# model is the optional fourth argument ("main pair" = no model). Written
	# with :- because this file runs under set -u: a caller that leaves it off
	# would otherwise abort the whole menu with "unbound variable" instead of
	# getting the main pair.
	local root=$1 soc=$2 brand=$3 model=${4:-} dir
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
	local had_nullglob=0
	# Save/restore: a caller (flash_input_menu, restore_image_names) may already
	# have nullglob on, and blanket `shopt -u` here would silently change how
	# its own globs behave for the rest of that function.
	shopt -q nullglob && had_nullglob=1
	shopt -s nullglob
	for d in "$root/$soc/$brand/alternatif"/*/ "$root/$soc/$brand/alternativ"/*/; do
		[[ -f ${d}fdl1-dl.bin && -f ${d}fdl2-dl.bin ]] || continue
		base=$(basename "$d")
		found+=("$base")
	done
	(( had_nullglob )) || shopt -u nullglob
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
		if [[ $brand == universal ]]; then
			echo "[$n] universal (generic; try this if you do not know the model)"
		else
			echo "[$n] $brand"
		fi
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
	mapfile -t pair < <(shipped_fdl_pair "$root" "$soc" "$brand" "$model" || true)
	if ((${#pair[@]} != 2)); then
		echo "That pair is not in fdl/."
		return 1
	fi
	# soc_profile mutates the live chip globals (SOC_FDL1_ADDR/SOC_FDL2_ADDR/
	# EXEC_ADDR_DEFAULT/EXEC_ADDR_ALT), and it has to run before the confirm
	# below so the addresses can be shown. Declining must put them back, or the
	# menu would keep the rejected chip's exec stub live -- hex_mode_menu would
	# then toggle to it and save_config would persist it. Captured BEFORE the
	# call, and with :- because SOC_FDL*_ADDR are unset until some profile runs.
	local old_fdl1=${SOC_FDL1_ADDR:-} old_fdl2=${SOC_FDL2_ADDR:-}
	local old_exec=$EXEC_ADDR_DEFAULT old_alt=$EXEC_ADDR_ALT
	soc_profile "$soc" || return 1
	echo "  ${pair[0]} @ $SOC_FDL1_ADDR"
	echo "  ${pair[1]} @ $SOC_FDL2_ADDR"
	echo "  exec stub $EXEC_ADDR_DEFAULT"
	echo "A wrong chip or address can brick the phone."
	if ! confirm_action "type yes to use these loaders: "; then
		SOC_FDL1_ADDR=$old_fdl1
		SOC_FDL2_ADDR=$old_fdl2
		EXEC_ADDR_DEFAULT=$old_exec
		EXEC_ADDR_ALT=$old_alt
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
	# A config that pairs one chip's loaders with another chip's addresses must
	# not reach a session: config_chip_check() explains what is wrong at load
	# time, and this is what stops every option until option 3 fixes it.
	if [[ -n ${CONFIG_CHIP_ERROR:-} ]]; then
		echo "Refusing: $CONFIG_CHIP_ERROR."
		echo "Option 3 re-picks the loaders; the explanation is in the config warning above."
		return 1
	fi
	if [[ -f $FDL1 && -n $FDL1_ADDR && -f $FDL2 && -n $FDL2_ADDR ]]; then
		return 0
	fi
	echo "Set the loader files first."
	configure_loaders || return 1
	# configure_loaders also returns 0 on its "Back" and "Unchanged." arms, so
	# its status alone is not proof the user picked anything: backing out used
	# to return 0 here and every option then built a session with an empty
	# FDL1 path ("open : No such file") instead of stopping. Re-check the four
	# fields, which is the only thing this gate actually promises.
	if [[ -f $FDL1 && -n $FDL1_ADDR && -f $FDL2 && -n $FDL2_ADDR ]]; then
		return 0
	fi
	echo "Still no loader files; option 3 picks them." >&2
	return 1
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
	echo "Only after it says 'Plug the target in NOW', hold the download-mode keys and connect the cable"
	echo "(volume down on most Unisoc phones; some use volume up, both volume keys, or a boot key)."
	echo "Tap OK on the permission dialog as soon as it appears."
	echo "The first try often misses the BootROM window. Unplug, run the same action, and plug in again."
	echo "Cold-unplug ≥5 s between sessions. Success once does not make later tries stickier without a replug."
	pause
}

# Effective exec_addr: env SPDHOST_EXEC_ADDR, else config EXEC_ADDR, else the
# chip's default -- and with no chip (SOC unset) none at all. Prints nothing
# when disabled (0/off/empty).
exec_addr_value() {
	local v
	if [[ -n ${SPDHOST_EXEC_ADDR+set} ]]; then
		v=$SPDHOST_EXEC_ADDR
	elif [[ -n $EXEC_ADDR ]]; then
		v=$EXEC_ADDR
	elif [[ -n ${SOC:-} ]]; then
		v=$EXEC_ADDR_DEFAULT
	else
		# L6: no chip chosen, no stub. The old default was ums9230's
		# 0x65015f08 whatever the phone was.
		v=0
	fi
	case $v in
		''|0|off|OFF|0x0|0X0) return 0 ;;
	esac
	printf '%s\n' "$v"
}

# custom_exec_no_verify_<hex>.bin for exec_addr, same name spdhost looks up.
# Fail here, before the plug-in wait, when the stub is not on disk or does not
# go with the chosen chip / FDL1 address. Prints the path on stdout; the
# caller passes it to spdhost as exec_addr's FILE.
exec_stub_path() {
	local ea=$1 hex name d chip here
	local -a places=()
	hex=$(printf '%x' "$((ea))" 2>/dev/null) || return 1
	name="custom_exec_no_verify_${hex}.bin"
	# L6: a stub is looked up only under fdl/<its chip>/. The chip is the one
	# the address belongs to; a chosen SOC that disagrees is refused (M4).
	chip=$(exec_soc_name "$ea")
	if [[ -z $chip ]]; then
		echo "no $name: exec_addr $ea is no shipped chip's stub address (stubs live in fdl/<chip>/)." >&2
		echo "Set SPDHOST_EXEC_ADDR=0 to use BSL EXEC, or pick the chip in option 3." >&2
		return 1
	fi
	if [[ -n ${SOC:-} && $SOC != "$chip" ]]; then
		echo "refusing: exec_addr $ea is the $chip stub but the chip is $SOC (option 3)." >&2
		return 1
	fi
	# G3: no chip picked means no stub. A saved EXEC_ADDR alone (hex mode used
	# to save ums9230's second stub for any FDL1 at 0x65000800, which newer
	# chips share) is not a reason to send a BootROM stub. SPDHOST_EXEC_ADDR
	# is the explicit expert override and is still honoured.
	if [[ -z ${SOC:-} && -z ${SPDHOST_EXEC_ADDR+set} ]]; then
		echo "refusing: exec_addr $ea is the $chip stub, but no chip is picked (option 3)." >&2
		echo "Pick the chip in option 3, set EXEC_ADDR to 0 there ([4] another chip), or set SPDHOST_EXEC_ADDR to send it anyway." >&2
		return 1
	fi
	if [[ -n ${FDL1_ADDR:-} ]] && soc_fdl1_for "$chip" >/dev/null &&
	   (( FDL1_ADDR != $(soc_fdl1_for "$chip") )); then
		echo "refusing: exec_addr $ea is the $chip stub, which goes with FDL1 at $(soc_fdl1_for "$chip"), not $FDL1_ADDR." >&2
		return 1
	fi
	here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	places+=("$here/../fdl/$chip/$name" "$PWD/fdl/$chip/$name")
	if [[ -n ${RUNNER[0]:-} ]]; then
		places+=("$(dirname "${RUNNER[0]}")/../fdl/$chip/$name")
	fi
	for d in "${places[@]}"; do
		if [[ -f $d ]]; then
			printf '%s\n' "$d"
			return 0
		fi
	done
	echo "missing $name for exec_addr $ea." >&2
	echo "Put it in fdl/$chip/, or set SPDHOST_EXEC_ADDR=0 to use BSL EXEC." >&2
	return 1
}

# FDL1 load address of a chip (the soc_profile table), without touching the
# soc_profile globals.
soc_fdl1_for() {
	case $1 in
		ums9230) echo 0x65000800 ;;
		ums512) echo 0x5500 ;;
		sc9863a) echo 0x5000 ;;
		*) return 1 ;;
	esac
}

# The check on its own, for callers that only want "is it there?" (hex mode,
# the package test): the path goes to /dev/null, the guidance still shows.
exec_stub_present() { exec_stub_path "$@" >/dev/null; }

run_session() {
	local -a prefix=(--timeout "${SPDHOST_TIMEOUT:-3000}")
	local ea stub
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
	# Every BootROM fdl flow starts with FDL1: put exec_addr in front of it,
	# with the stub's own path from fdl/<chip>/ (exec_stub_path).
	if [[ ${1:-} == fdl ]]; then
		ea=$(exec_addr_value) || ea=
		if [[ -n $ea ]]; then
			stub=$(exec_stub_path "$ea") || return 1
			set -- exec_addr "$ea" "$stub" "$@"
		fi
	fi
	# spdhost leaves partition_<unixtime>.xml behind every time it reads the
	# partition table, the way spd_dump does -- but into the folder we point it
	# at, so it lands with the dumps instead of in whatever directory the menu
	# ran from. That is the file a repartition edit is made from, and having it
	# appear without asking is the point. SPDHOST_PART_XML_DIR= (empty) turns
	# the copy off for a caller that does not want it.
	local -x SPDHOST_PART_XML_DIR="${SPDHOST_PART_XML_DIR-$DUMP_DIR}"
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

# The unit of the "name units" rows. spdhost (G1) writes it as the file's first
# line, "# spdhost-parts shift S verified V [corrected 1]", from the table it
# actually read: the divisor it used, a GPT's byte sizes, or the shift its size
# probe corrected the table to. That line is the only source used when it is
# there. Without it (an older spdhost) the divisor loop below re-derives it
# like spd_dump partition_list() (common.c ~1106-1116): divisor starts at 10 and
# drops until every non-zero entry >> divisor is non-zero; bytes = units <<
# (20 - divisor). That guess halves every row of a GPT whose smallest row is
# 2 MiB, which is why the header exists.
# PARTS_VERIFIED: 1 = the sizes are known good, 0 = the unit is a guess the
# device did not confirm (spdhost's `dump` then sizes each row by the device),
# "" = no header (older spdhost; only shift 10 is a known unit).
# PARTS_CORRECTED: 1 when spdhost re-scaled the table to the probe's answer.
# RAW (units) -> OUT (bytes). Always derived from RAW, so it is idempotent.
PARTS_VERIFIED=""
PARTS_CORRECTED=""
parts_units_to_bytes() {
	local raw=$1 out=$2 name size div=10 tmp ushift="" line
	PARTS_VERIFIED=""
	PARTS_CORRECTED=""
	IFS= read -r line < "$raw" || line=
	if [[ $line =~ ^\#\ spdhost-parts\ shift\ ([0-9]+)\ verified\ ([01])(\ corrected\ 1)?[[:space:]]*$ ]] &&
		(( BASH_REMATCH[1] <= 30 )); then
		ushift=${BASH_REMATCH[1]}
		PARTS_VERIFIED=${BASH_REMATCH[2]}
		[[ -n ${BASH_REMATCH[3]} ]] && PARTS_CORRECTED=1
	else
		while read -r name size _; do
			[[ $size =~ ^[0-9]+$ ]] && (( size > 0 )) || continue
			while (( div > 0 && (size >> div) == 0 )); do ((div--)); done
		done < "$raw"
		ushift=$((20 - div))
	fi
	tmp=$(mktemp "$out.XXXXXX") || return 1
	while read -r name size _; do
		[[ -n ${name:-} && $name != \#* && $size =~ ^[0-9]+$ ]] || continue
		printf '%s %s\n' "$name" $(( size << ushift ))
	done < "$raw" > "$tmp" && mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
	PARTS_SHIFT=$ushift
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
	echo "  imei      — miscdata, prodnv, both fixnv, both runtimenv"
	echo "  preset_modem  — spd_dump r preset_modem: every l_* and nr_* partition,"
	echo "                  plus misc when the phone is A/B"
	echo "  preset_resign — spd_dump r preset_resign: vbmeta, splloader, uboot, sml,"
	echo "                  trustos, teecfg, boot, recovery"
	echo "Several names (boot vbmeta) are dumped in one session."
	echo "all, all_lite, imei, preset_modem, and preset_resign are typed alone."
}

# L2: how a READ-ONLY session ends. A session that stops after its last read
# used to leave the phone sitting in FDL2 (screen on, battery draining, no way
# out but a forced restart). It now ends like every other session: with the
# configured ending when that is reset or power-off, and with power-off when
# the ending is recovery/fastbootd -- those write misc, and a read-only session
# writes nothing.
read_only_ending() {
	case $BOOT_AFTER in
		reset|power-off) printf '%s\n' "$BOOT_AFTER" ;;
		*) printf '%s\n' power-off ;;
	esac
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
		parts "$raw" read-part misc "$SPD_SLOT_OFF" "$SPD_SLOT_BYTES" "$misc" "$(read_only_ending)"
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
	echo "parts: units -> bytes (shift $PARTS_SHIFT${PARTS_VERIFIED:+, from spdhost}); slot: ${ACTIVE_SLOT:-unknown}"
	if [[ $PARTS_VERIFIED == 1 && $PARTS_CORRECTED == 1 ]]; then
		echo "note: the device's size probe disagreed with spd_dump's unit guess; spdhost corrected"
		echo "every row to shift $PARTS_SHIFT from the device's answer (see its 'check:' line above)."
	elif [[ $PARTS_VERIFIED == 0 ]]; then
		echo "WARNING: this table's unit is a guess the device did not confirm (shift $PARTS_SHIFT)."
		echo "The sizes shown may be off by a power of two. Dumps size each partition by asking"
		echo "the device; a partition it will not size is reported UNVERIFIED, not ok."
	elif [[ -z $PARTS_VERIFIED && $PARTS_SHIFT != 10 ]]; then
		# L1: only shift 10 (KiB rows, eMMC) is a known unit. Anything else is
		# UFS or spd_dump's heuristic lowered by a row under 1 MiB; spdhost
		# printed what its one-row check_partition probe answered above.
		echo "WARNING: this table's unit is a guess (shift $PARTS_SHIFT, not 10: UFS or a row under 1 MiB)."
		echo "Sizes may be off by a power of two; see spdhost's 'check:' line above before a full dump or restore."
	fi
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
		# A failed filter or rename used to leave the mktemp file sitting in
		# the dump folder while the new line was still appended below, so the
		# next run's `ls` would show a stray SHA256SUMS.XXXXXX. Drop it.
		if ! awk -v k="$key" '{ n = $0; sub(/^[0-9a-f]+  /, "", n); if (n != k) print }' "$sums" > "$tmp" ||
			! mv "$tmp" "$sums"; then
			rm -f "$tmp"
			return 1
		fi
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
	local -A unver=()
	while read -r tag name _; do
		[[ $tag == ok ]] && okset[$name]=1
		[[ $tag == unverified ]] && unver[$name]=1
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
		if [[ -n ${unver[$name]:-} ]]; then
			# G1: read at a size from a guessed table unit the device would
			# not confirm. The file is kept, but it is not called a backup.
			failed+=("$name(size unverified)")
			echo "UNVERIFIED $name: $sz bytes at a guessed table unit; the device would not size it."
			echo "     $file is kept but NOT recorded in SHA256SUMS; it may be truncated."
			continue
		fi
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
	dump_many_session miscdata prodnv l_fixnv1 l_fixnv2 l_runtimenv1 l_runtimenv2
}

# One session, one `dump NAME DIR` per name. The release backup line accepts
# several names; all / all_lite / imei stay single-word and do not come here.
dump_many_session() {
	local raw rc name
	local -a args=()
	(($#)) || { echo "No partition names."; return 1; }
	raw=$(parts_cache_path)
	mkdir -p "$DUMP_DIR"
	echo "One session: refresh the table, then dump $*."
	ready || return 1
	rm -f "$DUMP_DIR/dump-manifest.txt"
	for name in "$@"; do
		args+=(dump "$name" "$DUMP_DIR")
	done
	run_session --keep-going fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$raw" "${args[@]}" "$BOOT_AFTER"
	rc=$?
	[[ -s $raw ]] && load_parts_state && echo "table refreshed: $raw (slot ${ACTIVE_SLOT:-unknown})"
	verify_dump_manifest "$rc"
}

# One typed line: "boot", "boot vbmeta", "all", "all_lite", or "imei".
dispatch_dump_query() {
	local query=$1 parts_file=$2 w t
	local -a words=() targets=()
	read -ra words <<<"$query"
	if ((${#words[@]} == 0)); then
		echo "Cancelled."
		return 1
	fi
	if ((${#words[@]} == 1)); then
		case ${words[0],,} in
			imei) dump_imei_session; return ;;
			all|all_lite|preset_modem|preset_resign)
				echo "Reading the live table, then dumping ${words[0],,}."
				dump_live_session "${words[0],,}"
				return
				;;
		esac
		t=$(live_dump_target "${words[0]}" "$parts_file") || return 1
		echo "Will dump '$t' using the live table."
		dump_live_session "$t"
		return
	fi
	for w in "${words[@]}"; do
		case ${w,,} in
			all|all_lite|imei|preset_modem|preset_resign)
				echo "all, all_lite, imei, preset_modem, and preset_resign must be typed alone." >&2
				return 1
				;;
		esac
		t=$(live_dump_target "$w" "$parts_file") || return 1
		targets+=("$t")
	done
	echo "Will dump: ${targets[*]}"
	dump_many_session "${targets[@]}"
}

dump_partition() {
	local parts_file raw reply query matched name size refresh=0 target rc
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
			echo "Type a name (boot, boot.img, boot_a, splloader), several names, or all / all_lite / imei."
		fi
		read -r -p "Partition name (or all / all_lite / imei / preset_modem / preset_resign): " query
		if [[ -z ${query:-} ]]; then
			echo "Cancelled."
			pause
			return
		fi
		dispatch_dump_query "$query" "$parts_file"
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
	read -r -p "Partition name (or all / all_lite / imei / preset_modem / preset_resign): " query
	if [[ -z ${query:-} ]]; then
		echo "Cancelled."
		pause
		return
	fi
	# One real partition name still shows the cached size. all / all_lite / imei
	# / preset_modem / preset_resign and several names go straight to dispatch.
	case ${query,,} in
		all|all_lite|imei|preset_modem|preset_resign) ;;
		*' '*) ;;
		*)
		matched=$(resolve_part_query "$query" "$parts_file") || {
			pause
			return 1
		}
		read -r name size <<<"$matched"
		echo
		echo "Cached match '$query' -> $name  size=$(fmt_size "$size") ($size bytes)"
		echo "The dump re-reads the device. A name without _a/_b follows the live slot."
		;;
	esac
	dispatch_dump_query "$query" "$parts_file"
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
	echo
	# The session above read the table, so spdhost also left it as the
	# repartition XML in the dump folder -- the file option 8 edits a copy of.
	echo "The same table was written as repartition XML to $DUMP_DIR"
	echo "(partition_<unixtime>.xml). Copy and edit that for option 8."
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

# Release-menu file, shipped per model: fdl/<soc>/<brand>/fdl2-cboot.bin, and
# gen_spl-unlock beside menu.sh. spl-unlock.bin is generated.
#
# The selected model's own loader directory is searched FIRST. This file is
# what unlock_bootloader_menu writes to uboot just after erasing splloader, so
# picking up another model's copy is a brick: the old order tried the
# hardcoded ums9230/infinix directory before the model's own, and a phone
# configured as ums9230/itel therefore got infinix's uboot. That directory is
# now a last resort, and only while the selection really is that same
# ums9230/infinix pair.
#
# Every directory the menu offers carries one now, but the brand-level copy
# must never stand in for an alternatif sub-model: those are different phones
# (c53 is not c31), so a lookup that crosses out of the sub-model's own folder
# is refused rather than answered with the wrong image.
find_user_file() {
	local name=$1 d base soc dev fdir
	local -a places=()
	base=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	soc=${SOC:-}
	dev=${DEVICE:-}
	# The model's own loader directory, then its package root.
	if [[ -n ${FDL1:-} ]]; then
		fdir=$(dirname "$FDL1")
		places+=("$fdir/$name")
		# Two levels up is the package root for the legacy layout, where the
		# loaders live at <package>/<soc>/<brand>/. From an alternatif
		# sub-model (<soc>/<brand>/alternatif/<model>/) the same hop lands on
		# <soc>/<brand>/ -- the generic brand image, which belongs to a
		# different phone. Writing that to uboot is a brick, so it is not
		# taken from inside an alternatif folder.
		if [[ $fdir != */alternatif/* && $fdir != */alternativ/* ]]; then
			places+=("$fdir/../../$name")
		fi
	fi
	# M3: once a model is chosen (DEVICE set) only its own folder counts. A
	# stray copy in the working directory or beside menu.sh belongs to no
	# model in particular, and this lookup feeds the uboot write.
	if [[ -z $dev ]]; then
		places+=(
			"$PWD/$name"
			"$base/$name"
			"$base/../$name"
		)
	fi
	# Legacy release layout: menu at the package root, loaders under
	# ums9230/infinix/. Only when no model has been chosen yet, or the chosen
	# one is that very pair — otherwise this is a different phone's file. A
	# sub-model (DEVICE=infinix/hot12pro) is not that pair either: it is its
	# own phone, so it does not get infinix's image.
	if [[ -z $dev || ( $soc == ums9230 && $dev == infinix ) ]]; then
		places+=("$PWD/ums9230/infinix/$name" "$base/ums9230/infinix/$name")
	fi
	for d in "${places[@]}"; do
		if [[ -f $d ]]; then
			(cd "$(dirname "$d")" && printf '%s/%s\n' "$(pwd)" "$(basename "$d")")
			return 0
		fi
	done
	return 1
}

# U6: a per-phone vendor blob (fdl2-cboot.bin, spl-unlock.bin) -- the file the
# unlock writes to uboot or runs as FDL1. find_user_file's fallbacks (the
# package root, ../../, $PWD, beside menu.sh, ums9230/infinix/ for any chip)
# each can answer with another phone's copy, so this looks in exactly one
# place: the folder FDL1 was loaded from. With a model picked (SOC and DEVICE
# set) that folder must be that model's own, fdl/<soc>/<brand>/ or
# fdl/<soc>/<brand>/alternatif/<model>/; anything else answers nothing. With
# loaders configured by hand (no DEVICE) the folder of the chosen FDL1 is the
# explicit choice.
find_model_file() {
	local name=$1 fdir soc=${SOC:-} dev=${DEVICE:-} ok=0
	[[ -n ${FDL1:-} ]] || return 1
	fdir=$(cd "$(dirname "$FDL1")" 2>/dev/null && pwd) || return 1
	if [[ -n $dev ]]; then
		[[ -n $soc ]] || return 1
		case $dev in
			*/*)
				[[ $fdir == */"$soc/${dev%%/*}/alternatif/${dev#*/}" ||
					$fdir == */"$soc/${dev%%/*}/alternativ/${dev#*/}" ]] && ok=1 ;;
			*)
				[[ $fdir == */"$soc/$dev" ]] && ok=1 ;;
		esac
		(( ok )) || return 1
	fi
	[[ -f $fdir/$name ]] || return 1
	printf '%s/%s\n' "$fdir" "$name"
}

# Release helper from the zip. These are x86-64 ELF binaries, so they run on a
# PC and cannot execute on the phone; the built-in spdhost image tools are what
# the menu prefers (see spdhost_has_image_tools). PATH, then the same places as
# the files. Named lookup because the release ships both the standard and the
# legacy spl algorithm.
find_release_tool() {
	local p
	p=$(command -v "$1" 2>/dev/null || true)
	if [[ -n $p && -x $p ]]; then
		printf '%s\n' "$p"
		return 0
	fi
	p=$(find_user_file "$1" || true)
	if [[ -n $p && -x $p ]]; then
		printf '%s\n' "$p"
		return 0
	fi
	return 1
}

find_gen_spl_unlock() {
	find_release_tool "${1:-gen_spl-unlock}"
}

# True when the resolved spdhost understands the offline image tools. Probed by
# running one with no arguments and looking for its usage line, so an older
# spdhost build falls back to the release binary instead of failing mid-unlock.
spdhost_has_image_tools() {
	local bin out
	bin=$(resolve_spdhost_bin 2>/dev/null) || return 1
	[[ -n $bin ]] || return 1
	out=$("$bin" gen-spl-unlock 2>&1 || true)
	[[ $out == *"gen-spl-unlock IN OUT"* ]]
}

# Absolute path to the spdhost binary, mirroring scripts/spdhost-usb's own
# resolver, so --self-test runs the same build the wrapper would actually
# launch (not a stale PATH copy from an older install).
resolve_spdhost_bin() {
	local script_dir cand
	# Explicit override first: tests point this at the binary they built, and a
	# user can run a spdhost kept outside this tree (e.g. an older release).
	if [[ -n ${SPDHOST_BIN:-} ]]; then
		[[ -f $SPDHOST_BIN && -x $SPDHOST_BIN ]] || return 1
		(cd "$(dirname "$SPDHOST_BIN")" && printf '%s/%s\n' "$(pwd)" "$(basename "$SPDHOST_BIN")")
		return 0
	fi
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

# Writable temp directory, resolved the same way scripts/spdhost-usb does:
# TMPDIR, else Termux's $PREFIX/tmp, else /tmp. A stock Termux has no /tmp.
spd_tmpdir() {
	local d
	for d in "${TMPDIR:-}" "${PREFIX:+$PREFIX/tmp}" /tmp; do
		[[ -n $d && -d $d && -w $d ]] && { printf '%s\n' "$d"; return 0; }
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
	echo "  SET_CONFIGURATION(1) on a device reading as config 0, and a zero-length"
	echo "  OUT packet after a full 512-byte write, are on by default too — they are"
	echo "  what the build that worked sends. SPDHOST_NO_SET_CONFIG=1 and"
	echo "  SPDHOST_NO_SEND_ZLP=1 turn each off for A/B testing on a hostile host."
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
	local devs="" probe_rc=0 tries=0
	if command -v termux-usb >/dev/null 2>&1; then
		# Always bounded (see bounded() above), and retried so a single slow
		# answer is not mistaken for "nothing plugged in". An empty list with
		# a clean exit is the normal "no device attached" case; a non-zero
		# exit means termux-usb never answered.
		while (( tries < 3 )); do
			devs=$(bounded 5 termux-usb -l 2>/dev/null)
			probe_rc=$?
			[[ -n $devs || $probe_rc == 0 ]] && break
			tries=$((tries + 1))
			(( tries < 3 )) && sleep 1
		done
		devs=$(printf '%s\n' "$devs" | grep -oE '/dev/bus/usb/[0-9]+/[0-9]+' || true)
	fi
	if [[ -z $devs ]]; then
		if (( probe_rc != 0 )) && command -v termux-usb >/dev/null 2>&1; then
			echo "termux-usb -l did not answer within 5s (stopped after 3 tries)."
			echo "That is usually the Termux:API app missing, not yet opened, or"
			echo "killed by battery optimisation — see the notes at the end."
			echo
		fi
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
			# Not a hardcoded /tmp: a stock Termux has no /tmp, so the redirect
			# used to fail, grep then failed on the missing file, and the check
			# below reported PASS having captured nothing at all. Skipping is
			# the honest answer when there is nowhere to write the output.
			local tdir probe2=
			if tdir=$(spd_tmpdir); then
				probe2=$(mktemp "$tdir/spdhost-smoke-probe2.XXXXXX") || probe2=
			fi
			if [[ -n $probe2 ]]; then
				SPDHOST_BROM_TRIES=2 SPDHOST_BROM_WALL_MS=3000 run_session ping >"$probe2" 2>&1
				if grep -qi "LIBUSB_ERROR_BUSY\|interface .* is busy" "$probe2"; then
					echo "FAIL  interface is busy on the follow-up probe"
					ok=0
				else
					echo "PASS  no busy interface on the follow-up probe"
				fi
				cat "$probe2"
				rm -f "$probe2"
			else
				echo "note  no writable temp directory (set TMPDIR); skipped the"
				echo "      follow-up busy check"
			fi
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
MISC_EXPECT_SHA=""
guarded_misc_session() {
	local kind=$1 ts backup raw rc want sz tok=$MISC_CONFIRM_TOKEN expect=$MISC_EXPECT_SHA
	local -a backup_cmd
	shift
	# MISC_EXPECT_SHA (one-shot, like the token): the sha256 misc had when the
	# caller read it in an EARLIER session. The backup then becomes
	# misc-backup-expect, and spdhost stops before the write if misc has
	# changed since -- the write is built from that earlier read.
	MISC_EXPECT_SHA=
	# The caller's last command is what ends the session (reset, power-off).
	# One --confirm-token authorizes exactly ONE misc write, so a caller must
	# never put a second misc-writing command (reboot-recovery, reboot-fastboot,
	# another write-part misc) behind this one: spdhost refuses it and exits.
	local ending=reset st verify endres
	if (( $# > 0 )); then ending=${!#}; fi
	case $ending in
		recovery) ending="reset into recovery" ;;
		fastboot) ending="reset into fastbootd" ;;
		reboot-recovery) ending="reset into recovery" ;;
		reboot-fastboot) ending="reset into fastbootd" ;;
	esac
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
	if [[ -n $expect ]]; then
		if [[ ! $expect =~ ^[0-9a-f]{64}$ ]]; then
			echo "menu: bad expected misc sha256 for $kind; nothing written" >&2
			return 1
		fi
		backup_cmd=(misc-backup-expect "$backup" "$expect")
	else
		backup_cmd=(misc-backup "$backup")
	fi
	# spdhost appends misc-verify=... and reset=/power-off=... here, so the
	# two results are reported apart (H1): a lost reset ack after a verified
	# misc is not a failed misc write, and a verified misc is not a reset.
	st=$(mktemp "$(spd_tmpdir 2>/dev/null || echo /tmp)/spdhost-status.XXXXXX" 2>/dev/null) || st=
	local -x SPDHOST_STATUS_FILE=$st
	run_session "--confirm-token=$tok" fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$raw" "${backup_cmd[@]}" "$@"
	rc=$?
	verify=$( [[ -n $st ]] && awk -F= '$1 == "misc-verify" { v = $2 } END { print v }' "$st" 2>/dev/null)
	endres=$( [[ -n $st ]] && awk -F= '$1 == "reset" || $1 == "power-off" { v = $2 } END { print v }' "$st" 2>/dev/null)
	[[ -n $st ]] && rm -f "$st"
	case $verify in
		ok) echo "misc verify: OK (the whole misc was read back and matches)" ;;
		failed) echo "misc verify: FAILED (read-back mismatch; spdhost did not reset)" ;;
		not-reached) echo "misc verify: not reached (the misc write itself failed)" ;;
		*) echo "misc verify: not reached (spdhost stopped before the misc write)" ;;
	esac
	case $endres in
		ack) echo "$ending: acknowledged by the loader" ;;
		left-bus) echo "$ending: device left the bus on reset (expected)" ;;
		timeout) echo "$ending: FAILED -- no ack and the device is still connected (timeout)" ;;
		not-sent|usb-error|nack) echo "$ending: FAILED ($endres)" ;;
		*) [[ $verify == ok ]] && echo "$ending: not run" ;;
	esac
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
		if [[ -n $expect ]]; then
			echo "If spdhost said 'misc CHANGED since it was read', nothing was written: misc"
			echo "changed between the read session and this one. Run this option again."
		fi
		if [[ $verify == ok ]]; then
			echo "$kind: misc WAS written and verified; only the $ending did not complete (exit $rc)."
			echo "Hold power (or unplug the battery/USB) to restart; misc already holds the change."
		else
			echo "$kind FAILED (exit $rc). Read the spdhost lines above: no $ending happens after a failed backup or a misc read-back mismatch."
		fi
	else
		echo "$kind: misc written, read back and verified, then $ending."
	fi
	return "$rc"
}

# Read the whole misc partition into MISC_LIVE_IMAGE (a private temp file).
# Read-only: the session runs `parts` (misc size) and `misc-backup` (read +
# read-back check) and nothing else, so there is no write, no confirm token.
# Returns 1 and leaves no file behind on failure.
#
# Sets a global instead of printing the path because run_session writes the
# command line and its output to stdout: a $(...) caller would capture all of
# that, not just the path.
#
# The file lands in the temp dir, NOT in DUMP_DIR: write-parts restores every
# NAME.img it finds there, so a live misc image in DUMP_DIR could be written
# back by a later restore.
MISC_LIVE_IMAGE=""
read_misc_image() {
	local dir img rc
	MISC_LIVE_IMAGE=
	dir=$(spd_tmpdir) || { echo "no writable temp directory (set TMPDIR)" >&2; return 1; }
	img=$(mktemp "$dir/spdhost-misc-live.XXXXXX") || return 1
	ready || { rm -f "$img"; return 1; }
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" misc-backup "$img" "$(read_only_ending)"
	rc=$?
	if (( rc != 0 )) || [[ ! -s $img ]]; then
		echo "reading misc failed (exit $rc); nothing written." >&2
		rm -f "$img"
		return 1
	fi
	MISC_LIVE_IMAGE=$img
	return 0
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

# Factory reset is the recovery wipe BCB only. It does not erase persist.
# Shared by reboot menu [5] and extra [1]. Returns 1 without pausing.
wipe_userdata_action() {
	local misc
	need_loaders || return 1
	resolve_misc_dir || return 1
	misc="$MISC_DIR/misc-wipe.bin"
	if [[ ! -f $misc ]]; then
		echo "missing $misc" >&2
		return 1
	fi
	echo "Wipe userdata via shipped misc-wipe.bin + reset (BCB only; no persist erase)."
	if ! confirm_wipe_userdata "$misc"; then
		return 1
	fi
	# No --yes: token = sha256 of misc-wipe.bin, checked by spdhost.
	guarded_misc_session wipe-userdata write-part misc "$misc" reset
}

reboot_mode() {
	local choice
	need_loaders || return
	cls
	echo "Reboot mode"
	echo "[1] system"
	echo "[2] recovery"
	echo "[3] fastbootd (needs an Android 10+ recovery)"
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
			# An unchecked reset reads as success: the user unplugs a phone
			# that is still sitting in download mode.
			if ! run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" reset; then
				echo "The reset command failed. The phone is still in download mode."
				echo "Unplug and re-plug it, then try again."
			fi
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
			if ! run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" power-off; then
				echo "The power-off command failed. The phone is still in download mode"
				echo "and its battery is still draining; unplug it to leave that state."
			fi
			;;
		5)
			wipe_userdata_action || { pause; return; }
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
		*_bak|misc-slotinfo|misc-before-*|persist-before-*) return 1 ;;
	esac
	return 0
}

# Release menu option 2: every input/<partition>.img, then BOOT_AFTER.
#
# A .bin is used under its stripped name (boot.bin as boot.img) WITHOUT
# renaming it. The flash folder used to be a dedicated input/ folder, but it is
# the phone's Download folder now, so renaming every *.bin in it would rename
# files that have nothing to do with this tool. Instead the chosen files are
# gathered into a temporary staging folder as NAME.img -- symlinked when the
# filesystem allows it, copied when it does not -- and that is what is passed
# to write-files. Nothing in $INPUT_DIR is ever modified.
flash_input_menu() {
	# Parallel arrays, not "src:dst" strings: a file name is allowed to contain
	# a colon, and splitting on the first one would then cut the path in half.
	local -a names=() skipped=() stage_src=() stage_dst=()
	local f base stage="" i tdir
	need_loaders || return
	mkdir -p "$INPUT_DIR"
	shopt -s nullglob
	for f in "$INPUT_DIR"/*.img; do
		base=$(basename "$f")
		if part_image_candidate "$base"; then
			names+=("${base%.img}")
			stage_src+=("$f")
			stage_dst+=("$base")
		else
			skipped+=("$base")
		fi
	done
	for f in "$INPUT_DIR"/*.bin; do
		base=$(basename "$f")
		if [[ -e ${f%.bin}.img ]]; then
			echo "Not using $base: ${base%.bin}.img is also there."
			continue
		fi
		if part_image_candidate "${base%.bin}.img"; then
			names+=("${base%.bin}")
			stage_src+=("$f")
			stage_dst+=("${base%.bin}.img")
		else
			skipped+=("$base")
		fi
	done
	shopt -u nullglob
	if (( ${#names[@]} == 0 )); then
		echo "No partition images in $INPUT_DIR."
		echo "That folder is there now. Copy images into it, then choose this again."
		# True only in the shared one-folder layout. In the package layout
		# dumps are in backup/ and this sentence used to send people looking
		# in the flash folder for files that were never written there.
		if [[ -n $INPUT_DIR && -n $DUMP_DIR ]] &&
		   [[ $(cd "$INPUT_DIR" 2>/dev/null && pwd -P) == "$(cd "$DUMP_DIR" 2>/dev/null && pwd -P)" ]]; then
			echo "If you just dumped from this phone, they are already here (it is the same folder)."
		else
			echo "Dumps are in $DUMP_DIR. Menu [9] copies partition images into this folder."
		fi
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
	# Nothing below writes to $INPUT_DIR; the stage is a private view of it.
	# spd_tmpdir(), not ${TMPDIR:-/tmp}: a stock Termux has no /tmp at all,
	# only $PREFIX/tmp, and with TMPDIR unset this fell through to a path that
	# cannot be created -- menu [6] aborted with "Could not create a staging
	# folder." on exactly the phone this tool is for. The suites masked it by
	# exporting TMPDIR.
	tdir=$(spd_tmpdir) || {
		echo "no writable temp directory (set TMPDIR)" >&2
		return 1
	}
	stage=$(mktemp -d "$tdir/spdhost-flash.XXXXXX") || {
		echo "Could not create a staging folder in $tdir." >&2
		return 1
	}
	for (( i = 0; i < ${#stage_src[@]}; i++ )); do
		if ! ln -s "${stage_src[i]}" "$stage/${stage_dst[i]}" 2>/dev/null; then
			cp "${stage_src[i]}" "$stage/${stage_dst[i]}" || {
				echo "Could not stage ${stage_dst[i]}" >&2
				rm -rf "$stage"
				return 1
			}
		fi
	done
	echo "Each file is written under its own name, including an inactive _a or _b image."
	echo "A .bin is flashed under its stripped name; the file itself is not renamed."
	echo "A name that is not on the phone is skipped. The other images are still written."
	echo "An empty image, or one larger than its partition, aborts the flash before anything is sent."
	echo "misc.img, if present, is backed up and verified. Writing it also restores the"
	echo "slot record it was dumped with; no other file here can change the slot."
	echo "This flash does not erase metadata."
	echo "splloader.img is capped at 256 KiB (the size of a splloader dump); a larger one aborts the flash."
	echo "A misc.img that is not 2048 bytes or the whole live misc partition is skipped with a warning."
	echo "A broken l_fixnv1 image is skipped. A sparse image waits up to 100 seconds per chunk."
	echo "Then: $BOOT_AFTER. recovery/fastbootd writes a 2048-byte BCB after the images."
	echo "A same-size *_bak is written only when the device is not A/B. vbmeta flags are not edited."
	if ! confirm_action "type yes to flash these partitions: "; then
		rm -rf "$stage"
		return 1
	fi
	echo "spdhost asks once more on the terminal before it sends anything."
	if ! ready; then
		rm -rf "$stage"
		return 1
	fi
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" write-files "$stage" "$BOOT_AFTER"
	local rc=$?
	rm -rf "$stage"
	return $rc
}

# A dump lands in DUMP_DIR; a flash reads INPUT_DIR. The release menu leaves
# the user to move files between them by hand (that is what the "letak file di
# folder input" step means). This copies the images one way, so a partition
# that was just read off a phone is the partition menu [6] will write, under
# the same name it was dumped with.
#
# It only ever adds files: an existing input/NAME.img of the same size is left
# alone, and one of a different size is reported and skipped, never replaced.
# That matters because input/ is also where a user keeps the images they meant
# to flash -- silently swapping one for a dump would change what gets written.
promote_dump_action() {
	local -a names=() copied=() same=() clash=()
	local n f base src dst ssz dsz
	echo "Copy dumped images from the dump folder into the flash folder."
	echo "  from: $DUMP_DIR"
	echo "  to:   $INPUT_DIR"
	echo "Only partition images are copied (the same names menu [7] restores)."
	echo "A file already in the flash folder with the same size is left alone;"
	echo "one with a different size is skipped, never overwritten."
	# In the default layout there is one folder, so menu [6] already reads
	# every dump. Say that plainly rather than reporting a no-op copy as if
	# it had done something.
	if [[ -n $INPUT_DIR && -n $DUMP_DIR ]] &&
	   [[ $(cd "$INPUT_DIR" 2>/dev/null && pwd -P) == "$(cd "$DUMP_DIR" 2>/dev/null && pwd -P)" ]]; then
		echo "The flash folder and the dump folder are the same folder:"
		echo "  $INPUT_DIR"
		echo "Menu [6] flashes the images here directly; there is nothing to copy."
		echo "This step is only needed when the two differ (STORAGE=package, or"
		echo "separate SPDHOST_INPUT_DIR / SPDHOST_DUMP_DIR)."
		return 0
	fi
	if [[ ! -d $DUMP_DIR ]]; then
		echo "No dump folder yet: $DUMP_DIR"
		return 1
	fi
	mkdir -p "$INPUT_DIR" || { echo "Could not create $INPUT_DIR" >&2; return 1; }
	shopt -s nullglob
	for f in "$DUMP_DIR"/*; do
		[[ -f $f ]] || continue
		base=$(basename "$f")
		part_image_candidate "$base" || continue
		# A dump is NAME.img. A .bin kept in the dump folder is left where it
		# is: menu [6] reads .bin in either folder, so copying it here would
		# only create a second name for the same bytes.
		[[ $base == *.img ]] || continue
		names+=("$base")
	done
	shopt -u nullglob
	if (( ${#names[@]} == 0 )); then
		echo "No *.img partition images in $DUMP_DIR. Dump one first (menu [1])."
		return 1
	fi
	for base in "${names[@]}"; do
		src=$DUMP_DIR/$base
		dst=$INPUT_DIR/$base
		if [[ -e $dst ]]; then
			ssz=$(stat -c %s "$src" 2>/dev/null || echo 0)
			dsz=$(stat -c %s "$dst" 2>/dev/null || echo 0)
			if [[ $ssz == "$dsz" ]]; then same+=("$base"); else clash+=("$base"); fi
			continue
		fi
		copied+=("$base")
	done
	echo
	if (( ${#copied[@]} )); then
		echo "Will copy:"
		printf '  %s\n' "${copied[@]}"
	else
		echo "Nothing new to copy."
	fi
	(( ${#same[@]} )) && echo "Already there, same size (left alone): ${same[*]}"
	(( ${#clash[@]} )) && echo "Skipped, a different file of that name is already there: ${clash[*]}"
	if (( ${#copied[@]} == 0 )); then
		echo "menu [6] already has every one of these images."
		return 0
	fi
	if ! confirm_action "type yes to copy these into the flash folder: "; then
		return 1
	fi
	n=0
	for base in "${copied[@]}"; do
		src=$DUMP_DIR/$base
		dst=$INPUT_DIR/$base
		tmp=$dst.new.$$
		# Copy beside the destination, check the size there, and only then
		# publish it. `ln` fails if the name exists, which is the atomic
		# no-clobber: a file that appeared while this was running is left
		# exactly as it is. Nothing here ever removes a file this loop did
		# not just write -- cp -n returns 0 without copying, so pairing it
		# with a fallback `rm -f "$dst"` would delete a stranger's image.
		rm -f "$tmp"
		if ! cp "$src" "$tmp" 2>/dev/null; then
			echo "could not copy $base into $INPUT_DIR" >&2
			rm -f "$tmp"
			continue
		fi
		ssz=$(stat -c %s "$src" 2>/dev/null || echo 0)
		tsz=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
		if [[ $ssz != "$tsz" ]]; then
			echo "short copy of $base ($tsz of $ssz bytes); not installed" >&2
			rm -f "$tmp"
			continue
		fi
		if ln "$tmp" "$dst" 2>/dev/null; then
			echo "ok   $base $(fmt_size "$ssz")"
			n=$((n + 1))
		elif [[ -e $dst ]]; then
			echo "$base appeared in $INPUT_DIR while copying; left alone" >&2
		elif cp "$tmp" "$dst" 2>/dev/null; then
			echo "ok   $base $(fmt_size "$ssz")"
			n=$((n + 1))
		else
			echo "could not install $base into $INPUT_DIR" >&2
		fi
		rm -f "$tmp"
	done
	echo "$n image(s) in $INPUT_DIR. Choose menu [6] to flash them."
	return 0
}

# Names write-parts will look at: regular files in this directory that
# part_image_candidate does not reject. Prints one name per line.
restore_image_names() {
	local dir=$1 f base
	shopt -s nullglob
	for f in "$dir"/*; do
		[[ -f $f ]] || continue
		base=$(basename "$f")
		part_image_candidate "$base" || continue
		printf '%s\n' "${base%.*}"
	done
	shopt -u nullglob
}

# Release menu option 4: write_parts of the backup folder.
restore_backup_menu() {
	local -a names=()
	local cmd slot
	need_loaders || return
	if [[ ! -d $DUMP_DIR ]]; then
		echo "No backup directory $DUMP_DIR."
		return 1
	fi
	mapfile -t names < <(restore_image_names "$DUMP_DIR")
	if ((${#names[@]} == 0)); then
		echo "No partition images in $DUMP_DIR."
		echo "Dump first (menu [1]), or put partition-name.img files in that folder."
		return 1
	fi
	echo "Restore these images from $DUMP_DIR, then $BOOT_AFTER:"
	printf '  %s\n' "${names[@]}"
	echo "Skipped: *.txt, SHA256SUMS, misc-slotinfo.img, misc-before-*.img, persist-before-*.img, *_bak.img."
	if [[ $INPUT_DIR == "$DUMP_DIR" ]]; then
		echo "This is the same folder menu [6] flashes from, so images you put there to flash are listed here too."
	fi
	echo "A name that is not on the phone is skipped. The other images are still written."
	echo "A broken l_fixnv1 image is skipped. An empty or oversized image aborts the restore before anything is sent."
	echo "splloader.img is capped at 256 KiB (the size of a splloader dump); a larger one aborts the restore."
	echo "A misc.img that is not 2048 bytes or the whole live misc partition is skipped with a warning; the rest is written."
	echo "userdata.img in this folder is written back. Inactive _a/_b images are skipped."
	echo "The active slot is written back after the files."
	echo "super.img without metadata.img erases metadata when that partition is on the phone."
	echo "Then: $BOOT_AFTER. recovery/fastbootd writes a 2048-byte BCB after the images."
	if ! confirm_action "type yes to restore this backup: "; then
		return 1
	fi
	# A/B phones: write-parts writes the images for the slot the backup's own
	# misc image names (offset 0x800) and drops the other slot's files, so a
	# restore after the phone was switched lands on the wrong slot. -a and -b
	# force one. Off an A/B phone there are no _a/_b names and this is ignored.
	read -r -p "Restore to slot [Enter] as the backup's misc says / [a] / [b]: " slot
	# Same trim as confirm_action. "a " must not fall through to write-parts
	# while the line below still says the slot was forced.
	while [[ ${slot:-} == *[$' \t\r\n'] ]]; do slot=${slot%?}; done
	case ${slot:-} in
		a|A) cmd=write-parts-a ;;
		b|B) cmd=write-parts-b ;;
		*) cmd=write-parts ;;
	esac
	echo "Using $cmd (${slot:+forced slot ${slot,,}; }the other slot's images are skipped)."
	echo "spdhost asks once more on the terminal before it sends anything."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" "$cmd" "$DUMP_DIR" "$BOOT_AFTER"
}

# Same shape spd_repartition_xml accepts: one <Partitions> list, each entry
# a Partition tag with id="..." and size="...", file under 1 MiB, no NUL.
repartition_xml_preview() {
	local xml=$1 sz n
	[[ -f $xml ]] || { echo "No such file."; return 1; }
	sz=$(stat -c %s "$xml" 2>/dev/null || echo 0)
	if (( sz <= 0 || sz > 1048576 )); then
		echo "XML is empty or over 1 MiB ($sz bytes)."
		return 1
	fi
	if [[ $(tr -cd '\0' < "$xml" | wc -c) -ne 0 ]]; then
		echo "XML contains a zero byte."
		return 1
	fi
	grep -q '<Partitions>' "$xml" && grep -q '</Partitions>' "$xml" || {
		echo "XML needs one <Partitions>...</Partitions> list."
		return 1
	}
	# Count and list Partitions by looking at whole tags, not at lines: a
	# hand-written XML may put id="..." and size="..." on separate lines inside
	# one <Partition> tag, and that is legal. Flattening the whitespace first
	# keeps the preview in step with the C parser, which reads the tag as text.
	local flat tags
	flat=$(tr '\n\r\t' '   ' < "$xml")
	tags=$(printf '%s' "$flat" | grep -oE '<Partition[^>]*>' || true)
	n=$(printf '%s' "$tags" | grep -cE 'id="[^"]*"[^>]*size="|size="[^"]*"[^>]*id="' || true)
	if (( n < 1 )); then
		echo "No <Partition id=\"...\" size=\"...\"> entries."
		return 1
	fi
	# R2: one name twice is not a table spdhost will send; say so here too.
	local dups
	dups=$(printf '%s' "$tags" | grep -oE 'id="[^"]*"' | sort | uniq -d | tr '\n' ' ')
	if [[ -n $dups ]]; then
		echo "XML names a partition twice: $dups-- refused."
		return 1
	fi
	echo "Repartition replaces the on-device partition map ($n entries). A wrong XML can brick the phone."
	printf '%s\n' "$tags" | grep -E 'id="[^"]*"[^>]*size="|size="[^"]*"[^>]*id="' || true
}

repartition_menu() {
	local xml out
	need_loaders || return
	echo "Repartition replaces the phone's partition map from an XML:"
	echo '    <Partitions><Partition id="boot_a" size="64"/>...</Partitions>'
	echo "Size is MiB, and the last row is normally 0xffffffff (\"take the rest\")."
	echo "If you do not have one, spdhost can write the phone's current table as a"
	echo "starting point; edit that copy rather than writing one by hand."
	echo "Any path works, e.g. $DUMP_DIR/repart.xml or $DUMP_DIR/partition_<unixtime>.xml"
	echo "(spdhost leaves that second one in the dump folder on every table read)."
	read -r -p "Partition XML path, or 'new' to dump the current table first: " xml
	if [[ -z ${xml:-} ]]; then
		echo "Cancelled."
		return 1
	fi
	if [[ $xml == new ]]; then
		# The XML repartition reads is the XML partition-list writes, so the
		# phone can always supply its own starting point. Timestamped, so a
		# copy the user has edited is never overwritten by the next dump.
		out=$DUMP_DIR/partitions-$(date +%Y%m%d-%H%M%S).xml
		echo "Reading the table off the phone and writing $out."
		ready || return 1
		run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
			partition-list "$out" "$BOOT_AFTER" || return 1
		echo
		echo "Wrote $out. Edit a copy of it, then run this option again and give"
		echo "that path. The table itself was only read; the partition map is unchanged."
		# The ending is not a read: the release menu appends its bootmode to the
		# dump line too. reboot-recovery/reboot-fastboot add a 2048-byte BCB
		# write to misc. reset and power-off send no map write, but they do
		# take the phone out of download mode. Say which one happened.
		case $BOOT_AFTER in
			reboot-recovery|reboot-fastboot)
				echo "The ending is $BOOT_AFTER, so spdhost also wrote the 2048-byte"
				echo "BCB to misc and the phone is rebooting. Only the map is untouched."
				;;
			power-off|poweroff)
				echo "The ending is $BOOT_AFTER, so the phone powers off after the read."
				echo "Only the map is untouched."
				;;
			reset)
				echo "The ending is reset, so the phone reboots to system after the read."
				echo "Only the map is untouched."
				;;
		esac
		return 0
	fi
	repartition_xml_preview "$xml" || return 1
	# R2: spdhost refuses to send unless this same session saved the current
	# table as partition_<time>.xml first, and that copy goes to
	# SPDHOST_PART_XML_DIR (the dump folder). Stop here if it cannot.
	local bkdir=${SPDHOST_PART_XML_DIR-$DUMP_DIR}
	if [[ -z $bkdir ]] || ! mkdir -p "$bkdir" 2>/dev/null || [[ ! -w $bkdir ]]; then
		echo "No writable folder for the pre-repartition backup of the current table"
		echo "(SPDHOST_PART_XML_DIR / dump folder: '${bkdir}'). Refused; nothing sent."
		return 1
	fi
	if ! confirm_action "type yes to repartition from this XML: "; then
		return 1
	fi
	echo "spdhost first saves the current table to $bkdir/partition_<time>.xml, then"
	echo "prints the XML against the live table row by row (old and new size and start)."
	echo "It refuses duplicate names, a total past the phone's capacity, or a missing"
	echo "backup. Read the diff, then answer its question on the terminal."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		repartition "$xml" "$BOOT_AFTER"
}

# The --confirm-token for `set-active`: spdhost hashes the PATCH, not the misc
# image -- the line "spdhost-set-active <a|b> <BCB sha256|none>\n" -- because
# the image around the patch is whatever misc holds when the write session
# reads it. WHICH a|b, ENDING the BOOT_AFTER value.
set_active_token() {
	local which=$1 ending=$2 bcb=none
	case $ending in
		reboot-recovery|reboot-fastboot) bcb=$(misc_bcb_sha256 "$ending") ;;
	esac
	printf 'spdhost-set-active %s %s\n' "$which" "$bcb" | sha256sum | awk '{print $1}'
}

# H2: ONE session. spdhost reads misc, patches the slot block (and the BCB for
# a recovery/fastbootd ending), writes the whole misc, reads it back and
# resets. The old flow read misc in one session and wrote an image built from
# that read in a second one; anything that touched the slot block in between
# (the bootloader counting a try down, a fastboot boot) was either refused or,
# before the expect check, overwritten with stale bytes.
set_slot_menu() {
	local which digest ending rc
	local -a cmd
	need_loaders || return
	echo "Set the active A/B slot. spdhost reads misc, patches the 32-byte slot"
	echo "block at misc+0x800 (keeping the other slot's tries/successful), writes"
	echo "the whole misc back and reads it back -- all in one session."
	echo "Only for A/B phones (uboot_a and uboot_b in the table); spdhost refuses"
	echo "anything else before writing."
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
	cmd=(set-active "$which")
	ending=reset
	case $BOOT_AFTER in
		power-off)
			ending=power-off
			cmd+=(power-off)
			;;
		reboot-recovery)
			ending="reset into recovery"
			cmd+=(--bcb recovery)
			echo "Ending is $BOOT_AFTER: its 2048-byte BCB is part of this one misc write."
			;;
		reboot-fastboot)
			ending="reset into fastbootd"
			cmd+=(--bcb fastboot)
			echo "Ending is $BOOT_AFTER: its 2048-byte BCB is part of this one misc write."
			echo "fastbootd lives in recovery and needs an Android 10+ recovery image."
			;;
		*)
			cmd+=(reset)
			;;
	esac
	if [[ $which == b ]]; then
		echo "note: slot b is often never flashed on these phones. spdhost checks"
		echo "boot_b/vbmeta_b before a recovery ending; with a 'super' partition,"
		echo "slot b's system may be empty and a normal boot on b can fail."
	fi
	digest=$(set_active_token "$which" "$BOOT_AFTER")
	echo "About to set the active slot to $which in partition 'misc' (whole misc rewritten, read back), then $ending."
	echo "confirm token (sha256 of the patch: slot $which, BCB for $BOOT_AFTER): $digest"
	echo "Wrong chip/FDL or a mis-click can soft-brick the boot path."
	if [[ ! -t 0 ]]; then
		echo "refusing to write misc without a TTY (no silent --yes)" >&2
		return 1
	fi
	if ! menu_typed_yes "type yes to set the active slot to $which: " "$digest"; then
		return 1
	fi
	guarded_misc_session "set-active $which" "${cmd[@]}"
	rc=$?
	return "$rc"
}

boot_after_menu() {
	local choice
	echo "What to do after a flash, restore, repartition, slot change, or dump."
	echo "Same four endings as the release menu."
	echo "Recovery and fastbootd put the 2048-byte BCB into misc after the other work"
	echo "(the whole misc is rewritten and read back, so the slot at misc+0x800 stays),"
	echo "then reset. A slot change with a recovery/fastbootd ending does the slot and"
	echo "the BCB in one set-active session (one confirm token = one misc write)."
	echo "fastbootd lives in recovery: it needs an Android 10+ recovery image."
	echo "Read-only sessions end with reset/power off; with a recovery/fastbootd"
	echo "ending they power off (a read-only session writes no misc)."
	echo "Now: $BOOT_AFTER"
	echo "[1] system (reset)"
	echo "[2] recovery"
	echo "[3] fastbootd (Android 10+ recovery only)"
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
	# Persisted like the loaders and exec_addr: the main header shows this as a
	# setting, so it must not silently revert to `reset` on the next launch.
	save_config
	echo "After flash/restore/dump: $BOOT_AFTER (saved to $CONFIG)."
}

hex_mode_menu() {
	local cur alt
	cur=$(exec_addr_value || true)
	echo "exec_addr now: ${cur:-disabled}."
	# G3: the two stubs belong to a chip. With none picked (manual loaders,
	# "[4] another chip: no exec stub") EXEC_ADDR_DEFAULT/ALT are still the
	# ums9230 globals, and toggling would save ums9230's BootROM stub for
	# whatever phone this is. Nothing is changed or saved.
	if [[ -z ${SOC:-} ]]; then
		echo "No chip picked (option 3), so there is no stub to toggle. Nothing changed."
		echo "Pick the chip in option 3 first; hex mode only switches between that chip's two stubs."
		return 1
	fi
	echo "Chip $SOC: primary stub $EXEC_ADDR_DEFAULT, second $EXEC_ADDR_ALT."
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

# Build spl-unlock.bin from the splloader dump.
#
# Prefers the built-in tool in spdhost: it is aarch64, so it runs on the phone,
# and it never overwrites the file it is given. The release's gen_spl-unlock is
# x86-64 (PC only) and removes its INPUT and renames over it, so it gets a copy
# to destroy.
#
# The built-in reports how many signature sites it patched. Zero means the
# pattern did not match this splloader generation -- which is exactly when the
# legacy algorithm is the right answer, so offer it instead of guessing which
# SoC generation the user has.
unlock_make_spl_unlock() {
	# `out` is built from `work` on the next line rather than on this one:
	# bash expands every word of a `local` before it assigns any of them, so
	# `local work=$1 out=$work/...` would read `work` while it is still unset
	# and menu.sh runs under `set -u`. That aborted the whole unlock.
	local work=$1 spl=$2 out bin err rc reply legacy
	out=$work/spl-unlock.bin

	if spdhost_has_image_tools; then
		bin=$(resolve_spdhost_bin)
		err=$("$bin" gen-spl-unlock "$spl" "$out" 2>&1 >/dev/null)
		rc=$?
		[[ -n $err ]] && printf '  %s\n' "$err"
		if (( rc != 0 )) || [[ ! -s $out ]]; then
			echo "Built-in gen-spl-unlock failed (exit $rc). splloader was not erased."
			return 1
		fi
		if [[ $err == *"patched 0 signature site"* ]]; then
			legacy=$work/spl-unlock-legacy.bin
			echo
			echo "The standard pattern matched nothing in this splloader."
			echo "'gen-spl-unlock-legacy' targets an older layout. Trying it is"
			echo "free: the dump is only read, never modified."
			read -r -p "Try the legacy algorithm as well? [y/N] " reply
			if [[ ${reply,,} == y ]]; then
				err=$("$bin" gen-spl-unlock-legacy "$spl" "$legacy" 2>&1 >/dev/null)
				rc=$?
				[[ -n $err ]] && printf '  %s\n' "$err"
				if (( rc == 0 )) && [[ -s $legacy ]]; then
					if [[ $err == *"patched 0 signature site"* ]]; then
						echo "The legacy pattern matched nothing either."
						echo "Keeping the standard output; it may still work."
					else
						cp -f "$legacy" "$out"
						echo "Using the legacy result."
					fi
				fi
			fi
		fi
		return 0
	fi

	bin=$(find_gen_spl_unlock || true)
	if [[ -z $bin ]]; then
		echo "Cannot build spl-unlock.bin: this spdhost has no built-in image"
		echo "tools and gen_spl-unlock was not found."
		echo "The release package ships gen_spl-unlock beside its menu.sh. It is"
		echo "an x86-64 binary, so it runs on a PC, not on the phone."
		echo "splloader was not erased."
		return 1
	fi
	echo "note: using the release's gen_spl-unlock (x86-64). It is given a copy,"
	echo "      because it deletes the file it patches."
	cp -f "$spl" "$work/splloader.bin"
	if ! ( cd "$work" && "$bin" splloader.bin ); then
		echo "gen_spl-unlock failed. splloader was not erased."
		return 1
	fi
	if [[ ! -s $out ]]; then
		echo "gen_spl-unlock did not write spl-unlock.bin. splloader was not erased."
		return 1
	fi
	return 0
}

# Release-menu unlock. fdl2-cboot.bin ships per model for every chip+brand the
# menu offers (fdl/<soc>/<brand>/) and for the ums9230 alternatif sub-models
# (fdl/ums9230/<brand>/alternatif/<model>/, from the root release package).
# The generic ums9230 "universal" set has none: the vendor zip's file there
# was just its fdl2-dl.bin, so unlock refuses it. A missing blob, or a
# missing dump, does not continue into the erase. --dangerous is not passed.
unlock_bootloader_menu() {
	local cboot unlock can_gen=0 work spl uboot slotf rc erase_rc=0
	if [[ ${DEVICE:-} == universal ]]; then
		echo "DANGEROUS unlock: nothing sent."
		echo "The generic 'universal' loader set has no model-specific fdl2-cboot.bin"
		echo "(the vendor zip's copy was only fdl2-dl.bin under another name, which is"
		echo "not an unlock uboot). Pick your phone's own brand/model in menu [3] first."
		return 1
	fi
	cboot=$(find_model_file fdl2-cboot.bin || true)
	unlock=$(find_model_file spl-unlock.bin || true)
	if [[ -z $unlock ]]; then
		if spdhost_has_image_tools; then
			can_gen=1
		elif find_gen_spl_unlock >/dev/null 2>&1; then
			can_gen=1
		fi
	fi
	if [[ -z $cboot || ( -z $unlock && $can_gen == 0 ) ]]; then
		echo "DANGEROUS unlock: nothing sent."
		if [[ -z $cboot ]]; then
			echo "Missing fdl2-cboot.bin."
			echo "  looked only beside the loaders: $(dirname "${FDL1:-<fdl1>}")/fdl2-cboot.bin"
			if [[ -n ${DEVICE:-} ]]; then
				echo "  (model ${SOC:-?}/$DEVICE: only fdl/${SOC:-?}/$DEVICE is searched, and the"
				echo "  loaders must come from that folder)"
			else
				echo "  (no model picked: put this phone's fdl2-cboot.bin beside the FDL1 you"
				echo "  configured, or pick the model in menu [3]; no other folder is searched)"
			fi
			echo "This is a vendor blob, one per model (fdl/<chip>/<brand>/ and"
			echo "fdl/ums9230/<brand>/alternatif/<model>/). It is not derivable from"
			echo "the other files, and another phone's copy must not be used, so"
			echo "nothing is written."
		fi
		if [[ -z $unlock && $can_gen == 0 ]]; then
			echo "Missing spl-unlock.bin, and nothing here can build it."
			echo "The release package ships gen_spl-unlock beside its menu.sh"
			echo "(x86-64, PC only). A current spdhost builds it on the phone."
		fi
		return 1
	fi
	if [[ -z $unlock ]]; then
		echo "spl-unlock.bin is missing; it is built from the backup, before the erase."
	fi
	echo "DANGEROUS: Unlock BootLoader."
	echo "This follows the release menu: back up splloader and uboot, erase splloader"
	echo "and splloader_bak, write fdl2-cboot.bin to uboot, send spl-unlock.bin as FDL1"
	echo "(no FDL2), read 64 bytes at miscdata+8192, then write the backup back."
	echo "After the erase the phone will not boot until that last write."
	echo "Hold the download-mode keys and stay in download mode between the pauses."
	if ! confirm_dangerous "type dangerous to unlock the bootloader: "; then
		return 1
	fi
	need_loaders || return 1
	# U1: the restore point is always taken in THIS run, from THIS phone, into
	# a folder of its own. An older backup_spl/ may come from another unit or
	# from the firmware before an OTA, and writing that back over an erased
	# splloader is a wrong-device flash, so nothing from an earlier run is
	# reused or restored. It is 256 KiB plus uboot, so the cost is one session.
	work=$PWD/backup_spl/unlock-$(date +%Y%m%d-%H%M%S)
	[[ -e $work ]] && work=$work-$$
	if ! mkdir -p "$work"; then
		echo "Cannot create $work. Nothing sent."
		return 1
	fi
	spl=$work/splloader.img
	echo "Backing up splloader and uboot into $work (a new folder for this run;"
	echo "an earlier backup is never reused). Nothing is erased in this session."
	echo "splloader is read as 256 KiB, the size the release menu's r splloader uses."
	ready || return 1
	if ! run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" \
		read-part splloader 0 262144 "$spl" \
		dump uboot "$work" reset; then
		echo "Backup failed. splloader was not erased. Nothing further sent."
		return 1
	fi
	# Only a whole 256 KiB read is a usable restore point: a shorter file
	# written back over the erased loader leaves the phone unbootable.
	if [[ ! -s $spl || $(stat -c %s "$spl" 2>/dev/null || echo -1) != 262144 ]] \
		|| ! uboot=$(unlock_pick_uboot "$work"); then
		echo "Backup files are missing or short ($spl: $(stat -c %s "$spl" 2>/dev/null || echo none) bytes)."
		echo "splloader was not erased. Nothing further sent."
		return 1
	fi
	echo "Backup: $spl and $uboot."
	# G2: every refusal that depends on the table happens HERE, before the
	# erase -- not as a write refused after splloader is already gone.
	unlock_preflight "$cboot" "$uboot" "$work" || return 1
	if [[ -z $unlock ]]; then
		unlock=$work/spl-unlock.bin
		echo "Building spl-unlock.bin from $spl."
		unlock_make_spl_unlock "$work" "$spl" || return 1
	fi
	echo "DANGEROUS: next session erases splloader_bak, then splloader, then reset."
	echo "spdhost asks for the word dangerous once. That answer covers both erases."
	echo "Any other answer sends nothing."
	echo "The backup stays in $work."
	pause || return 1
	ready || return 1
	erase_rc=0
	# U2: splloader_bak first. spdhost stops the session at the first refused
	# erase, so a loader that will not erase splloader_bak now leaves
	# splloader untouched, instead of exiting after splloader is already gone.
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		danger-erase splloader_bak danger-erase splloader reset || erase_rc=$?
	if (( erase_rc != 0 )); then
		echo "Erase session failed (exit $erase_rc)."
		echo "splloader_bak is erased first, so if that erase was the one refused,"
		echo "splloader was never erased (see the session output above)."
		echo "The unlock loader is skipped. The last session still writes $work back."
	fi
	if (( erase_rc == 0 )); then
	echo "Next session writes $cboot onto uboot (the active slot name) only."
	echo "spdhost asks you to type yes for that write."
	echo "A file larger than the uboot partition is refused, and the backup is written back."
	pause || { unlock_restore_help "$spl" "$uboot"; return 1; }
	ready || { unlock_restore_help "$spl" "$uboot"; return 1; }
	rc=0
	# G2: write-part-plain: uboot only. A NAME_bak twin (non-A/B) is never
	# given the cboot image and the table is never re-sent for it.
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" write-part-plain uboot "$cboot" reset || rc=$?
	if [[ $rc != 0 ]]; then
		echo "Modified uboot was not written (exit $rc). Skipping the unlock loader."
	else
		echo "Next session sends spl-unlock.bin as FDL1 and does not load FDL2."
		echo "The release menu treats a disconnect ('perangkat dilepas') as success."
		pause || { unlock_restore_help "$spl" "$uboot"; return 1; }
		ready || { unlock_restore_help "$spl" "$uboot"; return 1; }
		run_session fdl "$unlock" "$FDL1_ADDR" || \
			echo "Unlock loader returned non-zero. Continuing to the status read."
		echo "Next session reads 64 bytes at miscdata offset 8192."
		echo "Release-menu note: 64 zero bytes means locked; 32 bytes of text plus two 16-byte hashes means unlocked."
		echo "This tool prints the bytes. It does not decide the lock state beyond that note."
		pause || { unlock_restore_help "$spl" "$uboot"; return 1; }
		ready || { unlock_restore_help "$spl" "$uboot"; return 1; }
		slotf=$work/unlock-status.bin
		run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
			read-part miscdata 8192 64 "$slotf" reset || \
			echo "Status read failed."
		unlock_describe_status "$slotf"
	fi
	fi
	echo "Last session writes the dumped splloader and $(basename "$uboot") back, then reset."
	echo "The uboot copy goes to $(unlock_uboot_row "$uboot"), the row it was dumped from."
	echo "spdhost asks you to type yes for each of those writes."
	pause || { unlock_restore_help "$spl" "$uboot"; return 1; }
	ready || { unlock_restore_help "$spl" "$uboot"; return 1; }
	# This is the write that makes the phone bootable again: splloader is still
	# erased from the session above. Its failure used to fall out of the case
	# arm unchecked, so the menu moved on with the phone unbootable and said
	# nothing. Say it loudly instead, and point at the two files that fix it.
	# U4: the uboot backup goes back to the row it was dumped from (its own
	# file name: uboot_a, uboot_b or uboot), not to whatever slot is active now.
	# G2: the two writes are reported apart (SPDHOST_STATUS_FILE: one
	# write-NAME=ok|failed|started line each), so a refused uboot write is
	# not reported as "splloader is still erased" when splloader was written.
	local st row wspl wub
	row=$(unlock_uboot_row "$uboot")
	st=$(mktemp "$(spd_tmpdir 2>/dev/null || echo /tmp)/spdhost-status.XXXXXX" 2>/dev/null) || st=
	rc=0
	SPDHOST_STATUS_FILE=$st run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" \
		write-part-plain splloader "$spl" write-part-plain "$row" "$uboot" reset || rc=$?
	wspl=$( [[ -n $st ]] && awk -F= '$1 == "write-splloader" { v = $2 } END { print v }' "$st" 2>/dev/null)
	wub=$( [[ -n $st ]] && awk -F= -v k="write-$row" '$1 == k { v = $2 } END { print v }' "$st" 2>/dev/null)
	[[ -n $st ]] && rm -f "$st"
	if (( rc == 0 )); then
		echo "Restore: splloader written, $row written."
		return 0
	fi
	echo
	case $wspl in
		ok) echo "splloader: RESTORED (written from $spl); the phone has its loader back." ;;
		failed|started) echo "splloader: NOT restored (the write was refused or failed); it is still erased." ;;
		*) echo "splloader: NOT restored (the session stopped before that write); it is still erased." ;;
	esac
	case $wub in
		ok) echo "$row: restored from $uboot." ;;
		failed|started) echo "$row: NOT restored (the write was refused or failed)." ;;
		*) echo "$row: NOT restored (the session stopped before that write)." ;;
	esac
	if [[ $wub != ok ]]; then
		if (( erase_rc == 0 )); then
			echo "  $row may still hold $(basename "$cboot") from the unlock step, not your backup."
		else
			echo "  The unlock step never wrote $row, so it should still hold the stock image."
		fi
	fi
	if [[ $wspl != ok ]]; then
		echo
		echo "RESTORE FAILED. splloader is still erased and the phone will not boot."
		echo "Do not unplug. Keep it in download mode and run this session again"
		echo "until it succeeds; the backups are still on disk:"
	else
		echo
		echo "RESTORE INCOMPLETE: only $row is left. Run the restore again for it;"
		echo "the backups are still on disk:"
	fi
	echo "  $spl"
	echo "  $uboot"
	echo "spdhost writes an image only after you type yes, so a lost USB"
	echo "connection or an aborted prompt is the usual cause, not bad files."
	unlock_restore_help "$spl" "$uboot"
	return 1
}

# G2: the unlock's checks that need the live table, run after the backup
# session read it and BEFORE the erase. Each refusal leaves the phone as it
# was: nothing erased, nothing written.
#   - the table's unit must be known (a guessed unit cannot size uboot),
#   - non-A/B (no uboot_a / uboot_b row) is refused outright: the reference's
#     non-A/B write goes through a temporary repartition (w_force) and also
#     overwrites uboot_bak, while splloader is erased, and a plain uboot write
#     has not been proven on a real non-A/B phone yet,
#   - fdl2-cboot.bin must fit the uboot row it will be written to.
unlock_preflight() {
	local cboot=$1 uboot=$2 work=$3 bytes row rowsz csz
	bytes=$(parts_bytes_path)
	if ! load_parts_state || [[ ! -s $bytes ]]; then
		echo "UNLOCK REFUSED: the backup session left no partition table, so the menu"
		echo "cannot check this phone's layout. Nothing was erased or written."
		echo "The backup stays in $work."
		return 1
	fi
	if [[ $PARTS_VERIFIED == 0 || ( -z $PARTS_VERIFIED && $PARTS_SHIFT != 10 ) ]]; then
		echo "UNLOCK REFUSED: this table's size unit is a guess the device did not confirm"
		echo "(shift $PARTS_SHIFT), so the uboot size cannot be checked."
		echo "Nothing was erased or written. The backup stays in $work."
		return 1
	fi
	if ! grep -qE '^uboot_[ab][[:space:]]' "$bytes"; then
		echo "UNLOCK REFUSED: this phone is not A/B (its table has no uboot_a / uboot_b)."
		echo "On a non-A/B phone the unlock would have to write uboot while splloader is"
		echo "erased, and spd_dump does that with a temporary repartition that also"
		echo "overwrites uboot_bak. That path has not been proven on a real non-A/B"
		echo "phone, so it is not offered yet. Nothing was erased or written."
		echo "The backup stays in $work."
		return 1
	fi
	row=$(unlock_uboot_row "$uboot")
	rowsz=$(awk -v n="$row" '$1 == n { print $2; exit }' "$bytes")
	csz=$(stat -c %s "$cboot" 2>/dev/null || echo -1)
	if [[ ! $rowsz =~ ^[0-9]+$ ]] || (( rowsz <= 0 )); then
		echo "UNLOCK REFUSED: $row is not in the live table. Nothing was erased or written."
		return 1
	fi
	if (( csz <= 0 || csz > rowsz )); then
		echo "UNLOCK REFUSED: $(basename "$cboot") is $csz bytes and $row is $rowsz bytes;"
		echo "it would be refused after the erase. Nothing was erased or written."
		return 1
	fi
	return 0
}

# M4: after the erase session the phone has no splloader until the last
# session writes the backup back. Every way out of the unlock past that point
# prints the backup paths and the exact command that restores them, so a
# dropped cable, an EOF at a pause or a failed restore never leaves the user
# without the next step. The command is the menu's own restore session,
# spelled out (typed yes for each write; no --yes).
unlock_restore_help() {
	local spl=$1 uboot=$2 ea stub
	local -a cmd=("${RUNNER[@]}" --timeout "${SPDHOST_TIMEOUT:-3000}")
	ea=$(exec_addr_value 2>/dev/null) || ea=
	if [[ -n $ea ]] && stub=$(exec_stub_path "$ea" 2>/dev/null); then
		cmd+=(exec_addr "$ea" "$stub")
	fi
	cmd+=(fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" parts "$(parts_cache_path)"
		write-part-plain splloader "$spl" write-part-plain "$(unlock_uboot_row "$uboot")" "$uboot" reset)
	echo
	echo "splloader may still be erased. An erased SPL should still drop into BootROM download mode"
	echo "(power off, hold the download-mode keys, plug in), so it is recoverable with this tool."
	echo "Backups:"
	echo "  splloader: $spl"
	echo "  uboot:     $uboot"
	echo "Restore command (from $PWD; it asks you to type yes for each write):"
	printf '  '
	printf '%q ' "${cmd[@]}"
	echo
}

# U4: the partition a uboot backup belongs to is in its file name
# (unlock_pick_uboot only returns uboot.img, uboot_a.img or uboot_b.img).
unlock_uboot_row() {
	local b
	b=$(basename "$1" .img)
	case $b in
		uboot|uboot_a|uboot_b) printf '%s\n' "$b" ;;
		*) printf 'uboot\n' ;;
	esac
}

unlock_pick_uboot() {
	local d=$1 tag name pick= slotpick= want other
	# L5: on A/B the bootloader runs uboot_<active slot>; that copy is the one
	# to patch. ACTIVE_SLOT comes from misc (load_parts_state).
	want=uboot_${ACTIVE_SLOT:-a}
	if [[ $want == uboot_a ]]; then other=uboot_b; else other=uboot_a; fi
	# The manifest names the image this dump actually wrote. An older
	# uboot_a.img left in the folder must not win over a new uboot.img.
	if [[ -f $d/dump-manifest.txt ]]; then
		while read -r tag name _; do
			[[ $tag == ok ]] || continue
			case $name in
				uboot|uboot_a|uboot_b)
					if [[ -s $d/$name.img ]]; then
						pick=$d/$name.img
						[[ $name == "$want" ]] && slotpick=$d/$name.img
					fi
					;;
			esac
		done < "$d/dump-manifest.txt"
	fi
	if [[ -n $slotpick ]]; then
		printf '%s\n' "$slotpick"
		return 0
	fi
	if [[ -n $pick ]]; then
		printf '%s\n' "$pick"
		return 0
	fi
	if [[ -s $d/uboot.img ]]; then printf '%s\n' "$d/uboot.img"; return 0; fi
	if [[ -s $d/$want.img ]]; then printf '%s\n' "$d/$want.img"; return 0; fi
	if [[ -s $d/$other.img ]]; then printf '%s\n' "$d/$other.img"; return 0; fi
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
	echo "Offset 0x7B is the low byte of the AVB header's flags word (big-endian, 0x78-0x7B):"
	echo "bit0 = hashtree (dm-verity) disabled, bit1 = verification disabled."
	echo "verity 0 writes 0x01 at 0x7B of vbmeta (the active slot name): dm-verity off."
	echo "verity 1 writes 0x00 at 0x7B of vbmeta, vbmeta_system, vbmeta_vendor,"
	echo "vbmeta_system_ext, vbmeta_product, and vbmeta_odm. A missing name is skipped."
	echo "WARNING: the flags are inside the signed vbmeta header. A patched vbmeta boots"
	echo "only with an UNLOCKED bootloader; on a locked one the phone refuses to boot"
	echo "until verity 1 (or the saved original) is written back."
	echo "Each partition must start with the AVB0 magic or it is not touched. The original"
	echo "is saved to $DUMP_DIR/vbmeta-before-<name>-<time>.img (sha256 in SHA256SUMS)"
	echo "before the whole partition is rewritten. Over 64MB is refused."
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
	mkdir -p "$DUMP_DIR" || { echo "Cannot create $DUMP_DIR for the vbmeta backup. Nothing sent."; return 1; }
	local mark rc f
	mark=$(mktemp "$(spd_tmpdir)/spdhost-verity.XXXXXX") || mark=
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" verity "$which" "$DUMP_DIR" reset
	rc=$?
	# V1: every original this session saved gets a SHA256SUMS line, whether or
	# not the write after it went through.
	if [[ -n $mark ]]; then
		while IFS= read -r f; do
			[[ -s $f ]] && { echo "Original vbmeta saved: $f"; record_sha256 "$f" || true; }
		done < <(find "$DUMP_DIR" -maxdepth 1 -name 'vbmeta-before-*.img' -newer "$mark" 2>/dev/null)
		rm -f "$mark"
	fi
	return $rc
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
	local rc=$?
	# spdhost only erases persist after the read comes back whole, so a nonzero
	# exit means the backup is untrustworthy. A good one gets a SHA256SUMS line
	# like every other read in this menu.
	if (( rc == 0 )) && [[ -s $out ]]; then
		record_sha256 "$out" || true
	fi
	return $rc
}

# spd_dump chip_uid, read-only: the BSL answer printed as hex. No write, no
# erase, no reboot, so no typed confirm is needed -- but the loaders still have
# to come up, which is the only reason this needs a phone in download mode.
# Not in the release menu (it never calls chip_uid); spdhost has had the command
# since the first build, so the menu surfaces it here.
chip_uid_action() {
	need_loaders || return 1
	echo "Read-only: spdhost asks the BootROM/FDL for the chip UID."
	echo "spd_dump prints it as a string; this prints the bytes as hex."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" chip-uid "$(read_only_ending)"
}

# Read-only: one session that refreshes the table and prints the byte size
# spdhost resolves for one name (the same table a dump or a write uses). It is
# the way to confirm the cached table still matches the phone after a
# repartition. part-size, not check-part: spd_dump's check_part prints 0/1
# ("Checks if the specified partition exists"), and the byte count is its
# separate size_part / part_size command.
check_part_action() {
	local name
	need_loaders || return 1
	read -r -p "Partition name (boot, boot_a, misc, ...): " name
	if [[ -z ${name:-} ]]; then
		echo "Cancelled."
		return 1
	fi
	if [[ ! $name =~ ^[A-Za-z0-9_]+$ ]]; then
		echo "A partition name is letters, digits and _ only." >&2
		return 1
	fi
	echo "Read-only: parts, then part-size $name. Nothing is written."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" part-size "$name" "$(read_only_ending)"
}

# erase-part clears one partition. persist, splloader, splloader_bak and all
# are refused in spdhost itself (that guard is in C and stays there, so it also
# holds for a hand-typed spdhost-usb command); everything else is real data
# loss, so it needs the typed word and the menu still passes no --yes --
# spdhost asks on the terminal as well.
erase_part_action() {
	local name
	need_loaders || return 1
	echo "erase-part clears one partition on the phone. It cannot be undone."
	echo "spdhost refuses: persist, persist_a, persist_b, splloader, splloader_bak, all."
	echo "A name without _a/_b is resolved like spd_dump: boot erases boot_a on a slot-a phone."
	echo "userdata is refused here: erasing it directly leaves recovery nothing to format."
	echo "For a factory reset use [10] -> [1] (wipe BCB via recovery)."
	read -r -p "Partition name to erase: " name
	if [[ -z ${name:-} ]]; then
		echo "Cancelled."
		return 1
	fi
	if [[ ! $name =~ ^[A-Za-z0-9_]+$ ]]; then
		echo "A partition name is letters, digits and _ only." >&2
		return 1
	fi
	# Refused in spdhost too; saying it here first means not asking anyone to
	# type "dangerous" for something that would be refused anyway.
	case $name in
		persist|persist_a|persist_b|splloader|splloader_bak|all|erase_all)
			echo "Refusing: spdhost never erases $name." >&2
			return 1
			;;
	esac
	case $name in
		userdata|userdata_a|userdata_b)
			echo "Refusing: erase-part $name leaves recovery nothing to format. Use [10] -> [1] for a factory reset." >&2
			return 1
			;;
	esac
	if ! confirm_dangerous "type dangerous to erase $name: "; then
		return 1
	fi
	echo "spdhost asks once more on the terminal before it erases."
	ready || return 1
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		parts "$(parts_cache_path)" erase-part "$name" "$BOOT_AFTER"
}

# Offline: patch a dumped misc image so it names slot a or b. This is the same
# pack-slot that set_slot_menu hashes for its --confirm-token; here it only
# writes a file, nothing is sent and no phone is needed. The slot block is
# misc+0x800, so a 2048-byte image is not enough on its own -- use a full misc
# dump.
pack_slot_action() {
	local bin in out which
	bin=$(resolve_spdhost_bin) || { echo "spdhost binary not found (make)." >&2; return 1; }
	read -r -p "misc image [$DUMP_DIR/misc.img]: " in
	in=${in:-$DUMP_DIR/misc.img}
	if [[ ! -f $in ]]; then
		echo "No such file: $in" >&2
		return 1
	fi
	read -r -p "Slot to make active [a/b]: " which
	which=${which,,}
	case $which in
		a|b) ;;
		*) echo "Choose a or b." >&2; return 1 ;;
	esac
	out=${in%.img}-slot$which.img
	if ! "$bin" pack-slot "$which" "$in" "$out"; then
		echo "pack-slot failed; nothing usable was written." >&2
		rm -f "$out"
		return 1
	fi
	echo "Wrote $out: the image for slot $which, same size as $in."
	record_sha256 "$out" || true
	# [6] and [7] take a file's name as its partition name, so misc-slot$which.img
	# is skipped there as "not in the table" and the slot never changes (L1).
	# Write it here instead, through the same guarded misc session set-slot
	# uses: typed yes, --confirm-token for these exact bytes, backup first,
	# read-back after. The image is built from $in, so the write session also
	# checks that the phone's misc still IS $in (misc-backup-expect) and stops
	# before writing if it is not -- a stale dump never reverts newer misc.
	echo "Menus [6] and [7] cannot flash this file: they use the file name as the"
	echo "partition name, and 'misc-slot$which' is not a partition."
	echo "To change the slot on the phone, either write it now (below), or use"
	echo "[10] -> [2] Set active slot, which reads misc live and does the same."
	local ans digest in_sha ending=reset rc
	read -r -p "Write $out to misc on the phone now? [y/N]: " ans || ans=
	while [[ $ans == *[$' \t\r\n'] ]]; do ans=${ans%?}; done
	case $ans in
		y|Y|yes) ;;
		*) echo "Not written. The file stays at $out."; return 0 ;;
	esac
	need_loaders || return 1
	if [[ ! -t 0 ]]; then
		echo "refusing to write misc without a TTY (no silent --yes)" >&2
		return 1
	fi
	[[ $BOOT_AFTER == power-off ]] && ending=power-off
	in_sha=$(sha256sum "$in" | awk '{print $1}')
	digest=$(sha256sum "$out" | awk '{print $1}')
	echo "About to write $(stat -c %s "$out") bytes to partition 'misc' (active slot $which), then $ending."
	echo "The phone's misc must still be exactly $in (sha256 $in_sha), or nothing is written."
	echo "misc image sha256: $digest"
	echo "Wrong chip/FDL or a mis-click can soft-brick the boot path."
	if ! menu_typed_yes "type yes to write the slot $which image to misc: " "$digest"; then
		return 1
	fi
	MISC_EXPECT_SHA=$in_sha
	guarded_misc_session "slot $which image" write-part misc "$out" "$ending"
	rc=$?
	return "$rc"
}

# True when the resolved spdhost has the built-in PAC reader. Probed the same
# way as spdhost_has_image_tools: run it with no arguments and look for its
# usage line, so an older spdhost degrades to a clear message instead of
# failing in the middle of an extract.
spdhost_has_unpac() {
	local bin out
	bin=$(resolve_spdhost_bin 2>/dev/null) || return 1
	[[ -n $bin ]] || return 1
	out=$("$bin" unpac 2>&1 || true)
	[[ $out == *"unpac [-d dir]"* ]]
}

# Offline: list, verify, and extract a PAC firmware. The release ships
# extrac.sh plus an x86-64 pacextractor, which only runs on a PC; this is the
# same job built into spdhost, so it also works on the phone. Nothing is sent
# over USB and no phone is needed.
pac_extract_action() {
	local bin pac mode dir e pick want out rc
	bin=$(resolve_spdhost_bin) || { echo "spdhost binary not found (make)." >&2; return 1; }
	if ! spdhost_has_unpac; then
		echo "This spdhost has no built-in PAC reader (unpac)." >&2
		echo "Rebuild it (make), or use the release's extrac.sh on a PC." >&2
		return 1
	fi
	# The usual case is one .pac in the flash folder: offer it as the default.
	pac=""
	for e in "$INPUT_DIR"/*.pac; do
		[[ -f $e ]] || continue
		pac=$e
		break
	done
	read -r -p "PAC file${pac:+ [$pac]}: " want
	pac=${want:-$pac}
	[[ -n $pac ]] || { echo "No .pac given and none in $INPUT_DIR." >&2; return 1; }
	[[ -f $pac ]] || { echo "No such file: $pac" >&2; return 1; }
	echo
	echo "== $pac =="
	"$bin" unpac list "$pac" || { echo "unpac list failed: not a PAC?" >&2; return 1; }
	echo
	echo "[1] Verify the CRCs (check)"
	echo "[2] Extract every entry"
	echo "[3] Extract chosen entries"
	echo "[0] Back"
	read -r -p "Choice: " mode
	case ${mode:-} in
		0) echo "Back to the menu."; return ;;
		1)
			out=$("$bin" unpac check "$pac" 2>&1)
			rc=$?
			printf '%s\n' "$out"
			if (( rc != 0 )); then
				echo "unpac check failed (exit $rc)." >&2
				return 1
			fi
			# The exit status is the vendor's, and it is 0 even when the
			# stored CRC and the computed one differ, so the text is what
			# reports a bad pac. Saying so here is the whole point of
			# offering check: a silent 0 would read as "verified".
			if [[ $out == *"(expected"* ]]; then
				echo "MISMATCH: this pac is corrupt or truncated." >&2
				return 1
			fi
			echo "CRCs match."
			return
			;;
		2) pick= ;;
		3)
			read -r -p "Entries (space separated; * and ? work): " pick
			[[ -n ${pick:-} ]] || { echo "No entries given." >&2; return 1; }
			;;
		*) echo "Unchanged."; return ;;
	esac
	read -r -p "Output folder [$INPUT_DIR/extract]: " dir
	dir=${dir:-$INPUT_DIR/extract}
	mkdir -p "$dir" || { echo "Cannot create $dir." >&2; return 1; }
	# shellcheck disable=SC2086 -- the word split IS the entry list.
	if "$bin" unpac -d "$dir" extract "$pac" $pick; then
		echo "Extracted into $dir"
		echo "Flash one from menu [6], or move it into $INPUT_DIR."
	else
		echo "unpac extract failed; $dir may hold a partial set." >&2
		return 1
	fi
}

extra_menu() {
	local choice
	echo "Extra"
	echo "[1] Factory reset (recovery wipe BCB; does not erase persist)"
	echo "[2] Set active slot (a/b)"
	echo "[3] Power off"
	echo "[4] DANGEROUS: verity (vbmeta byte 0x7B; type the word dangerous)"
	echo "[5] DANGEROUS: reset FRP (backup persist, then erase it)"
	echo "[6] Reboot recovery"
	echo "[7] Reboot fastbootd (Android 10+ recovery)"
	echo "[8] DANGEROUS: unlock bootloader (erases splloader until the last step)"
	echo "[9] Hex mode (exec_addr $EXEC_ADDR_DEFAULT / $EXEC_ADDR_ALT)"
	echo "[10] Boot mode after flash / restore (now: $BOOT_AFTER)"
	echo "[11] Read the chip UID (read-only; spd_dump's chip_uid)"
	echo "[12] Check one partition's live size (read-only)"
	echo "[13] DANGEROUS: erase one partition (type the word dangerous)"
	echo "[14] Build a slot a/b misc image from a dump (offline, no phone)"
	echo "[15] Storage folders: shared storage (/sdcard) or the package"
	echo "[16] Extract a PAC firmware (offline, no phone)"
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
		11) continue_choice "read the chip UID" || return ;;
		12) continue_choice "check a partition's live size" || return ;;
		13) continue_choice "erase a partition" || return ;;
		14) continue_choice "build a slot image" || return ;;
		15) continue_choice "storage folders" || return ;;
		16) continue_choice "extract a PAC" || return ;;
		*) echo "Unchanged."; return ;;
	esac
	case $choice in
		1) wipe_userdata_action ;;
		2) set_slot_menu ;;
		3)
			need_loaders || return
			if confirm_action "type yes to power off: "; then
				ready || return
				if ! run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" power-off; then
					echo "The power-off command failed. The phone is still in download mode"
					echo "and its battery is still draining; unplug it to leave that state."
				fi
			fi
			;;
		4) verity_menu ;;
		5) frp_reset_menu ;;
		6)
			need_loaders || return
			if confirm_reboot_cmd reboot-recovery; then
				guarded_misc_session reboot-recovery reboot-recovery
			fi
			;;
		7)
			need_loaders || return
			if confirm_reboot_cmd reboot-fastboot; then
				guarded_misc_session reboot-fastboot reboot-fastboot
			fi
			;;
		8) unlock_bootloader_menu ;;
		9) hex_mode_menu ;;
		10) boot_after_menu ;;
		11) chip_uid_action ;;
		12) check_part_action ;;
		13) erase_part_action ;;
		14) pack_slot_action ;;
		15) storage_switch_menu ;;
		16) pac_extract_action ;;
	esac
}

# Test hook: SPDHOST_MENU_LIB=1 + `source menu.sh` loads functions only.
if [[ ${SPDHOST_MENU_LIB:-} == 1 ]]; then
	return 0 2>/dev/null || exit 0
fi

load_config
# First run: ask for the phone details and FDLs, with the generic set offered
# as "universal". A saved config, a non-TTY stdin, or SPDHOST_ALLOW_DEFAULT_FDL
# all take the silent paths inside.
setup_wizard
# After load_config, because the saved config is what picks the layout.
apply_storage_mode
mkdir -p "$INPUT_DIR" || echo "Could not create $INPUT_DIR" >&2
mkdir -p "$DUMP_DIR" || echo "Could not create $DUMP_DIR" >&2

while true; do
	cls
	echo "spdhost test menu"
	echo "wrapper: ${RUNNER[0]}"
	echo "FDL1: ${FDL1:-unset} ${FDL1_ADDR:-}"
	echo "FDL2: ${FDL2:-unset} ${FDL2_ADDR:-}"
	echo "Folders: $(storage_describe)"
	echo "Dumps go to: $DUMP_DIR"
	echo "Flash input: $INPUT_DIR"
	if [[ $INPUT_DIR == "$DUMP_DIR" ]]; then
		echo "  (one folder: menu [1] writes here, menu [6] reads here)"
	fi
	echo "Device: ${DEVICE:-unset} ${SOC:+($SOC)}"
	echo "After flash/restore: $BOOT_AFTER"
	echo
	echo "[1] Dump partitions (one name, several names, all, all_lite, or imei)"
	echo "[2] Reboot into a mode"
	echo "[3] Change loader files (shipped models, or your own paths)"
	echo "[4] List partitions only"
	echo "[5] Smoke test (safe checks, no writes)"
	echo "[6] Flash images from $INPUT_DIR"
	echo "[7] Restore a backup folder"
	echo "[8] Repartition from XML"
	echo "[9] Copy dumped images into the flash folder ($INPUT_DIR)"
	echo "[10] Extra (slot, hex mode, DANGEROUS unlock / verity / FRP)"
	echo "[0] Quit"
	echo "After a number: y continues, n goes back."
	# EOF (Ctrl-D, or stdin that ran out) has to end the loop: read leaves
	# choice empty, the `*` arm only prints "Not a choice." and pause() reads
	# EOF again, so the old code spun here forever without ever accepting input.
	if ! read -r -p "Choice: " choice; then
		echo
		echo "Input closed. Bye."
		exit 0
	fi
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
		9) continue_choice "copy dumps into the flash folder" || { pause; continue; }
			promote_dump_action; pause ;;
		10) continue_choice "extra menu" || { pause; continue; }
			extra_menu; pause ;;
		0) continue_choice "quit" && exit 0
			pause ;;
		*) echo "Not a choice."; pause ;;
	esac
done
