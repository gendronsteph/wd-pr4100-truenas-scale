#!/bin/bash
# Common helpers for WD PR4100 / PR2100 front panel control on TrueNAS SCALE.
# Designed for external script files executed by TrueNAS init/shutdown tasks.

set -u

PR_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_STATE_DIR="/tmp/pr4100-hw"
PR_LOG_FILE="${PR_STATE_DIR}/pr4100.log"
PR_LOCK_FILE="${PR_STATE_DIR}/serial.lock"
mkdir -p "$PR_STATE_DIR"

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$PR_LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_linux() {
    [ "$(uname -s)" = "Linux" ]
}

get_tty_candidates() {
    printf '%s\n' /dev/ttyS2 /dev/ttyS5 /dev/ttyS3 /dev/ttyS4
}

get_hw_tty() {
    local dev
    for dev in $(get_tty_candidates); do
        [ -e "$dev" ] && { echo "$dev"; return 0; }
    done
    return 1
}

hex2dec() {
    local v="${1#0x}"
    [[ "$v" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    printf '%d\n' "$((16#$v))"
}

pct_to_hex() {
    local p="${1:-0}"
    [ "$p" -lt 0 ] && p=0
    [ "$p" -gt 100 ] && p=100
    printf '%02X\n' "$p"
}

ensure_deps() {
    local missing=0 cmd
    for cmd in timeout awk sed grep cut tr sort head tail flock find readlink lsblk; do
        command_exists "$cmd" || { log "Missing dependency: $cmd"; missing=1; }
    done
    for cmd in sensors smartctl zpool ip hostname; do
        command_exists "$cmd" || log "Optional dependency not found: $cmd"
    done
    return "$missing"
}

serial_send() {
    local cmd="${1:-}"
    local tty reply

    tty="$(get_hw_tty)" || {
        log "no working tty found"
        return 1
    }

    mkdir -p "$PR_STATE_DIR"

    (
        flock -x 9 || exit 1

        exec 4<>"$tty" || {
            log "failed to open $tty"
            exit 1
        }

        printf '%s\r' "$cmd" >&4

        if ! IFS= read -r -t 2 reply <&4; then
            log "timeout waiting reply for '$cmd' on $tty"
            exec 4<&-
            exit 1
        fi

        if [ "$reply" = "ALERT" ]; then
            log "PMC ALERT while sending '$cmd'"
            printf '%s\n' "$reply"
            exec 4<&-
            exit 2
        fi

        if [ -z "$reply" ] || [ "$reply" = "ERR" ]; then
            log "PMC bad reply for '$cmd' on $tty: '${reply:-<empty>}'"
            exec 4<&-
            exit 1
        fi

        printf '\r' >&4
        IFS= read -r -t 1 _ignore <&4 || true

        exec 4<&-
        printf '%s\n' "$reply"
    ) 9>"$PR_LOCK_FILE"
}

pmc_get() {
    local raw key
    key="$1"
    raw="$(serial_send "$key")" || return 1
    if [[ "$raw" == *=* ]]; then
        printf '%s\n' "${raw#*=}"
    else
        printf '%s\n' "$raw"
    fi
}

pmc_set() {
    serial_send "$1" >/dev/null 2>&1
}

lcd_line() {
    local n text maxlen
    n="$1"
    shift
    text="$*"
    maxlen=16
    text="$(sanitize_lcd "$text")"
    text="${text:0:$maxlen}"
    pmc_set "LN${n}=${text}"
}

lcd_show() {
    local line1="${1:-}" line2="${2:-}"
    lcd_line 1 "$line1"
    lcd_line 2 "$line2"
}

center16() {
    local s len pad_left pad_right
    s="$(sanitize_lcd "$1")"
    s="${s:0:16}"
    len=${#s}

    if [ "$len" -ge 16 ]; then
        printf '%s\n' "$s"
        return
    fi

    pad_left=$(( (16 - len) / 2 ))
    pad_right=$(( 16 - len - pad_left ))

    printf '%*s%s%*s\n' "$pad_left" "" "$s" "$pad_right" ""
}

lcd_show_center() {
    local line1="${1:-}" line2="${2:-}"
    lcd_line 1 "$(center16 "$line1")"
    lcd_line 2 "$(center16 "$line2")"
}

lcd_backlight_pct() {
    pmc_set "BKL=$(pct_to_hex "${1:-100}")"
}

fan_set_pct() {
    pmc_set "FAN=$(pct_to_hex "${1:-35}")"
}

fan_get_pct() {
    local v
    v="$(pmc_get FAN 2>/dev/null)" || return 1
    hex2dec "$v"
}

fan_get_rpm() {
    local v
    v="$(pmc_get RPM 2>/dev/null)" || return 1
    hex2dec "$v"
}

pmc_get_temp_c() {
    local v
    v="$(pmc_get TMP 2>/dev/null)" || return 1
    hex2dec "$v"
}

led_set() {
    local mode="${1:-solid}" color="${2:-blue}" code="10"

    case "${color,,}" in
        off) code="00" ;;
        blue|blu) code="10" ;;
        red) code="08" ;;
        purple|violet|pur) code="18" ;;
        green|gre) code="04" ;;
        teal|cyan|tea) code="05" ;;
        yellow|amber|ylw) code="06" ;;
        white|wht) code="07" ;;
    esac

    pmc_set "LED=$code"

    case "${mode,,}" in
        blink|flash)
            pmc_set "PLS=00"
            case "${color,,}" in
                blue|blu) pmc_set "BLK=01" ;;
                red) pmc_set "BLK=02" ;;
                purple|violet|pur) pmc_set "BLK=03" ;;
                green|gre) pmc_set "BLK=04" ;;
                teal|cyan|tea) pmc_set "BLK=05" ;;
                yellow|amber|ylw) pmc_set "BLK=06" ;;
                white|wht) pmc_set "BLK=07" ;;
                *) pmc_set "BLK=00" ;;
            esac
            ;;
        pulse)
            pmc_set "BLK=00"
            pmc_set "PLS=01"
            ;;
        *)
            pmc_set "BLK=00"
            pmc_set "PLS=00"
            ;;
    esac
}

get_hostname_short() {
    hostname -s 2>/dev/null || hostname 2>/dev/null || echo "truenas"
}

get_primary_ip() {
    local ipaddr
    ipaddr="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    [ -n "$ipaddr" ] || ipaddr="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s\n' "${ipaddr:-no ip}"
}

get_internal_drives() {
    local out=()
    local path target disk_name rm tran rota model

    if [ -d /dev/disk/by-id ]; then
        while IFS= read -r path; do
            [ -L "$path" ] || continue
            [[ "$path" == *-part* ]] && continue

            target="$(readlink -f "$path" 2>/dev/null || true)"
            [ -b "$target" ] || continue

            case "$target" in
                /dev/sd*)
                    ;;
                *)
                    continue
                    ;;
            esac

            disk_name="$(basename "$target")"

            rm="$(lsblk -dn -o RM "/dev/$disk_name" 2>/dev/null | tr -d ' ')"
            [ "${rm:-0}" = "1" ] && continue

            tran="$(lsblk -dn -o TRAN "/dev/$disk_name" 2>/dev/null | tr -d ' ')"
            [ "${tran:-}" = "usb" ] && continue

            rota="$(lsblk -dn -o ROTA "/dev/$disk_name" 2>/dev/null | tr -d ' ')"
            model="$(lsblk -dn -o MODEL "/dev/$disk_name" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

            if [ "${rota:-0}" = "1" ]; then
                out+=("$target")
                continue
            fi

            case "${model,,}" in
                *wd*|*western*digital*)
                    out+=("$target")
                    ;;
            esac
        done < <(find /dev/disk/by-id -maxdepth 1 -type l \( -name 'ata-*' -o -name 'wwn-*' \) 2>/dev/null | sort)
    fi

    printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++' | head -n 4
}

get_disk_temp() {
    local disk out temp
    disk="$1"
    out="$(smartctl -n standby -A "$disk" 2>/dev/null)"
    case $? in
        2) echo STANDBY; return 0 ;;
        0|4|64|68) ;;
        *) echo ERR; return 1 ;;
    esac

    temp="$(printf '%s\n' "$out" | awk '
        /Temperature_Celsius/ {print $10; found=1; exit}
        /Temperature_Internal/ {print $10; found=1; exit}
        /Current Drive Temperature/ {print $4; found=1; exit}
        /194 Temperature_Celsius/ {print $10; found=1; exit}
        END {if (!found) print ""}
    ' | tr -dc '0-9')"

    if [ -n "$temp" ]; then
        echo "$temp"
        return 0
    fi

    echo NA
}

get_cpu_temp() {
    local out t
    out="$(sensors 2>/dev/null || true)"
    [ -n "$out" ] || { echo NA; return 1; }

    t="$(printf '%s\n' "$out" | awk '
        /Package id 0:/ {print $4; exit}
        /^Tctl:/ {print $2; exit}
        /^Tdie:/ {print $2; exit}
        /Core 0:/ {print $3; exit}
    ' | tr -d "+°C" | cut -d. -f1)"

    [ -n "$t" ] || { echo NA; return 1; }
    echo "$t"
}

get_pool_name() {
    zpool list -H -o name 2>/dev/null | awk '$1 != "boot-pool" {print; exit}'
}

get_pool_state() {
    local pool="$1"
    [ -n "$pool" ] || { echo NOPOOL; return 0; }
    zpool list -H -o health "$pool" 2>/dev/null | head -n1
}

get_pool_usage_line() {
    local pool="$1"
    [ -n "$pool" ] || { echo "no data"; return 0; }
    zpool list -H -o cap,free "$pool" 2>/dev/null | awk '{printf "used %s free %s", $1, $2}'
}

get_pool_activity() {
    local pool="$1" status line
    [ -n "$pool" ] || { echo "idle"; return 0; }

    status="$(zpool status "$pool" 2>/dev/null || true)"
    line="$(printf '%s\n' "$status" | awk '/scan:/ {sub(/^ +/, ""); print; exit}')"
    [ -n "$line" ] || line="idle"

    case "$line" in
        *resilver*|*scrub*)
            printf '%s\n' "$line" | cut -c1-32
            ;;
        *)
            echo "idle"
            ;;
    esac
}

pmc_enable_button_interrupts() {
    pmc_set "IMR=FF"
}

pmc_disable_interrupts() {
    pmc_set "IMR=00"
}

pmc_get_isr_hex() {
    local v
    v="$(pmc_get ISR 2>/dev/null || true)"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

pmc_get_isr_dec() {
    local v
    v="$(pmc_get_isr_hex)" || return 1
    hex2dec "$v"
}

pmc_is_button_up() {
    local isr="${1:-0}"
    [ $(( isr & 0x20 )) -ne 0 ]
}

pmc_is_button_down() {
    local isr="${1:-0}"
    [ $(( isr & 0x40 )) -ne 0 ]
}

pmc_is_button_usb() {
    local isr="${1:-0}"
    [ $(( isr & 0x08 )) -ne 0 ]
}

get_button_isr() {
    pmc_get ISR 2>/dev/null || true
}

sanitize_lcd() {
    printf '%s' "$1" | tr -cd '[:print:]' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

shorten16() {
    local s
    s="$(sanitize_lcd "$1")"
    printf '%s\n' "${s:0:16}"
}
