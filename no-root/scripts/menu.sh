#!/usr/bin/env bash
# Test menu for spdhost. Two actions, same shape as the release menu:
#   dump one partition  (the release menu's "r" / Cadangkan Partisi)
#   reboot into a mode  (system, recovery, fastbootd, power off)
#
# It does not unlock, erase, or flash.
# Default loaders are the release's ums9230 Infinix pair:
#   fdl1-dl.bin at 0x65000800, fdl2-dl.bin at 0x9efffe00.
set -u

CONFIG="${SPDHOST_MENU_CONFIG:-$HOME/.spdhost-menu.conf}"
DUMP_DIR="${SPDHOST_DUMP_DIR:-$PWD/backup}"
FDL1_ADDR_DEFAULT=0x65000800
FDL2_ADDR_DEFAULT=0x9efffe00

if command -v spdhost-usb >/dev/null 2>&1; then
	RUNNER=(spdhost-usb)
elif [[ -x "$PWD/scripts/spdhost-usb" ]]; then
	RUNNER=(./scripts/spdhost-usb)
else
	echo "spdhost-usb is not on PATH. From no-root/: cp scripts/spdhost-usb \"\$PREFIX/bin/\"" >&2
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

apply_ums9230_infinix_defaults() {
	local dir
	[[ -n $FDL1_ADDR ]] || FDL1_ADDR=$FDL1_ADDR_DEFAULT
	[[ -n $FDL2_ADDR ]] || FDL2_ADDR=$FDL2_ADDR_DEFAULT
	dir=$(find_infinix_dir) || return 0
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
	echo "Power the target off. This phone is the USB host (OTG)."
	echo "Press Enter, then hold the target's download-mode keys and plug it in."
	echo "Allow the USB permission dialog. The first dialog often misses the BootROM window;"
	echo "if it does, unplug and run this action again."
	pause
}

run_session() {
	echo "+ ${RUNNER[*]} $*"
	"${RUNNER[@]}" "$@"
	local rc=$?
	echo "exit $rc"
	return "$rc"
}

dump_partition() {
	local name size out
	need_loaders || return
	cls
	echo "Dump one partition"
	echo "This is one read, not the release menu's \"all\" / \"all_lite\" list."
	echo "Size is required. Examples: 64M, 32K, 4096, 0x100000"
	read -r -p "Partition name: " name
	if [[ -z $name || $name == */* || $name == *' '* ]]; then
		echo "Name must be one word, like boot or boot_a."
		pause
		return
	fi
	read -r -p "Size: " size
	if [[ -z $size || ! $size =~ ^[0-9a-fA-FxXmMkKgG]+$ ]]; then
		echo "Bad size."
		pause
		return
	fi
	mkdir -p "$DUMP_DIR"
	out="$DUMP_DIR/${name}.img"
	read -r -e -p "Output file [$out]: " reply
	[[ -n ${reply:-} ]] && out=$reply
	echo "Will read $name at offset 0, size $size, into $out"
	ready
	run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
		read-part "$name" 0 "$size" "$out" || true
	pause
}

# Android bootloader control block, first 2048 bytes of misc.
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

reboot_mode() {
	local choice misc
	need_loaders || return
	cls
	echo "Reboot mode"
	echo "[1] system"
	echo "[2] recovery"
	echo "[3] fastbootd"
	echo "[4] power off"
	read -r -p "Choice: " choice
	case $choice in
		1)
			echo "Normal reset after the loaders."
			ready
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" reset || true
			;;
		2)
			misc=$(write_misc_command recovery)
			echo "Writes 2048 bytes at the start of misc, then reset."
			ready
			run_session --yes fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
				write-part misc "$misc" reset || true
			rm -f "$misc"
			;;
		3)
			misc=$(write_misc_command fastboot)
			echo "Writes the fastbootd boot command at the start of misc, then reset."
			ready
			run_session --yes fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" \
				write-part misc "$misc" reset || true
			rm -f "$misc"
			;;
		4)
			echo "Power off. The target stays off."
			ready
			run_session fdl "$FDL1" "$FDL1_ADDR" fdl "$FDL2" "$FDL2_ADDR" power-off || true
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
	echo "[1] Dump a partition"
	echo "[2] Reboot into a mode"
	echo "[3] Change loader files"
	echo "[0] Quit"
	read -r -p "Choice: " choice
	case ${choice:-} in
		1) dump_partition ;;
		2) reboot_mode ;;
		3) configure_loaders; pause ;;
		0) exit 0 ;;
		*) echo "Not a choice."; pause ;;
	esac
done
