#!/bin/bash
# =============================================================================
# modules/screensaver.sh
# Fullscreen clock + weather screensaver via swayidle
#
# Can be run standalone: bash modules/screensaver.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

section "Screensaver - Clock + Weather"
echo "  Displays a fullscreen clock with weather info from Home Assistant."
echo "  Activates after 2 minutes of inactivity. Touch screen to dismiss."
echo ""
echo "  Requires a Home Assistant long-lived access token."
echo "  Get one at: HA Profile page > Long-Lived Access Tokens"
echo ""

if ! confirm_or_skip "Install clock/weather screensaver?"; then
    log "Skipping screensaver"
    exit 0
fi

prompt_ha_url
prompt_ha_token
prompt_ha_weather

sudo apt-get install -y --no-install-recommends \
    swayidle \
    wlr-randr

SCREENSAVER_DIR="${USER_HOME}/.config/mark2-screensaver"
mkdir -p "$SCREENSAVER_DIR"

TEMPLATE_DIR="$(dirname "$0")/../templates"

# Copy template and substitute placeholders
sed \
    -e "s|%%HA_URL%%|${HA_URL}|g" \
    -e "s|%%HA_TOKEN%%|${HA_TOKEN}|g" \
    -e "s|%%HA_WEATHER_ENTITY%%|${HA_WEATHER_ENTITY}|g" \
    "${TEMPLATE_DIR}/screensaver.html" > "${SCREENSAVER_DIR}/screensaver.html"

log "Created screensaver: ${SCREENSAVER_DIR}/screensaver.html"

SWAYIDLE_CONF="${USER_HOME}/.config/swayidle/config"
mkdir -p "$(dirname "$SWAYIDLE_CONF")"
SCREENSAVER_URL="file://${SCREENSAVER_DIR}/screensaver.html"

cat > "$SWAYIDLE_CONF" << EOF
# Mark II screensaver - activates after 2 minutes idle
timeout 120 'chromium --app="${SCREENSAVER_URL}" --kiosk --ozone-platform=wayland --password-store=basic --no-first-run --disable-infobars 2>/dev/null &'
    resume 'pkill -f "screensaver.html" 2>/dev/null; true'
EOF

# Add swayidle to labwc autostart
labwc_autostart_add "swayidle" "swayidle -w &"

log "Screensaver configured (activates after 2 min idle)"
info "Change timeout: edit ${SWAYIDLE_CONF}"
