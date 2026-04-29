#!/bin/bash
# =============================================================================
# lib/kiosk.sh — main kiosk launcher for the Mark II touchscreen
#
# Called by ~/startup.sh which is launched by Weston (kiosk shell).
# Builds combined.html (HA iframe + HUD overlay), starts mark2-httpd.py,
# waits for HA to be reachable, then launches Chromium in kiosk mode.
#
# Audio output device: pipewire/sj201-output (via PipeWire — NOT alsa directly)
# Remote debugging: port 9222 (allows CDP reload and inspection)
# =============================================================================
exec >> /tmp/mark2-kiosk.log 2>&1
echo "[$(date)] kiosk.sh starting"

export XDG_RUNTIME_DIR=/run/user/$(id -u)

CONFIG="${HOME}/.config/mark2/config"
HA_URL=""
HA_TOKEN=""
HA_WEATHER_ENTITY=""
HA_KIOSK_TIMEOUT="60"
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
echo "[$(date)] Wayland ready: WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset}"

# Remove stale Chromium singleton lock
rm -f "${HOME}/.config/chromium-kiosk/Singleton"*
# Clear session restore files so Chromium always opens our URL
rm -f "${HOME}/.config/chromium-kiosk/Default/Last Session"
rm -f "${HOME}/.config/chromium-kiosk/Default/Last Tabs"
rm -f "${HOME}/.config/chromium-kiosk/Default/Current Session"
rm -f "${HOME}/.config/chromium-kiosk/Default/Current Tabs"

# Pre-seed Chromium profile to avoid white flash on first run:
# - First Run sentinel suppresses first-run overlay
# - Preferences sets dark background colour
mkdir -p "${HOME}/.config/chromium-kiosk/Default"
touch "${HOME}/.config/chromium-kiosk/First Run"
# Write minimal Preferences if not already present
PREFS="${HOME}/.config/chromium-kiosk/Default/Preferences"
if [ ! -f "$PREFS" ] || ! grep -q "theme" "$PREFS" 2>/dev/null; then
    echo '{"browser":{"theme":{"color_scheme":2}},"profile":{"content_settings":{}}}' > "$PREFS"
fi

KIOSK_DIR="${HOME}/.config/mark2-kiosk"
COMBINED="${KIOSK_DIR}/combined.html"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MARK2_DIR="${HOME}/mark2-assist"
BUILD_SCRIPT="${MARK2_DIR}/lib/build-combined.py"

if [ -n "$HA_URL" ] && [ -f "${MARK2_DIR}/templates/kiosk.html" ] && [ -f "$BUILD_SCRIPT" ]; then
    python3 "$BUILD_SCRIPT" "${MARK2_DIR}/templates/kiosk.html" "$HA_URL" "$COMBINED" "$HA_TOKEN" "$HA_WEATHER_ENTITY" "$HA_KIOSK_TIMEOUT"
    echo "[$(date)] Combined HA+HUD page ready"

    # Serve combined.html via local HTTP to avoid file://->http:// mixed content block.
    # Install splash screen (substitute hostname placeholder)
    sed "s/%%HOSTNAME%%/$(hostname -s)/" \
        "${MARK2_DIR}/templates/splash.html" > "${KIOSK_DIR}/splash.html"

    # Kill any previous server on port 8088.
    pkill -f 'mark2-httpd.py' 2>/dev/null || true
    sleep 0.5
    python3 "${HOME}/mark2-httpd.py" >> /tmp/mark2-httpd.log 2>&1 &
    echo "[$(date)] Local HTTP server started on :8088"

    # Show splash immediately — polls combined.html and auto-navigates when HA is up
    START_URL="http://localhost:8088/splash.html?next=http://localhost:8088/combined.html&ha=http://localhost:8088/ha/"

    # Wait for HA in background so combined.html is ready when splash finishes
    ( until curl -o /dev/null -sf --max-time 3 "${HA_URL}" 2>/dev/null; do
          sleep 3
      done
      echo "[$(date)] HA ready"
    ) &
elif [ -n "$HA_URL" ]; then
    until curl -o /dev/null -sf --max-time 3 "${HA_URL}" 2>/dev/null; do
        sleep 3
    done
    echo "[$(date)] HA ready: ${HA_URL}"
    START_URL="${HA_URL}"
else
    START_URL="file://${KIOSK_DIR}/hud.html"
    echo "[$(date)] No HA URL, opening local HUD"
fi

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
    --disable-web-security \
    --allow-file-access-from-files \
    --remote-debugging-port=9222 \
    --remote-allow-origins=* \
    --bwsi \
    --disable-features=TranslateUI,Translate \
    --app="${START_URL}" \
    --user-data-dir="${HOME}/.config/chromium-kiosk"
