#!/usr/bin/env bash
# Termux P0 A/B BootROM hello smoke menu for spdhost.
# This menu only selects existing spdhost-usb environment knobs; it does not
# change the hello protocol or any C sources.
set -u

script_dir=$(cd "$(dirname "$0")" && pwd -P)
RUNNER=""

# Prefer package/script locations over PATH so unzipped arm32 packages use
# their own updated spdhost-usb (timing breadcrumbs + warm-path shrink).
for cand in \
	"$script_dir/spdhost-usb" \
	"$PWD/scripts/spdhost-usb" \
	"$PWD/spdhost-usb"
do
	if [[ -x $cand && -f $cand ]]; then
		RUNNER=$(cd "$(dirname "$cand")" && printf '%s/%s' "$(pwd -P)" "$(basename "$cand")")
		break
	fi
done
if [[ -z $RUNNER ]]; then
	if cand=$(command -v spdhost-usb 2>/dev/null) && [[ -f $cand && -x $cand ]]; then
		RUNNER=$(cd "$(dirname "$cand")" && printf '%s/%s' "$(pwd -P)" "$(basename "$cand")")
	fi
fi

if [[ -z $RUNNER ]]; then
	echo "spdhost-usb not found in the package or on PATH." >&2
	echo "Run this from the unzipped spdhost-arm32 root, or put spdhost-usb on PATH." >&2
	exit 1
fi

pause_after_run() {
	read -r -p "Press Enter to return to the menu..." _
}

print_cmd() {
	printf '+ '
	printf '%q ' "$@"
	printf '\n'
}

run_smoke() {
	local choice=$1
	local -a cmd=(env
		-u SPDHOST_BROM_TRACE
		-u SPDHOST_BROM_SETTLE_MS
		-u SPDHOST_BROM_PAUSE_MS
		-u SPDHOST_BROM_WALL_MS
		-u SPDHOST_BROM_DRAIN
		-u SPDHOST_BROM_REACQ
		SPDHOST_BROM_TRACE=1)

	case $choice in
		1) ;;
		2) cmd+=(SPDHOST_BROM_SETTLE_MS=0) ;;
		3) cmd+=(SPDHOST_BROM_PAUSE_MS=0) ;;
		4) cmd+=(SPDHOST_BROM_WALL_MS=30000) ;;
		5) cmd+=(SPDHOST_BROM_DRAIN=1 SPDHOST_BROM_SETTLE_MS=300) ;;
		6) cmd+=(SPDHOST_BROM_REACQ=1) ;;
		*) echo "Internal error: unknown smoke option $choice" >&2; return 2 ;;
	esac
	cmd+=("$RUNNER" --timeout 5000 --verbose ping)

	echo "Exact command/env about to execute:"
	print_cmd "${cmd[@]}"
	"${cmd[@]}"
	local rc=$?
	echo "exit code: $rc"
	pause_after_run
	return "$rc"
}

while :; do
	cat <<'MENU'

cold-plug notes — unplug ≥5s between runs, tap Allow fast, power target off then vol-down+plug when wrapper says NOW.
Watch stderr for: usb: listed / usb: termux-usb -e / usb: child start (ms), then brom: open/claim, brom: try 1, version:SPRD3.
Optional fast path: arm 2 (SETTLE=0) is a reasonable first smoke when racing BootROM; default settle stays 100 unless env set. REACQ stays default 0 (only arm 6 enables it).
Warm already-authorized (optional; default keeps -r): export SPD_USB_SKIP_REQUEST=1   # after a successful Allow + cold-unplug ≥5s; unset for first plug

1) Baseline: SPDHOST_BROM_TRACE=1 + ./scripts/spdhost-usb --timeout 5000 --verbose ping
2) SETTLE only: also SPDHOST_BROM_SETTLE_MS=0 (+ TRACE, same ping)  [optional fast path]
3) PAUSE only: SPDHOST_BROM_PAUSE_MS=0 (+ TRACE, same ping)
4) WALL only: SPDHOST_BROM_WALL_MS=30000 (+ TRACE, same ping)
5) DRAIN+SETTLE: SPDHOST_BROM_DRAIN=1 + SPDHOST_BROM_SETTLE_MS=300 (+ TRACE, same ping)
6) REACQ once: SPDHOST_BROM_REACQ=1 (+ TRACE, same ping)
0) quit
MENU
	read -r -p "Select 0-6: " choice || { echo; exit 0; }
	case $choice in
		0) exit 0 ;;
		1|2|3|4|5|6)
			if [[ $choice == 6 ]]; then
				echo "WARNING: stop if you see BUSY / a second Allow; REACQ is only enabled for option 6."
			fi
			run_smoke "$choice" || :
			;;
		*) echo "Choose one of 0, 1, 2, 3, 4, 5, or 6." ;;
	esac
done
