#!/bin/bash
# ---------------------------------------------------------------------------
# synology_disk_report.sh
# Disk health report for Synology NAS (DSM 6.x / 7.x)
#
# Shows: Make, Model, Serial Number, Power-On Hours, Bad Sector counters
#        (Reallocated / Pending / Uncorrectable), SATA SSD life remaining
#        and overall SMART health.
#        NVMe / M.2 cache drives get their own section with wear level,
#        spare capacity, data written, error counters and temperature.
#
# Requires: bash 4.3+, smartctl (both ship with DSM), root.
#
# Usage:  sudo bash synology_disk_report.sh                # print table
#         sudo JOBS=16 bash synology_disk_report.sh       # override parallelism (default 32)
#         sudo bash synology_disk_report.sh /volume1/report.csv   # + CSV
#           (NVMe drives go to /volume1/report_nvme.csv)
# ---------------------------------------------------------------------------

VERSION="1.9"

case "${1:-}" in
    -h|--help)
        sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    -V|--version)
        echo "synology_disk_report.sh $VERSION"
        exit 0 ;;
    -*)
        echo "Unknown option: $1  (try --help)" >&2
        exit 2 ;;
esac

CSV_OUT="${1:-}"
JOBS="${JOBS:-32}"         # how many disks to query at once (32 suits large SAS setups; lower it on small NAS units)
SYSFS="${SYSFS:-/sys}"

# --- must be root to read SMART data ----------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo bash $0 $*" >&2
    exit 1
fi

# --- locate smartctl ---------------------------------------------------------
SMARTCTL="$(command -v smartctl 2>/dev/null)"
if [ -z "$SMARTCTL" ]; then
    for p in /usr/bin/smartctl /bin/smartctl /usr/sbin/smartctl /usr/syno/bin/smartctl; do
        [ -x "$p" ] && SMARTCTL="$p" && break
    done
fi
if [ -z "$SMARTCTL" ]; then
    echo "ERROR: smartctl not found on this system." >&2
    exit 1
fi

# --- helpers -----------------------------------------------------------------
# Value of a "Key: value" line from smartctl output
field() {
    printf '%s\n' "$OUT" | awk -v k="$1" 'index($0, k":") == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }'
}

# RAW value of an ATA SMART attribute by ID (column 10), digits only
attr() {
    printf '%s\n' "$OUT" | awk -v id="$1" '$1 == id { print $10; exit }' | sed 's/[^0-9].*//'
}

# SAS power-on hours, from either of the two formats smartctl uses:
#   "number of hours powered up = 34011.77"                 (Seagate / Hitachi)
#   "Accumulated power on time, hours:minutes 34011:46 ..."  (most SAS drives, -x)
sas_hours() {
    awk '/number of hours powered up/ { sub(/.*= */, ""); print int($0); exit }
         /power on time, hours:minutes/ {
             for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+:[0-9]+$/) { split($i, a, ":"); print a[1]; exit } }'
}

# SATA SSD life remaining (%), from the first wear attribute the drive has.
# These attributes count DOWN from 100 in the normalised VALUE column:
#   231 SSD_Life_Left            (Synology SAT5200 series, Kingston, many others)
#   202 Percent_Lifetime_Remain  (Crucial / Micron)
#   169 Remaining_Life_Percentage (WD Red SA500 / Blue)
#   177 Wear_Leveling_Count      (Samsung)
#   233 Media_Wearout_Indicator  (Intel)
ssd_life() {
    printf '%s\n' "$OUT" | awk '
        $1 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { v[$1] = $4 + 0 }
        END {
            n = split("231 202 169 177 233", ids, " ")
            for (i = 1; i <= n; i++) if (ids[i] in v) { print v[ids[i]]; exit }
        }'
}

# Strip commas / non-digits from a number like "12,345"
num() {
    printf '%s' "$1" | tr -d ',' | sed 's/[^0-9].*//'
}

# Work out the manufacturer from Model Family / Vendor / Model
get_make() {
    local family model vendor
    family="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    model="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
    vendor="$(printf '%s' "$3" | tr '[:lower:]' '[:upper:]')"

    case "$family $vendor" in
        *"WESTERN DIGITAL"*|*WDC*)  echo "Western Digital"; return ;;
        *SEAGATE*)                  echo "Seagate"; return ;;
        *HGST*|*HITACHI*)           echo "HGST"; return ;;
        *TOSHIBA*)                  echo "Toshiba"; return ;;
        *SYNOLOGY*)                 echo "Synology"; return ;;
        *SAMSUNG*)                  echo "Samsung"; return ;;
        *CRUCIAL*|*MICRON*)         echo "Crucial/Micron"; return ;;
        *INTEL*)                    echo "Intel"; return ;;
    esac

    case "$model" in
        WDC*|WD*)                   echo "Western Digital" ;;
        ST*|SEAGATE*)               echo "Seagate" ;;
        HGST*|HUH*|HUS*|HDN*|HDS*)  echo "HGST" ;;
        TOSHIBA*|MG0*|MG1*|HDW*|DT0*) echo "Toshiba" ;;
        HAT*|HAS*|SAT*|SNV*)        echo "Synology" ;;
        SAMSUNG*)                   echo "Samsung" ;;
        CT*|MICRON*)                echo "Crucial/Micron" ;;
        INTEL*)                     echo "Intel" ;;
        KINGSTON*)                  echo "Kingston" ;;
        *)                          echo "${3:-Unknown}" ;;
    esac
}

# --- find disks (whole disks only, no partitions) ----------------------------
DEVICES=""

# 1) Ask the kernel: every real disk appears in /sys/block with a "device" link
for sys in "$SYSFS"/block/*; do
    name="$(basename "$sys")"
    case "$name" in
        loop*|ram*|zram*|md*|dm-*|synoboot*|sr*|mtdblock*|nbd*) continue ;;
    esac
    [ -e "$sys/device" ] || continue
    [ -e "/dev/$name" ] && DEVICES="$DEVICES /dev/$name"
done

# 2) Fallback: let smartctl find them
if [ -z "$DEVICES" ]; then
    DEVICES="$("$SMARTCTL" --scan 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
fi

# 3) Fallback: common Synology device names
if [ -z "$DEVICES" ]; then
    for d in /dev/sata[0-9]* /dev/sas[0-9]* /dev/sd[a-z] /dev/sd[a-z][a-z] \
             /dev/hd[a-z] /dev/nvme[0-9]*n1; do
        case "$d" in *p[0-9]*) continue ;; esac   # skip partitions
        [ -b "$d" ] && DEVICES="$DEVICES $d"
    done
fi

if [ -z "$DEVICES" ]; then
    echo "No disks found. Please share the output of these commands:" >&2
    echo "  ls /sys/block" >&2
    echo "  $SMARTCTL --scan" >&2
    exit 1
fi

# --- slot / bay mapping ------------------------------------------------------
# Synology's own tool knows which bay each disk is in ("Drive 1" = bay 1, the
# same numbering Storage Manager and the front panel use).
SYNODISK=""
for p in /usr/syno/bin/synodisk /usr/syno/sbin/synodisk "$(command -v synodisk 2>/dev/null)"; do
    [ -n "$p" ] && [ -x "$p" ] && SYNODISK="$p" && break
done

SLOTMAP=""   # lines of "/dev/xxx|Label"
if [ -n "$SYNODISK" ]; then
    for t in internal ebox cache; do
        case "$t" in
            internal) prefix="Drive" ;;
            ebox)     prefix="Expansion Drive" ;;
            cache)    prefix="M.2 Drive" ;;
        esac
        SLOTMAP="$SLOTMAP
$("$SYNODISK" --enum -t "$t" 2>/dev/null | awk -v pre="$prefix" '
    /Disk id:/   { id = $NF }
    /Disk path:/ { if (id != "") print $NF "|" pre " " id; id = "" }')"
    done
    # Older DSM versions do not accept -t; try the plain form
    if ! printf '%s\n' "$SLOTMAP" | grep -q '|'; then
        SLOTMAP="$("$SYNODISK" --enum 2>/dev/null | awk '
            /Disk id:/   { id = $NF }
            /Disk path:/ { if (id != "") print $NF "|Drive " id; id = "" }')"
    fi
fi

# --- expansion enclosures (e.g. RX1217sas-1, RX1217sas-2 ...) ----------------
# Each expansion unit shows up in /sys/class/enclosure. Units are numbered per
# model in SCSI-address order, the same way DSM names them.
ENCLMAP=""      # lines of "blockname|EnclosureName|EnclosureIndex"
declare -A MODEL_COUNT
if [ -d "$SYSFS/class/enclosure" ]; then
    eidx=0
    for e in $(ls "$SYSFS/class/enclosure" 2>/dev/null | sort -t: -k1,1n -k2,2n -k3,3n -k4,4n); do
        ed="$SYSFS/class/enclosure/$e"
        emodel="$(sed 's/[[:space:]]*$//' "$ed/device/model" 2>/dev/null)"
        [ -z "$emodel" ] && emodel="Expansion"
        MODEL_COUNT[$emodel]=$(( ${MODEL_COUNT[$emodel]:-0} + 1 ))
        ename="$emodel-${MODEL_COUNT[$emodel]}"
        eidx=$((eidx + 1))

        # a) slots that link straight to the disk
        found=0
        for b in "$ed"/*/device/block/*; do
            [ -e "$b" ] || continue
            ENCLMAP="$ENCLMAP$(basename "$b")|$ename|$eidx
"
            found=1
        done

        # b) otherwise: disks that sit behind the same SAS expander
        if [ "$found" -eq 0 ]; then
            epath="$(readlink -f "$ed/device" 2>/dev/null)"
            expander="$(printf '%s' "$epath" | tr '/' '\n' | grep '^expander-' | tail -1)"
            [ -z "$expander" ] && continue
            for sys in "$SYSFS"/block/*; do
                p="$(readlink -f "$sys/device" 2>/dev/null)"
                case "$p" in
                    */"$expander"/*)
                        rest="${p#*/$expander/}"
                        case "$rest" in *expander-*) continue ;; esac   # belongs to a unit further down the chain
                        ENCLMAP="$ENCLMAP$(basename "$sys")|$ename|$eidx
"
                        ;;
                esac
            done
        fi
    done
fi

# Prints "SORTGROUP SORTNUM|Human-readable slot"
get_slot() {
    local dev="$1" name label n einfo ename eidx
    name="$(basename "$dev")"
    label="$(printf '%s\n' "$SLOTMAP" | awk -F'|' -v d="$dev" '$1 == d { print $2; exit }')"

    case "$label" in
        "Expansion Drive "*)
            n="${label##* }"
            einfo="$(printf '%s\n' "$ENCLMAP" | awk -F'|' -v b="$name" '$1 == b { print $2 "|" $3; exit }')"
            if [ -n "$einfo" ]; then
                ename="${einfo%|*}"; eidx="${einfo#*|}"
                echo "1 $((eidx * 1000 + n))|$ename Drive $n"
            else
                echo "1 $((900000 + n))|$label"
            fi
            return ;;
        "Drive "*)
            echo "0 ${label##* }|$label"; return ;;
        "M.2 Drive "*)
            echo "2 ${label##* }|$label"; return ;;
    esac

    # Not in Synology's bay list even though the list exists (e.g. the
    # dedicated system SSD slots on an HD6500): don't guess a bay number, which
    # would clash with a real bay. DSM calls these SSD slots "System Drive N".
    case "$name" in
        nvme*) ;;
        *)
            if printf '%s\n' "$SLOTMAP" | grep -q '|'; then
                n="${name##*[!0-9]}"; [ -z "$n" ] && n=0
                if [ "$(cat "$SYSFS/block/$name/queue/rotational" 2>/dev/null)" = "0" ]; then
                    echo "2 $n|System Drive $n"
                else
                    echo "3 $n|Not in bay list"
                fi
                return
            fi ;;
    esac

    # Fallbacks worked out from the device name
    case "$name" in
        sata[0-9]*)  n="${name#sata}"; echo "0 $n|Drive $n" ;;
        sas[0-9]*)   n="${name#sas}";  echo "0 $n|Drive $n" ;;
        nvme[0-9]*)  n="${name#nvme}"; n="${n%%n*}"; n=$((n + 1))
                     echo "2 $n|M.2 Drive $n" ;;
        sd[a-z])     n="$(printf '%d' "'${name#sd}")"; n=$((n - 96))
                     echo "0 $n|Drive $n (est.)" ;;
        *)           echo "3 0|Unknown" ;;
    esac
}

# --- report header -----------------------------------------------------------
FMT="%-22s %-10s %-16s %-24s %-22s %10s %8s %8s %8s %6s %-8s\n"
echo "Disk Report v$VERSION - $(hostname) - $(date '+%Y-%m-%d %H:%M')"
echo
printf "$FMT" "Slot" "Device" "Make" "Model" "Serial" "PowerOnHrs" "Realloc" "Pending" "Uncorr" "Life%" "Health"
printf "$FMT" "----" "------" "----" "-----" "------" "----------" "-------" "-------" "------" "-----" "------"

if [ -n "$CSV_OUT" ]; then
    echo "Slot,Device,Make,Model,Serial,PowerOnHours,Reallocated,Pending,Uncorrectable,Health,SSDLifeRemaining" > "$CSV_OUT" || {
        echo "ERROR: cannot write $CSV_OUT" >&2; CSV_OUT=""; }
fi

# --- per-disk work (runs in parallel) ----------------------------------------
# Writes one line: SORTGRP <tab> SORTNUM <tab> SERIAL <tab> TABLE-ROW <tab> CSV-ROW
process_disk() {
    local dev="$1" family vendor model serial make hours realloc pending uncorr health life
    local slotinfo slotkey slot line csv
    local alt
    OUT="$("$SMARTCTL" -a "$dev" 2>/dev/null)"
    # SATA drives behind a SAS/SCSI layer (e.g. Synology SAT5210 SSDs) can look
    # like SCSI disks "lacking SMART"; asking with "-d sat" gets the real data.
    if ! printf '%s\n' "$OUT" | grep -qE '^(Device Model|Model Number|Product):'; then
        OUT="$("$SMARTCTL" -a -d sat "$dev" 2>/dev/null)"
    elif ! printf '%s\n' "$OUT" | grep -qE 'overall-health self-assessment|SMART Health Status' \
         || printf '%s\n' "$OUT" | grep -q 'lacks SMART capability'; then
        alt="$("$SMARTCTL" -a -d sat "$dev" 2>/dev/null)"
        printf '%s\n' "$alt" | grep -qE 'overall-health self-assessment|^Device Model:' && OUT="$alt"
    fi

    family="$(field 'Model Family')"
    vendor="$(field 'Vendor')"
    model="$(field 'Device Model')"
    [ -z "$model" ] && model="$(field 'Model Number')"   # NVMe
    [ -z "$model" ] && model="$(field 'Product')"        # SAS
    serial="$(field 'Serial Number')"
    [ -z "$serial" ] && serial="$(field 'Serial number')" # SAS

    [ -z "$model" ] && [ -z "$serial" ] && return        # not a readable disk

    make="$(get_make "$family" "$model" "$vendor")"

    if printf '%s\n' "$OUT" | grep -q '^Media and Data Integrity Errors'; then
        # ---- NVMe ----
        hours="$(num "$(field 'Power On Hours')")"
        realloc="n/a"
        pending="n/a"
        uncorr="$(num "$(field 'Media and Data Integrity Errors')")"
    elif printf '%s\n' "$OUT" | grep -q 'grown defect list'; then
        # ---- SAS ----
        hours="$(printf '%s\n' "$OUT" | sas_hours)"
        # some drives only report power-on time in the extended (-x) output
        [ -z "$hours" ] && hours="$("$SMARTCTL" -x "$dev" 2>/dev/null | sas_hours)"
        realloc="$(printf '%s\n' "$OUT" | awk -F': *' '/grown defect list/ {print $2; exit}')"
        pending="n/a"
        # total uncorrected read + write + verify errors from the error counter log
        uncorr="$(printf '%s\n' "$OUT" | awk '/^(read|write|verify):/ { t += $NF; n++ } END { if (n) print t }')"
    else
        # ---- SATA ----
        hours="$(attr 9)"
        realloc="$(attr 5)"
        pending="$(attr 197)"
        uncorr="$(attr 198)"
    fi

    health="$(printf '%s\n' "$OUT" | awk -F': *' '/overall-health self-assessment|SMART Health Status/ {print $NF; exit}')"

    hours="${hours:-?}"; realloc="${realloc:-?}"; pending="${pending:-?}"
    uncorr="${uncorr:-?}"; health="${health:-?}"

    # SSD life remaining - SATA SSDs only; hard drives have no flash to wear out
    life="n/a"
    if printf '%s\n' "$OUT" | grep -qE '^Rotation Rate: *Solid State' \
       || [ "$(cat "$SYSFS/block/$(basename "$dev")/queue/rotational" 2>/dev/null)" = "0" ]; then
        life="$(ssd_life)"; life="${life:-?}"
    fi

    slotinfo="$(get_slot "$dev")"
    slotkey="${slotinfo%%|*}"
    slot="${slotinfo#*|}"

    line="$(printf "$FMT" "$slot" "$(basename "$dev")" "$make" "${model:0:24}" "$serial" \
        "$hours" "$realloc" "$pending" "$uncorr" "$life" "$health")"
    csv="\"$slot\",$(basename "$dev"),\"$make\",\"$model\",\"$serial\",$hours,$realloc,$pending,$uncorr,$health,$life"

    printf '%s\t%s\t%s\t%s\t%s\n' "${slotkey% *}" "${slotkey#* }" "$serial" "$line" "$csv"
}

# --- NVMe / M.2 worker (runs in parallel) ------------------------------------
FMT_N="%-14s %-9s %-15s %-26s %-20s %10s %5s %5s %7s %9s %8s %7s %7s %5s %-8s %s\n"

add_note() { NOTES="${NOTES:+$NOTES; }$1"; }

process_nvme() {
    local dev="$1" name ctrl try model serial make hours used life spare spthr
    local units written media errlog unsafe temp crit c warnt critt health
    local slotinfo slotkey slot line csv
    name="$(basename "$dev")"
    ctrl="/dev/${name%n[0-9]*}"          # nvme0n1 -> nvme0 (the controller)

    # older smartctl builds need "-d nvme" and/or the controller device
    OUT=""
    for try in "-a $dev" "-a -d nvme $dev" "-a -d nvme $ctrl" "-a $ctrl"; do
        OUT="$("$SMARTCTL" $try 2>/dev/null)"
        printf '%s\n' "$OUT" | grep -q '^Percentage Used' && break
    done

    model="$(field 'Model Number')"
    serial="$(field 'Serial Number')"
    hours="$(num "$(field 'Power On Hours')")"
    used="$(num "$(field 'Percentage Used')")"
    spare="$(num "$(field 'Available Spare')")"
    spthr="$(num "$(field 'Available Spare Threshold')")"
    units="$(num "$(field 'Data Units Written')")"
    media="$(num "$(field 'Media and Data Integrity Errors')")"
    errlog="$(num "$(field 'Error Information Log Entries')")"
    unsafe="$(num "$(field 'Unsafe Shutdowns')")"
    temp="$(num "$(field 'Temperature')")"
    crit="$(field 'Critical Warning')"
    warnt="$(printf '%s\n' "$OUT" | awk -F': *' '/^Warning +Comp\. Temperature Time/ {gsub(/,/,"",$2); print $2+0; exit}')"
    critt="$(printf '%s\n' "$OUT" | awk -F': *' '/^Critical Comp\. Temperature Time/ {gsub(/,/,"",$2); print $2+0; exit}')"
    health="$(printf '%s\n' "$OUT" | awk -F': *' '/overall-health self-assessment|SMART Health Status/ {print $NF; exit}')"

    make="$(get_make "" "$model" "")"
    [ "$make" = "Unknown" ] && [ -n "$model" ] && make="${model%% *}"

    # life remaining = 100 - percentage used (used can go past 100)
    life="?"
    if [ -n "$used" ]; then life=$((100 - used)); [ "$life" -lt 0 ] && life=0; fi

    # data written: one NVMe "data unit" = 512,000 bytes
    written="?"
    [ -n "$units" ] && written="$(awk -v u="$units" 'BEGIN { b = u * 512000;
        if (b >= 1e12) printf "%.1f TB", b / 1e12; else printf "%.0f GB", b / 1e9 }')"

    # ---- plain-English notes ----
    NOTES=""
    if [ -z "$model" ] && [ -z "$serial" ]; then
        add_note "could not read SMART data"
    fi
    if printf '%s' "$crit" | grep -qiE '^0x[0-9a-f]+$'; then
        c=$((crit))
        [ $((c & 1))  -ne 0 ] && add_note "CRITICAL: spare below threshold"
        [ $((c & 2))  -ne 0 ] && add_note "CRITICAL: temperature out of range"
        [ $((c & 4))  -ne 0 ] && add_note "CRITICAL: reliability degraded"
        [ $((c & 8))  -ne 0 ] && add_note "CRITICAL: drive is read-only"
        [ $((c & 16)) -ne 0 ] && add_note "CRITICAL: backup power failed"
    fi
    if [ -n "$used" ]; then
        if   [ "$used" -ge 100 ]; then add_note "rated endurance used up - replace"
        elif [ "$used" -ge 80 ];  then add_note "over 80% worn - plan replacement"
        fi
    fi
    if [ -n "$spare" ] && [ -n "$spthr" ] && [ "$spare" -le "$spthr" ] && [ $(( ${c:-0} & 1 )) -eq 0 ]; then
        add_note "spare at/below threshold"
    fi
    [ -n "$media" ] && [ "$media" -gt 0 ] && add_note "$media media/data errors"
    [ -n "$critt" ] && [ "$critt" -gt 0 ] && add_note "ran above critical temp for $critt min"
    [ -n "$warnt" ] && [ "$warnt" -gt 0 ] && add_note "ran above warning temp for $warnt min"
    case "$health" in ""|PASSED|OK) ;; *) add_note "SMART health: $health" ;; esac
    [ -z "$NOTES" ] && NOTES="OK"

    slotinfo="$(get_slot "$dev")"
    slotkey="${slotinfo%%|*}"
    slot="${slotinfo#*|}"

    line="$(printf "$FMT_N" "$slot" "$name" "$make" "${model:0:26}" "${serial:-?}" \
        "${hours:-?}" "${used:-?}" "$life" "${spare:-?}/${spthr:-?}" "$written" \
        "${media:-?}" "${errlog:-?}" "${unsafe:-?}" "${temp:-?}" "${health:-?}" "$NOTES")"
    csv="\"$slot\",$name,\"$make\",\"$model\",\"$serial\",${hours},${used},${life},${spare},${spthr},\"$written\",${media},${errlog},${unsafe},${temp},${crit},${health},\"$NOTES\""

    printf '%s\t%s\t%s\t%s\t%s\n' "${slotkey% *}" "${slotkey#* }" "$serial" "$line" "$csv"
}

TMPD="$(mktemp -d /tmp/diskreport.XXXXXX)" || { echo "ERROR: cannot create temp dir" >&2; exit 1; }
trap 'rm -rf "$TMPD"' EXIT
mkdir "$TMPD/disks" "$TMPD/nvme"

ndev=$(echo $DEVICES | wc -w)
[ -t 2 ] && printf 'Reading %d disks, %d at a time...\r' "$ndev" "$JOBS" >&2
for dev in $DEVICES; do
    # keep at most $JOBS queries running
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || sleep 0.2; done
    case "$(basename "$dev")" in
        nvme*) process_nvme "$dev" > "$TMPD/nvme/$(basename "$dev")" & ;;
        *)     process_disk "$dev" > "$TMPD/disks/$(basename "$dev")" & ;;
    esac
done
wait
[ -t 2 ] && printf '%60s\r' '' >&2

# merge, sort into bay order, drop duplicates (same serial seen twice)
cat "$TMPD"/disks/* 2>/dev/null | sort -t "$(printf '\t')" -k1,1n -k2,2n \
    | awk -F'\t' '$3 == "" || !seen[$3]++' > "$TMPD/all.rows"

cut -f4 "$TMPD/all.rows"
[ -n "$CSV_OUT" ] && cut -f5 "$TMPD/all.rows" >> "$CSV_OUT"

echo
echo "Realloc = reallocated sectors (SATA ID 5) / grown defects (SAS)"
echo "Pending = sectors waiting to be remapped (ID 197)"
echo "Uncorr  = uncorrectable sectors (ID 198) / total uncorrected read+write errors (SAS)"
echo "Life%   = SSD life remaining, as reported by the SSD itself (hard drives: n/a)"
echo "Any non-zero bad sector count is worth watching; a rising count means plan a replacement."
echo "Plan to replace an SSD when Life% falls below about 10-20%."
# --- NVMe / M.2 cache section -------------------------------------------------
cat "$TMPD"/nvme/* 2>/dev/null | sort -t "$(printf '\t')" -k1,1n -k2,2n \
    | awk -F'\t' '$3 == "" || !seen[$3]++' > "$TMPD/nvme.rows"

echo
echo "NVMe / M.2 Cache Drives"
echo "======================="
if [ -s "$TMPD/nvme.rows" ]; then
    printf "$FMT_N" "Slot" "Device" "Make" "Model" "Serial" "PowerOnHrs" "Used%" "Life%" "Spare%" "Written" \
        "MediaErr" "ErrLog" "Unsafe" "Temp" "Health" "Notes"
    printf "$FMT_N" "----" "------" "----" "-----" "------" "----------" "-----" "-----" "------" "-------" \
        "--------" "------" "------" "----" "------" "-----"
    cut -f4 "$TMPD/nvme.rows"
    echo
    echo "Used%    = share of the drive's rated write endurance used up (wear level); Life% = 100 - Used%"
    echo "Spare%   = spare flash still available / level at which the drive raises a warning"
    echo "MediaErr = unrecovered data errors - should always be 0"
    echo "ErrLog   = entries in the drive's error log; often harmless (e.g. unsupported commands), watch for fast growth"
    echo "Unsafe   = power losses without a clean shutdown"

    if [ -n "$CSV_OUT" ]; then
        case "$CSV_OUT" in *.csv) NVME_CSV="${CSV_OUT%.csv}_nvme.csv" ;; *) NVME_CSV="${CSV_OUT}_nvme.csv" ;; esac
        { echo "Slot,Device,Make,Model,Serial,PowerOnHours,PercentUsed,LifeRemaining,AvailableSpare,SpareThreshold,DataWritten,MediaErrors,ErrorLogEntries,UnsafeShutdowns,TemperatureC,CriticalWarning,Health,Notes"
          cut -f5 "$TMPD/nvme.rows"; } > "$NVME_CSV" || NVME_CSV=""
    fi
else
    echo "No NVMe drives found."
fi

[ -n "$CSV_OUT" ] && echo && echo "CSV saved to: $CSV_OUT"
[ -n "${NVME_CSV:-}" ] && echo "NVMe CSV saved to: $NVME_CSV"
