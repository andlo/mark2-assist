#!/bin/bash
# =============================================================================
# lib/kiosk.sh — Mark II kiosk launcher
#
# Architecture (simplified):
#   1. Chromium opens Home Assistant directly (homeassistant.local or HA_URL)
#   2. face.html runs as a transparent always-on-top overlay window
#      showing the Mark II face animation (idle/listen/think/speak)
#   3. mark2-httpd.py handles only /screen-on and /screen-off (backlight)
#
# No local HTTP proxy. No combined.html. No iframe embedding.
# HA handles its own auth and dashboard routing.
#
# Config (~/.config/mark2/config):
#   HA_URL=http://192.168.1.100:8123   (optional — defaults to homeassistant.local)
#   SCREEN_BLANK_SECONDS=300           (optional — screensaver timeout, default 5 min)
# =============================================================================
exec >> /tmp/mark2-kiosk.log 2>&1
echo "[$(date)] kiosk.sh starting"

export XDG_RUNTIME_DIR=/run/user/$(id -u)

# Load config
CONFIG="${HOME}/.config/mark2/config"
HA_URL="http://homeassistant.local"
SCREEN_BLANK_SECONDS=300
[ -f "$CONFIG" ] && source "$CONFIG"

# Detect Wayland socket
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for i in $(seq 1 30); do
        for sock in wayland-0 wayland-1 wayland-2; do
            if [ -S "/run/user/$(id -u)/${sock}" ]; then
                export WAYLAND_DISPLAY="$sock"
                break 2
            fi
        done
        sleep 1
    done
fi
echo "[$(date)] Wayland: ${WAYLAND_DISPLAY:-unset}"

# Clean up stale Chromium state
for dir in chromium-kiosk chromium-face; do
    rm -f "${HOME}/.config/${dir}/Singleton"*
    rm -f "${HOME}/.config/${dir}/Default/Last Session"
    rm -f "${HOME}/.config/${dir}/Default/Last Tabs"
    rm -f "${HOME}/.config/${dir}/Default/Current Session"
    rm -f "${HOME}/.config/${dir}/Default/Current Tabs"
    mkdir -p "${HOME}/.config/${dir}/Default"
    touch "${HOME}/.config/${dir}/First Run"
    if [ ! -f "${HOME}/.config/${dir}/Default/Preferences" ]; then
        echo '{"browser":{"theme":{"color_scheme":2}},"profile":{"content_settings":{}}}' \
            > "${HOME}/.config/${dir}/Default/Preferences"
    fi
done

# Start backlight control server (screen-on / screen-off endpoints only)
pkill -f 'mark2-httpd.py' 2>/dev/null || true
sleep 0.3
python3 "${HOME}/mark2-httpd.py" >> /tmp/mark2-httpd.log 2>&1 &

# Brief pause to let network settle, then start regardless.
# Chromium shows its own error page if HA is not yet reachable — much
# better than a black screen. The user can refresh once HA is up.
echo "[$(date)] Starting kiosk (HA: ${HA_URL})"
sleep 5

# ── Face overlay ─────────────────────────────────────────────────────────────
# Launch face.html as a transparent always-on-top window.
# labwc window rule keeps it on top; Weston kiosk shell ignores it.
# Uses a separate Chromium profile so it doesn't conflict with the main window.
FACE_HTML="${HOME}/mark2-assist/templates/face.html"
if [ -f "$FACE_HTML" ]; then
    chromium \
        --app="file://${FACE_HTML}" \
        --window-size=800,480 \
        --window-position=0,0 \
        --ozone-platform=wayland \
        --enable-transparent-visuals \
        --enable-features=UseOzonePlatform \
        --user-data-dir="${HOME}/.config/chromium-face" \
        --allow-file-access-from-files \
        --remote-debugging-port=9223 \
        --password-store=basic \
        --no-first-run \
        --disable-infobars \
        --disable-background-timer-throttling \
        --noerrdialogs \
        >> /tmp/mark2-face.log 2>&1 &
    echo "[$(date)] Face overlay started"
fi

# ── Main HA kiosk window ──────────────────────────────────────────────────────
echo "[$(date)] Launching Chromium kiosk → ${HA_URL}"
exec chromium \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --no-first-run \
    --disable-session-crashed-bubble \
    --disable-component-update \
    --password-store=basic \
    --ozone-platform=wayland \
    --enable-features=UseOzonePlatform \
    --autoplay-policy=no-user-gesture-required \
    --disable-background-timer-throttling \
    --no-sandbox \
    --remote-debugging-port=9222 \
    --remote-allow-origins=* \
    --bwsi \
    --disable-features=TranslateUI,Translate \
    --app="${HA_URL}" \
    --user-data-dir="${HOME}/.config/chromium-kiosk"
