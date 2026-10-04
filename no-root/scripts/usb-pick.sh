# Shared list parsing for spdhost-usb and spd_dump-usb. Sourced, not executed.
# A termux-usb -l answer is either a JSON array of paths, or (newer builds)
# objects that also carry vendor_id. Paths are never joined by deleting
# commas. Duplicate paths count once.
#
# Vendor 1782 is a Unisoc phone (BootROM and diag both use it; product id
# is not required). A known other vendor is not opened. With no vendor id
# the choice stays the path-only one these wrappers already used: one new
# path wins immediately, and a single already-attached path is accepted
# after SPD_USB_ATTACHED_GRACE. Sysfs idVendor is consulted only to fill a
# missing vendor, and only when the directory is readable. SPD_USB_NO_SYSFS=1
# skips that. An unreadable sysfs does not change the path-only choice.

usb_now_ms() {
	if [[ -n ${EPOCHREALTIME-} ]]; then
		awk -v t="$EPOCHREALTIME" 'BEGIN { printf "%d", t * 1000 }'
		return
	fi
	local ns
	ns=$(date +%s%N 2>/dev/null) || ns=
	if [[ $ns =~ ^[0-9]+$ && ${#ns} -ge 10 ]]; then
		awk -v t="$ns" 'BEGIN { printf "%d", t / 1000000 }'
		return
	fi
	echo $((SECONDS * 1000))
}

# Sleep only the part of $2 ms that $1 (a usb_now_ms stamp) has not used.
# A clock step backwards does not turn into a long sleep.
usb_pace_since() {
	local start=$1 want=$2 now elapsed left
	now=$(usb_now_ms)
	elapsed=$((now - start))
	if (( elapsed < 0 || elapsed >= want )); then
		return 0
	fi
	left=$(awk -v ms="$((want - elapsed))" 'BEGIN { printf "%.3f", ms / 1000 }')
	sleep "$left"
}

# Print the vendor as hex with no 0x prefix, or nothing.
# Same rules as usb_list.c parse_id/find_id: the key starts at a
# [^A-Za-z0-9_] boundary, only '"', ':', '=' and blanks may sit between the
# key and the value, 0x... is hex, a QUOTED value with no 0x ("1782") is hex
# ID text (sysfs/lsusb style), and an unquoted number (6018) is decimal.
usb_vid_in() {
	local s=$1 hex dec sep='["[:space:]:=]*'
	if [[ $s =~ (^|[^A-Za-z0-9_])vendor_id${sep}0[xX]([0-9A-Fa-f]+) ]]; then
		hex=${BASH_REMATCH[2],,}
		(( ${#hex} > 8 )) && hex=${hex:0:8}
		printf '%x' "0x$hex"
		return 0
	fi
	if [[ $s =~ (^|[^A-Za-z0-9_])vendor_id${sep}\"([0-9A-Fa-f]+) ]]; then
		hex=${BASH_REMATCH[2],,}
		(( ${#hex} > 8 )) && hex=${hex:0:8}
		printf '%x' "0x$hex"
		return 0
	fi
	if [[ $s =~ (^|[^A-Za-z0-9_])vendor_id${sep}([0-9]+) ]]; then
		dec=${BASH_REMATCH[2]}
		if (( ${#dec} > 8 )); then
			return 0
		fi
		printf '%x' "$((10#$dec))"
		return 0
	fi
	return 0
}

# Text after a path, cut at the next path or the closing brace of this
# object, whichever comes first. A vendor_id past '}' belongs to the next
# device. A vendor printed before the path stays unknown.
usb_vendor_window() {
	local rest=$1 cut brace
	cut=${rest%%/dev/bus/usb/*}
	brace=${rest%%\}*}
	if (( ${#brace} < ${#cut} )); then
		printf '%s' "$brace"
	else
		printf '%s' "$cut"
	fi
}

usb_sysfs_root() {
	if [[ -n ${USB_SYSFS_ROOT:-} ]]; then
		printf '%s' "$USB_SYSFS_ROOT"
	else
		printf '%s' /sys/bus/usb/devices
	fi
}

# Fill empty USB_VIDS from busnum/devnum/idVendor. idVendor is hex.
# Give up for this process when the directory cannot be searched or when
# it has entries but none of them publish an idVendor.
usb_sysfs_fill() {
	local root ent bn dn vend bus dev i p rest saw_file=0 any=0 need=0
	local -A map=()
	[[ ${SPD_USB_NO_SYSFS:-0} == 1 ]] && return 0
	[[ ${_usb_sysfs_ok:-1} == 0 ]] && return 0
	(( ${#USB_PATHS[@]} )) || return 0
	for i in "${!USB_VIDS[@]}"; do
		[[ -z ${USB_VIDS[$i]:-} ]] && need=1
	done
	(( need )) || return 0
	root=$(usb_sysfs_root)
	if [[ ! -d $root || ! -r $root || ! -x $root ]]; then
		_usb_sysfs_ok=0
		return 0
	fi
	for ent in "$root"/*; do
		[[ -e $ent ]] || continue
		any=1
		[[ -d $ent ]] || continue
		[[ -r $ent/idVendor && -r $ent/busnum && -r $ent/devnum ]] || continue
		bn= dn= vend=
		IFS= read -r bn < "$ent/busnum" || continue
		IFS= read -r dn < "$ent/devnum" || continue
		IFS= read -r vend < "$ent/idVendor" || continue
		bn=${bn//$'\r'/}
		dn=${dn//$'\r'/}
		vend=${vend//$'\r'/}
		[[ $bn =~ ^[0-9]+$ && $dn =~ ^[0-9]+$ && $vend =~ ^[0-9A-Fa-f]+$ ]] || continue
		saw_file=1
		map["$((10#$bn))/$((10#$dn))"]=$(printf '%x' "0x$vend")
	done
	if (( ! saw_file )); then
		if (( any )); then
			_usb_sysfs_ok=0
		fi
		return 0
	fi
	_usb_sysfs_ok=1
	for i in "${!USB_PATHS[@]}"; do
		[[ -n ${USB_VIDS[$i]:-} ]] && continue
		p=${USB_PATHS[$i]}
		rest=${p#/dev/bus/usb/}
		bus=${rest%%/*}
		dev=${rest#*/}
		[[ $bus =~ ^[0-9]+$ && $dev =~ ^[0-9]+$ ]] || continue
		vend=${map["$((10#$bus))/$((10#$dev))"]-}
		[[ -n $vend ]] || continue
		USB_VIDS[$i]=$vend
	done
}

# Fills USB_PATHS and USB_VIDS ("" when the listing has no vendor_id).
usb_parse_list() {
	local text=$1 line rest vid idx
	local -A seen=()
	USB_PATHS=()
	USB_VIDS=()
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		rest=${text#*"$line"}
		rest=$(usb_vendor_window "$rest")
		vid=$(usb_vid_in "$rest")
		if [[ -n ${seen[$line]:-} ]]; then
			idx=${seen[$line]}
			if [[ -n $vid && -z ${USB_VIDS[$idx]:-} ]]; then
				USB_VIDS[$idx]=$vid
			fi
			continue
		fi
		seen[$line]=${#USB_PATHS[@]}
		USB_PATHS+=("$line")
		USB_VIDS+=("$vid")
	done < <(printf '%s\n' "$text" | grep -oE '/dev/bus/usb/[0-9]+/[0-9]+' || true)
	usb_sysfs_fill
}

# USB_BASE is the path list from the first poll. USB_GRACE / USB_START match
# the wrapper. Sets USB_ACTION to take, wait, or fail; USB_CHOSEN; USB_TAKE_WHY
# (new, unisoc, warm); USB_FAIL_KIND and USB_FAIL_LIST on fail.
# USB_SAW_OTHER sticks at 1 once any poll names a non-1782 vendor. A later
# empty poll does not clear it.
#
# A path that appears after the baseline is the one just plugged in, unless
# its vendor says it is not Unisoc. Several new unidentified paths still
# refuse. After the grace, with nothing new worth opening, the single
# vendor 1782 already on the bus is the phone; a single path with no vendor
# is the old warm accept. A known non-1782 is never that accept.
usb_decide() {
	local -a new=() new_vid=() uni=() unk=() have=()
	local i d seen v grace start b
	USB_ACTION=wait
	USB_CHOSEN=
	USB_TAKE_WHY=
	USB_FAIL_KIND=
	USB_FAIL_LIST=()
	if (( ${#USB_PATHS[@]} )); then
		for i in "${!USB_PATHS[@]}"; do
			v=${USB_VIDS[$i]:-}
			if [[ -n $v && $v != 1782 ]]; then
				USB_SAW_OTHER=1
			fi
			d=${USB_PATHS[$i]}
			seen=0
			if (( ${#USB_BASE[@]} )); then
				for b in "${USB_BASE[@]}"; do
					[[ $b == "$d" ]] && seen=1
				done
			fi
			if (( ! seen )); then
				new+=("$d")
				new_vid+=("$v")
			fi
		done
	fi
	for i in "${!new[@]}"; do
		v=${new_vid[$i]}
		if [[ $v == 1782 ]]; then
			uni+=("${new[$i]}")
		elif [[ -z $v ]]; then
			unk+=("${new[$i]}")
		fi
	done
	if (( ${#uni[@]} > 1 )); then
		USB_ACTION=fail
		USB_FAIL_KIND=many_unisoc
		USB_FAIL_LIST=("${uni[@]}")
		return 0
	fi
	if (( ${#uni[@]} == 1 )); then
		USB_ACTION=take
		USB_CHOSEN=${uni[0]}
		if (( ${#USB_PATHS[@]} > 1 )); then
			USB_TAKE_WHY=unisoc
		else
			USB_TAKE_WHY=new
		fi
		return 0
	fi
	if (( ${#unk[@]} > 1 )); then
		USB_ACTION=fail
		USB_FAIL_KIND=many_new
		USB_FAIL_LIST=("${unk[@]}")
		return 0
	fi
	if (( ${#unk[@]} == 1 )); then
		USB_ACTION=take
		USB_CHOSEN=${unk[0]}
		USB_TAKE_WHY=new
		return 0
	fi
	grace=${USB_GRACE:-0}
	start=${USB_START:-0}
	if (( SECONDS - start < grace )); then
		return 0
	fi
	if (( ${#USB_PATHS[@]} )); then
		for i in "${!USB_PATHS[@]}"; do
			[[ ${USB_VIDS[$i]:-} == 1782 ]] && have+=("${USB_PATHS[$i]}")
		done
	fi
	if (( ${#have[@]} > 1 )); then
		USB_ACTION=fail
		USB_FAIL_KIND=many_unisoc
		USB_FAIL_LIST=("${have[@]}")
		return 0
	fi
	if (( ${#have[@]} == 1 )); then
		USB_ACTION=take
		USB_CHOSEN=${have[0]}
		if (( ${#USB_PATHS[@]} > 1 )); then
			USB_TAKE_WHY=unisoc
		else
			USB_TAKE_WHY=warm
		fi
		return 0
	fi
	if (( ${#USB_PATHS[@]} == 1 )) && [[ -z ${USB_VIDS[0]:-} ]]; then
		USB_ACTION=take
		USB_CHOSEN=${USB_PATHS[0]}
		USB_TAKE_WHY=warm
		return 0
	fi
	return 0
}

usb_print_fail() {
	local tool=$1
	echo >&2
	if [[ ${USB_FAIL_KIND:-} == many_unisoc ]]; then
		echo "more than one Unisoc device (vendor 1782); pass the path:" >&2
	else
		echo "more than one new USB device; pass the path:" >&2
	fi
	if (( ${#USB_FAIL_LIST[@]} )); then
		printf '  %s\n' "${USB_FAIL_LIST[@]}" >&2
	fi
	echo "  $tool /dev/bus/usb/N/M -- <commands>" >&2
}
