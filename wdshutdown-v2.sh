#!/bin/bash
# WD PR4100 shutdown helper for TrueNAS SCALE
# Keep this script SHORT. It should only update LCD/LED/fan and exit.

set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${BASE_DIR}/pr4100-common.sh"

ACTION="${1:-}"

detect_action() {
    case "${ACTION,,}" in
        reboot|restart)
            echo "reboot"
            return 0
            ;;
        shutdown|poweroff|halt)
            echo "shutdown"
            return 0
            ;;
    esac

    # Best-effort fallback when called by system shutdown flow.
    # If we cannot know, default to shutdown.
    if [ -r /run/systemd/shutdown/scheduled ]; then
        if grep -qi reboot /run/systemd/shutdown/scheduled 2>/dev/null; then
            echo "reboot"
            return 0
        fi
    fi

    echo "shutdown"
}

main() {
    local mode
    mode="$(detect_action)"

    log "wdshutdown-v2 start mode=$mode"

    lcd_backlight_pct 100 || true
    fan_set_pct 100 || true
    led_set flash yellow || true

    if [ "$mode" = "reboot" ]; then
        lcd_show_center "Rebooting" "Please wait..."
    else
        lcd_show_center "Shutting down" "Please wait..."
    fi

    sync || true
    sleep 1

    log "wdshutdown-v2 exit mode=$mode"
    exit 0
}

main "$@"
