#!/bin/bash
# ---------------------------------------------------------------------------
# synology_disk_report.sh
# Disk health report for Synology NAS (DSM 6.x / 7.x)
#
# Shows: Make, Model, Serial Number, Power-On Hours, Bad Sector counters
#        (Reallocated / Pending / Uncorrectable), SATA SSD life remaining
#        and overall SMART health.
#        NVMe and SATA M.2 cache drives get their own section with wear
#        level, spare capacity, data written, error counters and temperature.
#
# Requires: bash 4.3+, smartctl (both ship with DSM), root.
#
# Usage:  sudo bash synology_disk_report.sh                # print table
#         sudo JOBS=16 bash synology_disk_report.sh       # override parallelism (default 32)
#         sudo bash synology_disk_report.sh /volume1/report.csv   # + CSV
#           (NVMe drives go to /volume1/report_nvme.csv)
# ---------------------------------------------------------------------------

VERSION="2.6"

case "${1:-}" in
    -h|--help)    sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -V|--version) echo "synology_disk_report.sh $VERSION"; exit 0 ;;
    -*)           echo "Unknown option: $1  (try --help)" >&2; exit 2 ;;
esac

CSV_OUT="${1:-}"
JOBS="${JOBS:-32}"         # disks queried at once (32 suits large SAS setups; lower it on small units)
SYSFS="${SYSFS:-/sys}"
TAB=$'\t'

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo bash $0 $*" >&2
    exit 1
fi

# First executable among the given paths and $PATH
find_tool() {
    local name="$1" p; shift
    for p in "$@" "$(command -v "$name" 2>/dev/null)"; do
        [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; return; }
    done
}

SMARTCTL="$(find_tool smartctl /usr/bin/smartctl /bin/smartctl /usr/sbin/smartctl /usr/syno/bin/smartctl)"
[ -n "$SMARTCTL" ] || { echo "ERROR: smartctl not found on this system." >&2; exit 1; }
SYNODISK="$(find_tool synodisk /usr/syno/bin/synodisk /usr/syno/sbin/synodisk)"      # bay numbers
SYNONVME="$(find_tool synonvme /usr/syno/bin/synonvme /usr/syno/sbin/synonvme)"      # NVMe fallback
NVMECLI="$(command -v nvme 2>/dev/null)"                                             # NVMe fallback

# --- parsing helpers (all read the smartctl output in $OUT) ------------------
has()   { grep -qE "$1" <<< "$OUT"; }
# Value of a "Key: value" line
field() { awk -v k="$1:" 'index($0, k) == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }' <<< "$OUT"; }
# Leading digits of a number like "12,345" or "6%"
num()   { local x="${1//,/}"; echo "${x%%[!0-9]*}"; }
# RAW value of an ATA attribute, by ID or by a regex on its name
attr()       { awk -v id="$1" '$1 == id { v = $10; sub(/[^0-9].*/, "", v); print v; exit }' <<< "$OUT"; }
attr_named() { awk -v re="$1" '$1 ~ /^[0-9]+$/ && $2 ~ re { v = $10; sub(/[^0-9].*/, "", v); print v; exit }' <<< "$OUT"; }
# Text after the health line's first colon: "PASSED", "OK", or a SAS sentence
health_text() { awk '/overall-health self-assessment|SMART Health Status/ { sub(/^[^:]*: */, ""); print; exit }' <<< "$OUT"; }
# COUNT x UNIT bytes as "12.3 TB" or "456 GB"
fmt_bytes() { awk -v b="$1" -v u="$2" 'BEGIN { b *= u; if (b >= 1e12) printf "%.1f TB", b / 1e12; else printf "%.0f GB", b / 1e9 }'; }
is_ssd()  { [ "$(cat "$SYSFS/block/$1/queue/rotational" 2>/dev/null)" = "0" ]; }
# A drive attribute the kernel recorded at start-up, e.g. model or serial
sysattr() { [ -r "$SYSFS/block/$1/device/$2" ] && sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$SYSFS/block/$1/device/$2"; }

# smartctl -a into $OUT. SATA drives behind a SAS/SCSI layer (e.g. Synology
# SAT5210 SSDs) can look like SCSI disks "lacking SMART"; "-d sat" gets the real
# data. With a second argument, retry whenever the ATA health line is missing.
read_smart() {
    local alt
    OUT="$("$SMARTCTL" -a "$1" 2>/dev/null)"
    if ! has '^(Device Model|Model Number|Product):'; then
        OUT="$("$SMARTCTL" -a -d sat "$1" 2>/dev/null)"
    elif has 'lacks SMART capability' || { ! has 'overall-health self-assessment' && { [ -n "${2:-}" ] || ! has 'SMART Health Status'; }; }; then
        alt="$("$SMARTCTL" -a -d sat "$1" 2>/dev/null)"
        grep -qE 'overall-health self-assessment|^Device Model:' <<< "$alt" && OUT="$alt"
    fi
}

# SAS power-on hours: "number of hours powered up = 34011.77" (Seagate/Hitachi)
# or "Accumulated power on time, hours:minutes 34011:46" (most SAS drives, -x)
sas_hours() {
    awk '/number of hours powered up/ { sub(/.*= */, ""); print int($0); exit }
         /power on time, hours:minutes/ {
             for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+:[0-9]+$/) { split($i, a, ":"); print a[1]; exit } }'
}

# SATA SSD life remaining (%): normalised VALUE of the first wear attribute,
# counting down from 100: 231 SSD_Life_Left (Synology, Kingston ...),
# 202 Percent_Lifetime_Remain (Crucial/Micron), 169 Remaining_Life_Percentage
# (WD), 177 Wear_Leveling_Count (Samsung), 233 Media_Wearout_Indicator (Intel)
ssd_life() {
    awk '$1 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { v[$1] = $4 + 0 }
         END { n = split("231 202 169 177 233", ids, " ")
               for (i = 1; i <= n; i++) if (ids[i] in v) { print v[ids[i]]; exit } }' <<< "$OUT"
}

# SAS health can be a whole sentence, e.g. "DATA CHANNEL IMPENDING FAILURE ...
# [asc=5d, ascq=30]": the table shows a short word, the text goes under it.
health_short() {
    case "$1" in
        PASSED|OK|FAILED!|"?"|"") echo "${1:-?}" ;;
        *FAIL*) echo "FAILING" ;;
        *)      echo "WARNING" ;;
    esac
}
health_explain() {
    case "$1" in
        *"asc=5d"*) echo "the drive predicts its own failure (SMART failure threshold exceeded) - replace it" ;;
        *"asc=b, ascq=14"*|*"asc=b, ascq=0x14"*)
                    echo "physical element status change - part of the drive (for example a head) has reported a problem" ;;
        *"asc=b,"*) echo "the drive has raised a warning" ;;
    esac
}

# Manufacturer from Model Family / Model / Vendor
get_make() {
    local m="${2^^}"
    case "${1^^} ${3^^}" in
        *"WESTERN DIGITAL"*|*WDC*) echo "Western Digital"; return ;;
        *SEAGATE*)          echo "Seagate"; return ;;
        *HGST*|*HITACHI*)   echo "HGST"; return ;;
        *TOSHIBA*)          echo "Toshiba"; return ;;
        *SYNOLOGY*)         echo "Synology"; return ;;
        *SAMSUNG*)          echo "Samsung"; return ;;
        *CRUCIAL*|*MICRON*) echo "Crucial/Micron"; return ;;
        *INTEL*)            echo "Intel"; return ;;
    esac
    case "$m" in
        WDC*|WD*)                     echo "Western Digital" ;;
        ST*|SEAGATE*)                 echo "Seagate" ;;
        HGST*|HUH*|HUS*|HDN*|HDS*)    echo "HGST" ;;
        TOSHIBA*|MG0*|MG1*|HDW*|DT0*) echo "Toshiba" ;;
        HAT*|HAS*|SAT*|SNV*)          echo "Synology" ;;
        SAMSUNG*)                     echo "Samsung" ;;
        CT*|MICRON*)                  echo "Crucial/Micron" ;;
        INTEL*)                       echo "Intel" ;;
        KINGSTON*)                    echo "Kingston" ;;
        *)                            echo "${3:-Unknown}" ;;
    esac
}

# --- find disks (whole disks only) -------------------------------------------
DEVICES=""
for sys in "$SYSFS"/block/*; do                       # 1) every real disk in /sys/block
    name="${sys##*/}"
    case "$name" in loop*|ram*|zram*|md*|dm-*|synoboot*|sr*|mtdblock*|nbd*) continue ;; esac
    [ -e "$sys/device" ] || continue
    [ -e "/dev/$name" ] && DEVICES+=" /dev/$name"
done
[ -z "$DEVICES" ] && DEVICES="$("$SMARTCTL" --scan 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"   # 2)
if [ -z "$DEVICES" ]; then                            # 3) common Synology device names
    for d in /dev/sata[0-9]* /dev/sas[0-9]* /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/hd[a-z] /dev/nvme[0-9]*n1; do
        case "$d" in *p[0-9]*) continue ;; esac
        [ -b "$d" ] && DEVICES+=" $d"
    done
fi
if [ -z "$DEVICES" ]; then
    printf 'No disks found. Please share the output of these commands:\n  ls /sys/block\n  %s --scan\n' "$SMARTCTL" >&2
    exit 1
fi

# --- slot names ----------------------------------------------------------------
# synodisk knows each disk's bay as Storage Manager numbers it. SLOTMAP lines:
# "/dev/xxx|Drive N", "|Expansion Drive N" or "|M.2 Drive N" (= listed as cache).
SLOTMAP=""
if [ -n "$SYNODISK" ]; then
    for t in internal:Drive "ebox:Expansion Drive" "cache:M.2 Drive"; do
        SLOTMAP+=$'\n'"$("$SYNODISK" --enum -t "${t%%:*}" 2>/dev/null | awk -v pre="${t#*:}" '
            /Disk id:/ { id = $NF }  /Disk path:/ { if (id != "") print $NF "|" pre " " id; id = "" }')"
    done
    # older DSM versions don't accept -t
    grep -q '|' <<< "$SLOTMAP" || SLOTMAP="$("$SYNODISK" --enum 2>/dev/null | awk '
        /Disk id:/ { id = $NF }  /Disk path:/ { if (id != "") print $NF "|Drive " id; id = "" }')"
fi
slotmap_label() { awk -F'|' -v d="$1" '$1 == d { print $2; exit }' <<< "$SLOTMAP"; }

# Expansion units (RX1217sas-1, -2 ...) from /sys/class/enclosure, numbered per
# model in SCSI-address order as DSM does. ENCLMAP lines: "blockname|Name|index".
ENCLMAP=""
declare -A MODEL_COUNT
eidx=0
for e in $(ls "$SYSFS/class/enclosure" 2>/dev/null | sort -t: -k1,1n -k2,2n -k3,3n -k4,4n); do
    ed="$SYSFS/class/enclosure/$e"
    emodel="$(sed 's/[[:space:]]*$//' "$ed/device/model" 2>/dev/null)"; emodel="${emodel:-Expansion}"
    MODEL_COUNT[$emodel]=$(( ${MODEL_COUNT[$emodel]:-0} + 1 ))
    ename="$emodel-${MODEL_COUNT[$emodel]}"; eidx=$((eidx + 1)); found=0
    for b in "$ed"/*/device/block/*; do               # slots linked straight to a disk
        [ -e "$b" ] && { ENCLMAP+="${b##*/}|$ename|$eidx"$'\n'; found=1; }
    done
    [ "$found" -eq 1 ] && continue
    # otherwise: disks behind this unit's SAS expander (not one further down the chain)
    expander="$(readlink -f "$ed/device" 2>/dev/null | tr '/' '\n' | grep '^expander-' | tail -1)"
    [ -z "$expander" ] && continue
    for sys in "$SYSFS"/block/*; do
        p="$(readlink -f "$sys/device" 2>/dev/null)"
        case "$p" in */"$expander"/*) case "${p#*/$expander/}" in *expander-*) ;; *) ENCLMAP+="${sys##*/}|$ename|$eidx"$'\n' ;; esac ;; esac
    done
done

# NVMe on PCIe adapter cards: a PCIe switch sits between the drive and the CPU
# (root port -> switch -> switch port -> drive). Cards are numbered in PCI order,
# slots in DSM's own order. NVME_CARDMAP lines: "blockname|card|slot".
nvlist=""
for sys in "$SYSFS"/block/nvme*; do
    [ -e "$sys/device" ] || continue
    name="${sys##*/}"
    addrs="$(readlink -f "$sys/device" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]')"
    n="$(grep -c . <<< "$addrs")"
    [ "$n" -ge 4 ] || continue                         # no switch: built-in M.2 slot
    id="$(slotmap_label "/dev/$name")"; case "$id" in "M.2 Drive "*) id="${id##* }" ;; *) id="" ;; esac
    nvlist+="$(sed -n "$((n - 2))p" <<< "$addrs") $(printf '%06d' "${id:-999999}") $name"$'\n'
done
NVME_CARDMAP="$(printf '%s' "$nvlist" | sort | awk '{ if ($1 != prev) { card++; slot = 0; prev = $1 } slot++; print $3 "|" card "|" slot }')"

# 2.5" SSDs in dedicated cache bays (e.g. RS10613xs+): "Cache device 1, 2 ..."
# in DSM's order. CACHEBAYMAP lines: "/dev/xxx|N".
CACHEBAYMAP="$(awk -F'|' '$2 ~ /^M\.2 Drive / && $1 !~ /\/(nvme|nvc)/ { n = $2; sub(/.* /, "", n); printf "%06d %s\n", n, $1 }' <<< "$SLOTMAP" \
    | sort | awk '{ print $2 "|" NR }')"

# Drives for the SSD / M.2 cache section
is_cache_dev() {
    case "${1##*/}" in nvme*|nvc*) return 0 ;; esac
    case "$(slotmap_label "$1")" in "M.2 Drive "*) return 0 ;; esac
    return 1
}

# SATA M.2 adapter cards (e.g. M2D17) hold 2 SSDs: cache device 3 = card 2, slot 1
cache_slot() { local c=$(( ($1 - 1) / 2 + 1 )) s=$(( ($1 - 1) % 2 + 1 )); echo "2 $((c * 10 + s))|Cache device $c-$s"; }

# Prints "SORTGROUP SORTNUM|Slot name"
get_slot() {
    local dev="$1" name="${1##*/}" label n info
    info="$(awk -F'|' -v b="$name" '$1 == b { print $2 " " $3; exit }' <<< "$NVME_CARDMAP")"
    if [ -n "$info" ]; then                            # NVMe on an adapter card
        echo "2 $(( ${info% *} * 10 + ${info#* } ))|Cache device ${info% *}-${info#* }"; return
    fi
    label="$(slotmap_label "$dev")"; n="${label##* }"
    case "$label" in
        "Expansion Drive "*)
            info="$(awk -F'|' -v b="$name" '$1 == b { print $2 "|" $3; exit }' <<< "$ENCLMAP")"
            if [ -n "$info" ]; then echo "1 $(( ${info#*|} * 1000 + n ))|${info%|*} Drive $n"
            else echo "1 $((900000 + n))|$label"; fi
            return ;;
        "Drive "*) echo "0 $n|$label"; return ;;
        "M.2 Drive "*)
            case "$name" in
                nvc*)  cache_slot "$n" ;;                              # SATA M.2 on a card
                nvme*) echo "2 $n|Cache device $n" ;;                  # built-in M.2 slot
                *)     n="$(awk -F'|' -v d="$dev" '$1 == d { print $2; exit }' <<< "$CACHEBAYMAP")"
                       echo "2 $((100 + ${n:-0}))|Cache device ${n:-?}" ;;   # cache-bay SSD
            esac
            return ;;
    esac
    case "$name" in nvc[0-9]*) cache_slot "${name#nvc}"; return ;; esac
    # Missing from a bay list that exists (e.g. HD6500 system SSDs): don't guess a
    # bay number, which would clash with a real bay.
    if [ "${name#nvme}" = "$name" ] && grep -q '|' <<< "$SLOTMAP"; then
        n="${name##*[!0-9]}"; n="${n:-0}"
        if is_ssd "$name"; then echo "2 $n|System Drive $n"; else echo "3 $n|Not in bay list"; fi
        return
    fi
    # no synodisk: work it out from the device name
    case "$name" in
        sata[0-9]*) n="${name#sata}"; echo "0 $n|Drive $n" ;;
        sas[0-9]*)  n="${name#sas}";  echo "0 $n|Drive $n" ;;
        nvme[0-9]*) n="${name#nvme}"; n=$(( ${n%%n*} + 1 )); echo "2 $n|Cache device $n (est.)" ;;
        sd[a-z])    n=$(( $(printf '%d' "'${name#sd}") - 96 )); echo "0 $n|Drive $n (est.)" ;;
        *)          echo "3 0|Unknown" ;;
    esac
}

# --- workers (run in parallel); each prints one tab-separated line:
#     SORTGROUP  SORTNUM  SERIAL  TABLE-ROW  CSV-ROW  WARNING
emit() {   # serial row csv [warning]; uses SLOT_KEY
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${SLOT_KEY% *}" "${SLOT_KEY#* }" "$1" "$2" "$3" "${4:-}"
}
set_slot() { local s; s="$(get_slot "$1")"; SLOT_KEY="${s%%|*}"; SLOT="${s#*|}"; }

add_note()    { NOTES="${NOTES:+$NOTES; }$1"; }
wear_note()   { [ -z "$1" ] && return; if [ "$1" -ge 100 ]; then add_note "rated endurance used up - replace"; elif [ "$1" -ge 80 ]; then add_note "over 80% worn - plan replacement"; fi; }
health_note() { case "$1" in ""|PASSED|OK) ;; *) add_note "SMART health: $1" ;; esac; }

FMT="%-22s %-10s %-16s %-24s %-22s %10s %8s %8s %8s %6s %-8s\n"
FMT_N="%-17s %-9s %-15s %-26s %-20s %10s %5s %5s %7s %9s %8s %7s %7s %5s %-8s %s\n"

# Hard drives and SATA SSDs (main table)
process_disk() {
    local dev="$1" name="${1##*/}" model serial make hours realloc pending uncorr full health life warn expl
    read_smart "$dev"
    model="$(field 'Device Model')"; [ -z "$model" ] && model="$(field 'Product')"        # SAS: Product
    serial="$(field 'Serial Number')"; [ -z "$serial" ] && serial="$(field 'Serial number')"
    [ -z "$model$serial" ] && return                                                    # not a readable disk
    make="$(get_make "$(field 'Model Family')" "$model" "$(field 'Vendor')")"

    if has 'grown defect list'; then                   # SAS
        hours="$(sas_hours <<< "$OUT")"
        [ -z "$hours" ] && hours="$("$SMARTCTL" -x "$dev" 2>/dev/null | sas_hours)"   # some only report it with -x
        realloc="$(awk -F': *' '/grown defect list/ {print $2; exit}' <<< "$OUT")"
        pending="n/a"
        uncorr="$(awk '/^(read|write|verify):/ { t += $NF; n++ } END { if (n) print t }' <<< "$OUT")"
    else                                               # SATA
        hours="$(attr 9)"; realloc="$(attr 5)"; pending="$(attr 197)"; uncorr="$(attr 198)"
    fi
    hours="${hours:-?}"; realloc="${realloc:-?}"; pending="${pending:-?}"; uncorr="${uncorr:-?}"
    full="$(health_text)"; full="${full:-?}"; health="$(health_short "$full")"
    life="n/a"                                         # SSDs only: hard drives have no flash to wear out
    if has '^Rotation Rate: *Solid State' || is_ssd "$name"; then life="$(ssd_life)"; life="${life:-?}"; fi

    set_slot "$dev"
    if [ "$health" != "$full" ]; then                  # full message, listed under the table
        expl="$(health_explain "$full")"; warn="$SLOT ($name, $serial): $full${expl:+@@NL@@-> $expl}"
    fi
    emit "$serial" \
        "$(printf "$FMT" "$SLOT" "$name" "$make" "${model:0:24}" "$serial" "$hours" "$realloc" "$pending" "$uncorr" "$life" "$health")" \
        "\"$SLOT\",$name,\"$make\",\"$model\",\"$serial\",$hours,$realloc,$pending,$uncorr,\"$full\",$life" "$warn"
}

# synonvme --smart-info-get / "nvme smart-log" output, renamed to smartctl's fields
nvme_normalize() {
    awk 'BEGIN { n = split("critical warning|Critical Warning|temperature|Temperature|available spare|Available Spare|" \
            "available spare threshold|Available Spare Threshold|percentage used|Percentage Used|" \
            "data units written|Data Units Written|power on hours|Power On Hours|unsafe shutdowns|Unsafe Shutdowns|" \
            "media errors|Media and Data Integrity Errors|number of error log entries|Error Information Log Entries|" \
            "num err log entries|Error Information Log Entries|warning temperature time|Warning  Comp. Temperature Time|" \
            "critical composite temperature time|Critical Comp. Temperature Time", a, "|")
            for (i = 1; i < n; i += 2) map[a[i]] = a[i + 1] }
         index($0, ":") {
            k = substr($0, 1, index($0, ":") - 1); v = substr($0, index($0, ":") + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v); k = tolower(k); gsub(/_/, " ", k)
            if (k in map) print map[k] ": " v }'
}

# NVMe drives (cache section)
process_nvme() {
    local dev="$1" name="${1##*/}" ctrl try model serial make hours used life spare spthr written
    local media errlog unsafe temp crit c warnt critt health src="smartctl" alt idc
    ctrl="/dev/${name%n[0-9]*}"                        # nvme0n1 -> nvme0 (the controller)
    # older smartctl builds need "-d nvme" and/or the controller device - but a
    # drive that rejects smartctl's identify command logs every rejection in its
    # own error log, so stop at the first one and use the fallback instead
    for try in "-a $dev" "-a -d nvme $dev" "-a -d nvme $ctrl" "-a $ctrl"; do
        OUT="$("$SMARTCTL" $try 2>/dev/null)"
        has '^Percentage Used|Identify Controller failed' && break
    done
    if ! has '^Percentage Used'; then                  # synonvme, then nvme-cli
        [ -n "$SYNONVME" ] && alt="$("$SYNONVME" --smart-info-get "$ctrl" 2>/dev/null | nvme_normalize)"
        if grep -q '^Percentage Used' <<< "$alt"; then src="synonvme"
        elif [ -n "$NVMECLI" ]; then
            alt="$("$NVMECLI" smart-log "$ctrl" 2>/dev/null | nvme_normalize)"
            grep -q '^Percentage Used' <<< "$alt" && src="nvme-cli"
        fi
        [ "$src" != "smartctl" ] && OUT+=$'\n'"$alt"
    fi

    model="$(field 'Model Number')"; serial="$(field 'Serial Number')"
    hours="$(num "$(field 'Power On Hours')")";    used="$(num "$(field 'Percentage Used')")"
    spare="$(num "$(field 'Available Spare')")";   spthr="$(num "$(field 'Available Spare Threshold')")"
    media="$(num "$(field 'Media and Data Integrity Errors')")"
    errlog="$(num "$(field 'Error Information Log Entries')")"
    unsafe="$(num "$(field 'Unsafe Shutdowns')")"; temp="$(num "$(field 'Temperature')")"
    crit="$(field 'Critical Warning')"
    warnt="$(awk -F': *' '/^Warning +Comp\. Temperature Time/ {gsub(/,/,"",$2); print $2+0; exit}' <<< "$OUT")"
    critt="$(awk -F': *' '/^Critical Comp\. Temperature Time/ {gsub(/,/,"",$2); print $2+0; exit}' <<< "$OUT")"
    health="$(health_text)"
    written="?"; [ -n "$(num "$(field 'Data Units Written')")" ] && written="$(fmt_bytes "$(num "$(field 'Data Units Written')")" 512000)"

    # no identify data: what the kernel recorded, then nvme-cli
    [ -z "$model" ]  && model="$(sysattr "$name" model)"
    [ -z "$serial" ] && serial="$(sysattr "$name" serial)"
    if [ -z "$model$serial" ] && [ -n "$NVMECLI" ]; then
        idc="$("$NVMECLI" id-ctrl "$ctrl" 2>/dev/null)"
        model="$(awk -F: '/^mn[ \t]/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' <<< "$idc")"
        serial="$(awk -F: '/^sn[ \t]/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' <<< "$idc")"
    fi
    make="$(get_make "" "$model" "")"; [ "$make" = "Unknown" ] && [ -n "$model" ] && make="${model%% *}"

    # critical warning: hex from smartctl (0x00), decimal from synonvme / nvme-cli;
    # with no health line, healthy means no critical warning
    c=""
    if [[ "$crit" =~ ^0[xX][0-9a-fA-F]+$ ]]; then c=$((crit)); elif [[ "$crit" =~ ^[0-9]+$ ]]; then c=$((10#$crit)); fi
    [ -z "$health" ] && [ -n "$c" ] && { [ "$c" -eq 0 ] && health="PASSED" || health="FAILED!"; }
    life="?"; [ -n "$used" ] && { life=$((100 - used)); [ "$life" -lt 0 ] && life=0; }

    NOTES=""
    [ -z "$used$hours" ] && add_note "could not read SMART data"
    if [ -n "$c" ]; then
        [ $((c & 1))  -ne 0 ] && add_note "CRITICAL: spare below threshold"
        [ $((c & 2))  -ne 0 ] && add_note "CRITICAL: temperature out of range"
        [ $((c & 4))  -ne 0 ] && add_note "CRITICAL: reliability degraded"
        [ $((c & 8))  -ne 0 ] && add_note "CRITICAL: drive is read-only"
        [ $((c & 16)) -ne 0 ] && add_note "CRITICAL: backup power failed"
    fi
    wear_note "$used"
    [ -n "$spare" ] && [ -n "$spthr" ] && [ "$spare" -le "$spthr" ] && [ $(( ${c:-0} & 1 )) -eq 0 ] && add_note "spare at/below threshold"
    [ -n "$media" ] && [ "$media" -gt 0 ] && add_note "$media media/data errors"
    [ -n "$critt" ] && [ "$critt" -gt 0 ] && add_note "ran above critical temp for $critt min"
    [ -n "$warnt" ] && [ "$warnt" -gt 0 ] && add_note "ran above warning temp for $warnt min"
    health_note "$health"
    NOTES="${NOTES:-OK}"; [ "$src" != "smartctl" ] && NOTES+=" (read with $src)"

    set_slot "$dev"
    emit "$serial" \
        "$(printf "$FMT_N" "$SLOT" "$name" "$make" "${model:0:26}" "${serial:-?}" "${hours:-?}" "${used:-?}" "$life" \
            "${spare:-?}/${spthr:-?}" "$written" "${media:-?}" "${errlog:-?}" "${unsafe:-?}" "${temp:-?}" "${health:-?}" "$NOTES")" \
        "\"$SLOT\",$name,\"$make\",\"$model\",\"$serial\",$hours,$used,$life,$spare,$spthr,\"$written\",$media,$errlog,$unsafe,$temp,$crit,$health,\"$NOTES\""
}

# SATA M.2 and cache-bay SSDs (cache section): NVMe columns from ATA attributes
process_sata_cache() {
    local dev="$1" name="${1##*/}" model serial make hours life used realloc media errlog unsafe temp health written
    read_smart "$dev" ata
    model="$(field 'Device Model')"; [ -z "$model" ] && model="$(field 'Product')"
    serial="$(field 'Serial Number')"; [ -z "$serial" ] && serial="$(field 'Serial number')"
    make="$(get_make "$(field 'Model Family')" "$model" "$(field 'Vendor')")"
    [ "$make" = "Unknown" ] && [ -n "$model" ] && make="${model%% *}"

    hours="$(attr 9)"; realloc="$(attr 5)"
    life="$(ssd_life)"; used=""; [ -n "$life" ] && used=$((100 - life))
    media="$(attr 187)"; [ -z "$media" ] && media="$(attr 198)"           # reported / offline uncorrectable
    temp="$(attr 194)";  [ -z "$temp" ]  && temp="$(attr 190)"
    unsafe="$(attr_named '^(Unexpect.*Power_Loss|POR_Recovery_Count|Unsafe_Shutdown)')"
    health="$(awk '/overall-health self-assessment/ { sub(/^[^:]*: */, ""); print; exit }' <<< "$OUT")"
    errlog="$(awk '/^ATA Error Count:/ { print $4 + 0; exit } /No Errors Logged/ { print 0; exit }' <<< "$OUT")"
    # data written: only when the attribute's name says which unit it counts in
    written="$(awk '$1 ~ /^[0-9]+$/ && $2 == "Total_LBAs_Written" { print $10, 512; exit }
                    $1 ~ /^[0-9]+$/ && $2 == "Host_Writes_32MiB"  { print $10, 33554432; exit }
                    $1 ~ /^[0-9]+$/ && $2 ~ /^(Host|Lifetime|Total)_Writes_GiB$/ { print $10, 1073741824; exit }' <<< "$OUT")"
    [ -n "$written" ] && written="$(fmt_bytes $written)"

    NOTES=""
    [ -z "$model$serial" ] && add_note "could not read SMART data"
    wear_note "$used"
    if [ -n "$realloc" ] && [ "$realloc" -gt 0 ]; then
        [ "$realloc" -eq 1 ] && add_note "1 retired NAND block" || add_note "$realloc retired NAND blocks"
    fi
    [ -n "$media" ] && [ "$media" -gt 0 ] && add_note "$media uncorrectable errors"
    health_note "$health"
    NOTES="${NOTES:-OK}"

    set_slot "$dev"
    emit "$serial" \
        "$(printf "$FMT_N" "$SLOT" "$name" "$make" "${model:0:26}" "${serial:-?}" "${hours:-?}" "${used:-?}" "${life:-?}" \
            "n/a" "${written:-?}" "${media:-?}" "${errlog:-?}" "${unsafe:-?}" "${temp:-?}" "${health:-?}" "$NOTES")" \
        "\"$SLOT\",$name,\"$make\",\"$model\",\"$serial\",$hours,$used,$life,n/a,n/a,\"$written\",$media,$errlog,$unsafe,$temp,n/a,$health,\"$NOTES\""
}

# --- run ---------------------------------------------------------------------
echo "Disk Report v$VERSION - $(hostname) - $(date '+%Y-%m-%d %H:%M')"
echo
printf "$FMT" "Slot" "Device" "Make" "Model" "Serial" "PowerOnHrs" "Realloc" "Pending" "Uncorr" "Life%" "Health"
printf "$FMT" "----" "------" "----" "-----" "------" "----------" "-------" "-------" "------" "-----" "------"
if [ -n "$CSV_OUT" ]; then
    echo "Slot,Device,Make,Model,Serial,PowerOnHours,Reallocated,Pending,Uncorrectable,Health,SSDLifeRemaining" > "$CSV_OUT" \
        || { echo "ERROR: cannot write $CSV_OUT" >&2; CSV_OUT=""; }
fi

TMPD="$(mktemp -d /tmp/diskreport.XXXXXX)" || { echo "ERROR: cannot create temp dir" >&2; exit 1; }
trap 'rm -rf "$TMPD"' EXIT
mkdir "$TMPD/disks" "$TMPD/cache"

[ -t 2 ] && printf 'Reading %d disks, %d at a time...\r' "$(wc -w <<< "$DEVICES")" "$JOBS" >&2
for dev in $DEVICES; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || sleep 0.2; done
    case "${dev##*/}" in
        nvme*) process_nvme "$dev" > "$TMPD/cache/${dev##*/}" & ;;
        *)     if is_cache_dev "$dev"; then process_sata_cache "$dev" > "$TMPD/cache/${dev##*/}" &
               else process_disk "$dev" > "$TMPD/disks/${dev##*/}" &
               fi ;;
    esac
done
wait
[ -t 2 ] && printf '%60s\r' '' >&2

# merge a worker directory: bay order, duplicates (same serial twice) dropped
collect() { cat "$TMPD/$1"/* 2>/dev/null | sort -t "$TAB" -k1,1n -k2,2n | awk -F'\t' '$3 == "" || !seen[$3]++'; }

collect disks > "$TMPD/disks.rows"
cut -f4 "$TMPD/disks.rows"
[ -n "$CSV_OUT" ] && cut -f5 "$TMPD/disks.rows" >> "$CSV_OUT"
if cut -f6 "$TMPD/disks.rows" | grep -q .; then
    printf '\nHealth warnings (full messages from the drives):\n'
    cut -f6 "$TMPD/disks.rows" | grep . | awk '{ gsub(/@@NL@@/, "\n      "); print "  " $0 }'
fi
cat <<'EOF'

Realloc = reallocated sectors (HDD, ID 5) / retired NAND blocks (SSD, ID 5) / grown defects (SAS)
Pending = sectors waiting to be remapped (ID 197)
Uncorr  = uncorrectable sectors (ID 198) / total uncorrected read+write errors (SAS)
Life%   = SSD life remaining, as reported by the SSD itself (hard drives: n/a)
Any non-zero bad sector count is worth watching; a rising count means plan a replacement.
Plan to replace an SSD when Life% falls below about 10-20%.

SSD / M.2 Cache Drives
======================
EOF

collect cache > "$TMPD/cache.rows"
if [ -s "$TMPD/cache.rows" ]; then
    printf "$FMT_N" "Slot" "Device" "Make" "Model" "Serial" "PowerOnHrs" "Used%" "Life%" "Spare%" "Written" \
        "MediaErr" "ErrLog" "Unsafe" "Temp" "Health" "Notes"
    printf "$FMT_N" "----" "------" "----" "-----" "------" "----------" "-----" "-----" "------" "-------" \
        "--------" "------" "------" "----" "------" "-----"
    cut -f4 "$TMPD/cache.rows"
    cat <<'EOF'

Used%    = share of the drive's rated write endurance used up (wear level); Life% = 100 - Used%
Spare%   = spare flash still available / level at which the drive raises a warning (NVMe only)
Written  = total data written (SATA SSDs: only shown when the drive states the unit it counts in)
MediaErr = unrecovered data errors (SATA: uncorrectable errors, ID 187/198) - should always be 0
ErrLog   = entries in the drive's error log; often harmless (e.g. unsupported commands), watch for fast growth
Unsafe   = power losses without a clean shutdown
EOF
    if [ -n "$CSV_OUT" ]; then
        NVME_CSV="${CSV_OUT%.csv}_nvme.csv"
        { echo "Slot,Device,Make,Model,Serial,PowerOnHours,PercentUsed,LifeRemaining,AvailableSpare,SpareThreshold,DataWritten,MediaErrors,ErrorLogEntries,UnsafeShutdowns,TemperatureC,CriticalWarning,Health,Notes"
          cut -f5 "$TMPD/cache.rows"; } > "$NVME_CSV" || NVME_CSV=""
    fi
else
    echo "No SSD or M.2 cache drives found."
fi

[ -n "$CSV_OUT" ] && printf '\nCSV saved to: %s\n' "$CSV_OUT"
[ -n "${NVME_CSV:-}" ] && echo "NVMe CSV saved to: $NVME_CSV"
