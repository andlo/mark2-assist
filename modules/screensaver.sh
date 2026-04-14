#!/bin/bash
# =============================================================================
# modules/screensaver.sh
# Fullscreen clock + weather screensaver for the Mark II touchscreen
#
# Activates after 2 minutes of inactivity and displays a fullscreen clock
# with live weather data fetched from Home Assistant. Resumes the HA kiosk
# display when activity is detected (touch, keyboard, etc.).
#
# Architecture:
#   swayidle — Wayland idle daemon
#     → after 120s idle: launches Chromium with screensaver.html in kiosk mode
#     → on resume: kills the screensaver Chromium instance
#
#   screensaver.html — fullscreen HTML/JS clock + weather
#     → fetches HA weather entity via REST API using HA_TOKEN
#     → shows current time, date, temperature, condition icon
#
# The HA token is embedded in screensaver.html at install time.
# See KNOWN_ISSUES.md Issue 7 for the security implications and planned fix.
#
# swayidle is added to labwc autostart so it starts with the display session.
# Weston is used as the main compositor; labwc autostart handles idle detection.
#
# Requirements:
#   - HA URL, long-lived access token, and a weather entity (e.g. weather.home)
#   - swayidle package (installed by this module)
#
# Can be run standalone: bash modules/screensaver.sh
# =============================================================================
# =============================================================================
# DEPRECATED — superseded by modules/ui.sh
#
# This module is kept for reference only. The functionality it provided
# is now built into the combined kiosk page (combined.html) and installed
# automatically by modules/ui.sh.
# Do NOT run this module alongside ui.sh.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "Screensaver — Clock + Weather" "Fullscreen clock with HA weather, activates after 2 min idle"

if ! confirm_or_skip "Install clock/weather screensaver?"; then
    log "Skipping screensaver"
    exit 0
fi

prompt_ha_url
prompt_ha_token
prompt_ha_weather

apt_install swayidle wlr-randr

SCREENSAVER_DIR="${USER_HOME}/.config/mark2-screensaver"
mkdir -p "$SCREENSAVER_DIR"

TEMPLATE_DIR="$(dirname "$0")/../templates"

# Substitute HA credentials into the HTML template.
# Note: HA_TOKEN is stored in plaintext in the resulting HTML file (chmod 644).
# See KNOWN_ISSUES.md Issue 7 for planned fix.
sed \
    -e "s|%%HA_URL%%|${HA_URL}|g" \
    -e "s|%%HA_TOKEN%%|${HA_TOKEN}|g" \
    -e "s|%%HA_WEATHER_ENTITY%%|${HA_WEATHER_ENTITY}|g" \
    "${TEMPLATE_DIR}/screensaver.html" > "${SCREENSAVER_DIR}/screensaver.html"
log "Created screensaver: ${SCREENSAVER_DIR}/screensaver.html"

# swayidle config — 120 second idle timeout
SWAYIDLE_CONF="${USER_HOME}/.config/swayidle/config"
mkdir -p "$(dirname "$SWAYIDLE_CONF")"
SCREENSAVER_URL="file://${SCREENSAVER_DIR}/screensaver.html"

cat > "$SWAYIDLE_CONF" << EOF
# Mark II screensaver — activates after 2 minutes of inactivity
# Adjust timeout (seconds) to change the idle delay
timeout 120 'chromium --app="${SCREENSAVER_URL}" --kiosk --ozone-platform=wayland --password-store=basic --no-first-run --disable-infobars 2>/dev/null &'
    resume 'pkill -f "screensaver.html" 2>/dev/null; true'
EOF

# Add swayidle to labwc autostart so it runs alongside the display session
labwc_autostart_add "swayidle" "swayidle -w &"

log "Screensaver configured (activates after 2 min idle)"
info "Change timeout: edit ${SWAYIDLE_CONF} — change '120' to desired seconds"
info "Weather entity: ${HA_WEATHER_ENTITY}"
