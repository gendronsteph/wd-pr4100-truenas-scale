#!/bin/bash
set -u
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BASE_DIR/pr4100-common.sh"

log "wdpreinit-v2 starting"
ensure_deps || true

lcd_backlight_pct 100 || true
fan_set_pct 55 || true
led_set solid blue || true
lcd_show "TrueNAS SCALE" "booting..." || true

# Best effort: some systems benefit from a short pause before later scripts touch the PMC again.
sleep 1
log "wdpreinit-v2 completed"
exit 0
