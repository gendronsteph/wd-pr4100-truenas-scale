#!/bin/bash
# WD PR4100 post-init monitor / LCD rotator for TrueNAS SCALE

set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${BASE_DIR}/pr4100-common.sh"

PID_FILE="${PR_STATE_DIR}/wdpostinit.pid"
METRICS_FILE="${PR_STATE_DIR}/metrics.env"

UPDATE_SENSORS_EVERY=15
UPDATE_DISPLAY_EVERY=5
BUTTON_POLL_EVERY=1
BUTTON_IDLE_TIMEOUT=30

MIN_FAN=35
MID_FAN=45
HIGH_FAN=60
MAX_FAN=100

CPU_WARM=55
CPU_HOT=70
DISK_WARM=42
DISK_HOT=48
PMC_WARM=60
PMC_HOT=66
LOW_RPM_WARN=400

TRANSFER_MBPS_THRESHOLD=15

AUTO_ROTATE=1
CURRENT_PAGE=0
LAST_BUTTON_TS=0
LAST_SENSOR_TS=0
LAST_ACTIVITY_TS=0
NEXT_DISPLAY_TS=0
LAST_ISR=""
TRANSFER_SCREEN_TOGGLE=0

HOSTNAME_SHORT="TrueNAS"
PRIMARY_IP="no ip"
PRIMARY_IFACE=""
POOL_NAME=""
POOL_STATE="NOPOOL"
POOL_USAGE="no data"
POOL_ACTIVITY="idle"
CPU_TEMP="NA"
PMC_TEMP="NA"
FAN_RPM="NA"
FAN_PCT="NA"
DISK_SUMMARY="no disks"
DISK_LINE1="No disks"
DISK_LINE2=""
HOTTEST_DISK_TEMP="NA"

NET_RX_BPS=0
NET_TX_BPS=0
NET_RX_MBPS="0.0"
NET_TX_MBPS="0.0"

DISK_R_BPS=0
DISK_W_BPS=0
DISK_R_MBPS="0.0"
DISK_W_MBPS="0.0"

UPTIME_TEXT="0m"
RAM_LINE="RAM N/A"
ARC_LINE="ARC N/A"

LAST_NET_RX_BYTES=0
LAST_NET_TX_BYTES=0
LAST_DISK_R_BYTES=0
LAST_DISK_W_BYTES=0

TRANSFER_ACTIVE=0

ALERT_LINE1=""
ALERT_LINE2=""
ALERT_ACTIVE=0

cleanup() {
    rm -f "$PID_FILE"
    log "wdpostinit-v2 stopped"
}
trap cleanup INT TERM EXIT

page_count() {
    echo 11
}

write_metrics_file() {
    cat > "$METRICS_FILE" <<EOF
HOSTNAME_SHORT=${HOSTNAME_SHORT}
PRIMARY_IP=${PRIMARY_IP}
PRIMARY_IFACE=${PRIMARY_IFACE}
POOL_NAME=${POOL_NAME}
POOL_STATE=${POOL_STATE}
POOL_USAGE=${POOL_USAGE}
POOL_ACTIVITY=${POOL_ACTIVITY}
CPU_TEMP=${CPU_TEMP}
PMC_TEMP=${PMC_TEMP}
FAN_RPM=${FAN_RPM}
FAN_PCT=${FAN_PCT}
DISK_SUMMARY=${DISK_SUMMARY}
DISK_LINE1=${DISK_LINE1}
DISK_LINE2=${DISK_LINE2}
HOTTEST_DISK_TEMP=${HOTTEST_DISK_TEMP}
NET_RX_MBPS=${NET_RX_MBPS}
NET_TX_MBPS=${NET_TX_MBPS}
DISK_R_MBPS=${DISK_R_MBPS}
DISK_W_MBPS=${DISK_W_MBPS}
UPTIME_TEXT=${UPTIME_TEXT}
RAM_LINE=${RAM_LINE}
ARC_LINE=${ARC_LINE}
TRANSFER_ACTIVE=${TRANSFER_ACTIVE}
ALERT_ACTIVE=${ALERT_ACTIVE}
ALERT_LINE1=${ALERT_LINE1}
ALERT_LINE2=${ALERT_LINE2}
EOF
}

get_primary_iface() {
    local iface
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    [ -n "$iface" ] || iface="$(ip route 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    printf '%s\n' "${iface:-}"
}

read_net_bytes_sysfs() {
    local iface="$1"
    local rx_file tx_file rx tx

    [ -n "$iface" ] || {
        echo "0 0"
        return 0
    }

    rx_file="/sys/class/net/${iface}/statistics/rx_bytes"
    tx_file="/sys/class/net/${iface}/statistics/tx_bytes"

    [ -r "$rx_file" ] || {
        echo "0 0"
        return 0
    }
    [ -r "$tx_file" ] || {
        echo "0 0"
        return 0
    }

    rx="$(cat "$rx_file" 2>/dev/null || echo 0)"
    tx="$(cat "$tx_file" 2>/dev/null || echo 0)"

    echo "${rx:-0} ${tx:-0}"
}

read_internal_disk_bytes() {
    local disks disk devname sectors_r sectors_w
    local total_r=0 total_w=0

    mapfile -t disks < <(get_internal_drives)

    [ "${#disks[@]}" -gt 0 ] || {
        echo "0 0"
        return 0
    }

    for disk in "${disks[@]}"; do
        devname="$(basename "$disk")"
        read -r sectors_r sectors_w < <(
            awk -v dev="$devname" '$3 == dev {print $6, $10; found=1} END {if (!found) print "0 0"}' /proc/diskstats 2>/dev/null
        )

        [[ "${sectors_r:-0}" =~ ^[0-9]+$ ]] || sectors_r=0
        [[ "${sectors_w:-0}" =~ ^[0-9]+$ ]] || sectors_w=0

        total_r=$(( total_r + (sectors_r * 512) ))
        total_w=$(( total_w + (sectors_w * 512) ))
    done

    echo "$total_r $total_w"
}

format_mbps_1() {
    local bps="${1:-0}"
    awk -v b="$bps" 'BEGIN {printf "%.1f", b/1024/1024}'
}

format_bytes_short() {
    local bytes="${1:-0}"
    awk -v b="$bytes" '
        BEGIN {
            if (b >= 1099511627776) printf "%.1fT", b/1099511627776;
            else if (b >= 1073741824) printf "%.1fG", b/1073741824;
            else if (b >= 1048576) printf "%.1fM", b/1048576;
            else if (b >= 1024) printf "%.1fK", b/1024;
            else printf "%dB", b;
        }'
}

format_uptime_short() {
    local total
    local d h m
    total="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
    d=$(( total / 86400 ))
    h=$(( (total % 86400) / 3600 ))
    m=$(( (total % 3600) / 60 ))

    if [ "$d" -gt 0 ]; then
        printf '%dd %02dh\n' "$d" "$h"
    elif [ "$h" -gt 0 ]; then
        printf '%dh %02dm\n' "$h" "$m"
    else
        printf '%dm\n' "$m"
    fi
}

get_ram_arc_lines() {
    local mem_total_kb mem_avail_kb mem_used_kb
    local mem_used mem_total arc_bytes arc_human

    mem_total_kb="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
    mem_avail_kb="$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"

    if [ -n "${mem_total_kb:-}" ] && [ -n "${mem_avail_kb:-}" ]; then
        mem_used_kb=$(( mem_total_kb - mem_avail_kb ))
        mem_used="$(awk -v k="$mem_used_kb" 'BEGIN {printf "%.1fG", k/1024/1024}')"
        mem_total="$(awk -v k="$mem_total_kb" 'BEGIN {printf "%.1fG", k/1024/1024}')"
        RAM_LINE="RAM ${mem_used}/${mem_total}"
    else
        RAM_LINE="RAM N/A"
    fi

    arc_bytes="$(awk '$1 == "size" {print $3; exit}' /proc/spl/kstat/zfs/arcstats 2>/dev/null)"
    if [ -n "${arc_bytes:-}" ]; then
        arc_human="$(format_bytes_short "$arc_bytes")"
        ARC_LINE="ARC ${arc_human}"
    else
        ARC_LINE="ARC N/A"
    fi
}

refresh_activity_metrics() {
    local now elapsed cur_net_rx cur_net_tx
    local cur_disk_r cur_disk_w
    local delta_rx delta_tx delta_disk_r delta_disk_w

    now="$(date +%s)"
    if [ "$LAST_ACTIVITY_TS" -gt 0 ]; then
        elapsed=$(( now - LAST_ACTIVITY_TS ))
        [ "$elapsed" -le 0 ] && elapsed=1
    else
        elapsed=1
    fi
    LAST_ACTIVITY_TS="$now"

    PRIMARY_IFACE="$(get_primary_iface)"
    read -r cur_net_rx cur_net_tx < <(read_net_bytes_sysfs "$PRIMARY_IFACE")
    read -r cur_disk_r cur_disk_w < <(read_internal_disk_bytes)

    if [ "$LAST_NET_RX_BYTES" -gt 0 ] || [ "$LAST_NET_TX_BYTES" -gt 0 ]; then
        delta_rx=$(( cur_net_rx - LAST_NET_RX_BYTES ))
        delta_tx=$(( cur_net_tx - LAST_NET_TX_BYTES ))
        [ "$delta_rx" -lt 0 ] && delta_rx=0
        [ "$delta_tx" -lt 0 ] && delta_tx=0
        NET_RX_BPS=$(( delta_rx / elapsed ))
        NET_TX_BPS=$(( delta_tx / elapsed ))
    else
        NET_RX_BPS=0
        NET_TX_BPS=0
    fi

    if [ "$LAST_DISK_R_BYTES" -gt 0 ] || [ "$LAST_DISK_W_BYTES" -gt 0 ]; then
        delta_disk_r=$(( cur_disk_r - LAST_DISK_R_BYTES ))
        delta_disk_w=$(( cur_disk_w - LAST_DISK_W_BYTES ))
        [ "$delta_disk_r" -lt 0 ] && delta_disk_r=0
        [ "$delta_disk_w" -lt 0 ] && delta_disk_w=0
        DISK_R_BPS=$(( delta_disk_r / elapsed ))
        DISK_W_BPS=$(( delta_disk_w / elapsed ))
    else
        DISK_R_BPS=0
        DISK_W_BPS=0
    fi

    LAST_NET_RX_BYTES="$cur_net_rx"
    LAST_NET_TX_BYTES="$cur_net_tx"
    LAST_DISK_R_BYTES="$cur_disk_r"
    LAST_DISK_W_BYTES="$cur_disk_w"

    NET_RX_MBPS="$(format_mbps_1 "$NET_RX_BPS")"
    NET_TX_MBPS="$(format_mbps_1 "$NET_TX_BPS")"
    DISK_R_MBPS="$(format_mbps_1 "$DISK_R_BPS")"
    DISK_W_MBPS="$(format_mbps_1 "$DISK_W_BPS")"

    if awk -v a="${NET_RX_MBPS:-0}" -v b="${NET_TX_MBPS:-0}" -v c="${DISK_R_MBPS:-0}" -v d="${DISK_W_MBPS:-0}" -v t="$TRANSFER_MBPS_THRESHOLD" 'BEGIN {exit !((a>=t)||(b>=t)||(c>=t)||(d>=t))}'; then
        TRANSFER_ACTIVE=1
    else
        TRANSFER_ACTIVE=0
    fi

    UPTIME_TEXT="$(format_uptime_short)"
    get_ram_arc_lines
}

collect_disk_summary() {
    local disks disk idx=1 t
    local line1="" line2=""
    local hottest=""

    DISK_SUMMARY="no disks"
    DISK_LINE1="No disks"
    DISK_LINE2=""
    HOTTEST_DISK_TEMP="NA"

    mapfile -t disks < <(get_internal_drives)

    [ "${#disks[@]}" -gt 0 ] || return 0

    for disk in "${disks[@]}"; do
        t="$(get_disk_temp "$disk" 2>/dev/null || true)"

        case "$t" in
            STANDBY)
                t="slp"
                ;;
            ERR|"")
                t="ERR"
                ;;
            NA)
                t="NA"
                ;;
            *)
                if [[ "$t" =~ ^[0-9]+$ ]]; then
                    [ -z "$hottest" ] && hottest="$t"
                    [ "$t" -gt "${hottest:-0}" ] && hottest="$t"
                    t="${t}C"
                fi
                ;;
        esac

        if [ "$idx" -le 2 ]; then
            line1="${line1}D${idx}:${t} "
        else
            line2="${line2}D${idx}:${t} "
        fi

        idx=$((idx + 1))
    done

    line1="$(printf '%s' "$line1" | sed 's/[[:space:]]*$//')"
    line2="$(printf '%s' "$line2" | sed 's/[[:space:]]*$//')"

    DISK_LINE1="$line1"
    DISK_LINE2="$line2"
    DISK_SUMMARY="$line1 | $line2"

    if [[ "$hottest" =~ ^[0-9]+$ ]]; then
        HOTTEST_DISK_TEMP="$hottest"
    fi
}

pick_fan_speed() {
    local target="$MIN_FAN"

    if [ "$ALERT_ACTIVE" -eq 1 ]; then
        echo "$MAX_FAN"
        return
    fi

    if [[ "$CPU_TEMP" =~ ^[0-9]+$ ]]; then
        if [ "$CPU_TEMP" -ge "$CPU_HOT" ]; then
            echo "$MAX_FAN"
            return
        elif [ "$CPU_TEMP" -ge "$CPU_WARM" ]; then
            target="$MID_FAN"
        fi
    fi

    if [[ "$HOTTEST_DISK_TEMP" =~ ^[0-9]+$ ]]; then
        if [ "$HOTTEST_DISK_TEMP" -ge "$DISK_HOT" ]; then
            echo "$MAX_FAN"
            return
        elif [ "$HOTTEST_DISK_TEMP" -ge "$DISK_WARM" ] && [ "$target" -lt "$HIGH_FAN" ]; then
            target="$HIGH_FAN"
        fi
    fi

    if [[ "$PMC_TEMP" =~ ^[0-9]+$ ]]; then
        if [ "$PMC_TEMP" -ge "$PMC_HOT" ]; then
            echo "$MAX_FAN"
            return
        elif [ "$PMC_TEMP" -ge "$PMC_WARM" ] && [ "$target" -lt "$HIGH_FAN" ]; then
            target="$HIGH_FAN"
        fi
    fi

    echo "$target"
}

update_alert_state() {
    ALERT_ACTIVE=0
    ALERT_LINE1=""
    ALERT_LINE2=""

    if [[ "$CPU_TEMP" =~ ^[0-9]+$ ]] && [ "$CPU_TEMP" -ge "$CPU_HOT" ]; then
        ALERT_ACTIVE=1
        ALERT_LINE1="CPU HOT"
        ALERT_LINE2="${CPU_TEMP}C"
        return
    fi

    if [[ "$HOTTEST_DISK_TEMP" =~ ^[0-9]+$ ]] && [ "$HOTTEST_DISK_TEMP" -ge "$DISK_HOT" ]; then
        ALERT_ACTIVE=1
        ALERT_LINE1="DISK HOT"
        ALERT_LINE2="${HOTTEST_DISK_TEMP}C"
        return
    fi

    if [[ "$PMC_TEMP" =~ ^[0-9]+$ ]] && [ "$PMC_TEMP" -ge "$PMC_HOT" ]; then
        ALERT_ACTIVE=1
        ALERT_LINE1="PMC HOT"
        ALERT_LINE2="${PMC_TEMP}C"
        return
    fi

    if [[ "$FAN_RPM" =~ ^[0-9]+$ ]] && [ "$FAN_RPM" -lt "$LOW_RPM_WARN" ]; then
        ALERT_ACTIVE=1
        ALERT_LINE1="FAN LOW"
        ALERT_LINE2="${FAN_RPM}RPM"
        return
    fi

    if [ -n "$POOL_NAME" ] && [ "$POOL_STATE" != "ONLINE" ]; then
        ALERT_ACTIVE=1
        ALERT_LINE1="POOL"
        ALERT_LINE2="$POOL_STATE"
        return
    fi
}

refresh_metrics() {
    local newfan

    HOSTNAME_SHORT="TrueNAS"
    PRIMARY_IP="$(get_primary_ip)"
    POOL_NAME="$(get_pool_name)"
    POOL_STATE="$(get_pool_state "$POOL_NAME")"
    POOL_USAGE="$(get_pool_usage_line "$POOL_NAME")"
    POOL_ACTIVITY="$(get_pool_activity "$POOL_NAME")"
    CPU_TEMP="$(get_cpu_temp || echo NA)"
    PMC_TEMP="$(pmc_get_temp_c || echo NA)"
    FAN_RPM="$(fan_get_rpm || echo NA)"
    FAN_PCT="$(fan_get_pct || echo NA)"

    collect_disk_summary
    update_alert_state

    newfan="$(pick_fan_speed)"
    fan_set_pct "$newfan"
    FAN_PCT="$newfan"

    if [ "$ALERT_ACTIVE" -eq 1 ]; then
        led_set flash red
    else
        led_set solid blue
    fi

    write_metrics_file
    log "metrics: ip=$PRIMARY_IP pool=${POOL_NAME:-none}/$POOL_STATE cpu=$CPU_TEMP pmc=$PMC_TEMP fanrpm=$FAN_RPM fanpct=$FAN_PCT hottest_disk=$HOTTEST_DISK_TEMP netrx=${NET_RX_MBPS} nettx=${NET_TX_MBPS} diskr=${DISK_R_MBPS} diskw=${DISK_W_MBPS} transfer=$TRANSFER_ACTIVE alert=$ALERT_ACTIVE"
}

show_page() {
    local page line1 line2 used_pct free_val status room
    page="$1"

    if [ "$ALERT_ACTIVE" -eq 1 ]; then
        lcd_show_center "$ALERT_LINE1" "$ALERT_LINE2"
        return
    fi

    case "$page" in
        0)
            line1="TrueNAS"
            line2="$PRIMARY_IP"
            ;;
        1)
            line1="Pool $POOL_NAME"
            line2="$POOL_STATE"
            ;;
        2)
            used_pct="$(printf '%s\n' "$POOL_USAGE" | awk '{for(i=1;i<=NF;i++) if($i=="used") {print $(i+1); exit}}')"
            free_val="$(printf '%s\n' "$POOL_USAGE" | awk '{for(i=1;i<=NF;i++) if($i=="free") {print $(i+1); exit}}')"
            status="$(sanitize_lcd "$POOL_ACTIVITY")"

            [ -n "$used_pct" ] || used_pct="?"
            [ -n "$free_val" ] || free_val="?"
            [ -n "$status" ] || status="idle"

            line1="used: $used_pct"
            room=$((16 - ${#line1} - 1))

            if [ "$room" -gt 0 ]; then
                status="${status:0:$room}"
                line1="${line1} ${status}"
            else
                line1="${line1:0:16}"
            fi

            line2="free: $free_val"
            ;;
        3)
            line1="CPU ${CPU_TEMP}C"
            if [[ "$PMC_TEMP" =~ ^[0-9]+$ ]]; then
                line2="PMC ${PMC_TEMP}C"
            else
                line2=""
            fi
            ;;
        4)
            if [[ "$FAN_PCT" =~ ^[0-9]+$ ]]; then
                line1="Fan ${FAN_PCT}%"
            else
                line1="Fan Auto"
            fi

            if [[ "$FAN_RPM" =~ ^[0-9]+$ ]]; then
                line2="RPM $FAN_RPM"
            else
                line2="RPM N/A"
            fi
            ;;
        5)
            line1="Hot disk"
            if [[ "$HOTTEST_DISK_TEMP" =~ ^[0-9]+$ ]]; then
                line2="${HOTTEST_DISK_TEMP}C"
            else
                line2="N/A"
            fi
            ;;
        6)
            line1="$DISK_LINE1"
            line2="$DISK_LINE2"
            ;;
        7)
            line1="Rx ${NET_RX_MBPS}M/s"
            line2="Tx ${NET_TX_MBPS}M/s"
            ;;
        8)
            line1="DiskR ${DISK_R_MBPS}"
            line2="DiskW ${DISK_W_MBPS}"
            line1="${line1}M/s"
            line2="${line2}M/s"
            line1="${line1:0:16}"
            line2="${line2:0:16}"
            ;;
        9)
            line1="Uptime"
            line2="$UPTIME_TEXT"
            ;;
        10)
            line1="$RAM_LINE"
            line2="$ARC_LINE"
            ;;
        *)
            line1="TrueNAS"
            line2="$PRIMARY_IP"
            ;;
    esac

    lcd_show_center "$line1" "$line2"
}

handle_buttons() {
    local isr_hex isr_dec now

    isr_hex="$(pmc_get_isr_hex || true)"
    [ -n "$isr_hex" ] || return 0

    isr_dec="$(hex2dec "$isr_hex" 2>/dev/null || true)"
    [ -n "$isr_dec" ] || return 0
    [ "$isr_dec" -eq 0 ] && return 0

    now="$(date +%s)"

    if [ "$LAST_ISR" = "$isr_hex" ] && [ $((now - LAST_BUTTON_TS)) -lt 1 ]; then
        return 0
    fi

    LAST_ISR="$isr_hex"
    LAST_BUTTON_TS="$now"

    if pmc_is_button_up "$isr_dec"; then
        CURRENT_PAGE=$(( CURRENT_PAGE + 1 ))
        if [ "$CURRENT_PAGE" -ge "$(page_count)" ]; then
            CURRENT_PAGE=0
        fi
        AUTO_ROTATE=0
        show_page "$CURRENT_PAGE"
        log "button up pressed isr=$isr_hex page=$CURRENT_PAGE"
        return 0
    fi

    if pmc_is_button_down "$isr_dec"; then
        CURRENT_PAGE=$(( CURRENT_PAGE - 1 ))
        if [ "$CURRENT_PAGE" -lt 0 ]; then
            CURRENT_PAGE=$(( $(page_count) - 1 ))
        fi
        AUTO_ROTATE=0
        show_page "$CURRENT_PAGE"
        log "button down pressed isr=$isr_hex page=$CURRENT_PAGE"
        return 0
    fi

    if pmc_is_button_usb "$isr_dec"; then
        log "usb button pressed isr=$isr_hex"
        return 0
    fi
}

next_auto_page() {
    if [ "$TRANSFER_ACTIVE" -eq 1 ]; then
        if [ "$TRANSFER_SCREEN_TOGGLE" -eq 0 ]; then
            TRANSFER_SCREEN_TOGGLE=1
            echo 7
        else
            TRANSFER_SCREEN_TOGGLE=0
            echo 8
        fi
        return 0
    fi

    CURRENT_PAGE=$(( CURRENT_PAGE + 1 ))
    if [ "$CURRENT_PAGE" -ge "$(page_count)" ]; then
        CURRENT_PAGE=0
    fi
    echo "$CURRENT_PAGE"
}

if [ -f "$PID_FILE" ]; then
    oldpid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
        log "existing wdpostinit-v2 already running with pid $oldpid, exiting"
        exit 0
    fi
fi

echo $$ > "$PID_FILE"
log "wdpostinit-v2 starting"

ensure_deps || {
    log "missing required dependencies, exiting"
    exit 1
}

lcd_backlight_pct 100
led_set solid blue
fan_set_pct 55
lcd_show_center "TrueNAS" "Starting..."
pmc_enable_button_interrupts || true
sleep 2

refresh_metrics
refresh_activity_metrics
show_page "$CURRENT_PAGE"

LAST_BUTTON_TS="$(date +%s)"
LAST_SENSOR_TS="$LAST_BUTTON_TS"
LAST_ACTIVITY_TS="$LAST_BUTTON_TS"
NEXT_DISPLAY_TS=$(( LAST_BUTTON_TS + UPDATE_DISPLAY_EVERY ))

while true; do
    now="$(date +%s)"

    refresh_activity_metrics

    if [ $((now - LAST_SENSOR_TS)) -ge "$UPDATE_SENSORS_EVERY" ]; then
        refresh_metrics
        LAST_SENSOR_TS="$now"
    fi

    handle_buttons

    if [ "$AUTO_ROTATE" -eq 0 ] && [ $((now - LAST_BUTTON_TS)) -ge "$BUTTON_IDLE_TIMEOUT" ]; then
        AUTO_ROTATE=1
        NEXT_DISPLAY_TS=$(( now + UPDATE_DISPLAY_EVERY ))
    fi

    if [ "$AUTO_ROTATE" -eq 1 ] && [ "$now" -ge "$NEXT_DISPLAY_TS" ]; then
        CURRENT_PAGE="$(next_auto_page)"
        show_page "$CURRENT_PAGE"
        while [ "$NEXT_DISPLAY_TS" -le "$now" ]; do
            NEXT_DISPLAY_TS=$(( NEXT_DISPLAY_TS + UPDATE_DISPLAY_EVERY ))
        done
    fi

    sleep "$BUTTON_POLL_EVERY"
done
