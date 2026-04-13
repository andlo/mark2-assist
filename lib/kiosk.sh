#!/bin/bash
exec >> /tmp/mark2-kiosk.log 2>&1
echo "[$(date)] kiosk.sh starting"

export XDG_RUNTIME_DIR=/run/user/$(id -u)

CONFIG="${HOME}/.config/mark2/config"
HA_URL=""
[ -f "$CONFIG" ] && source "$CONFIG"

# Detect which Wayland socket Weston is using.
# Weston picks the first free socket (wayland-0, wayland-1, ...).
# Other services (pipewire, xdg-desktop-portal) may claim wayland-0 first.
# Wait up to 30s for any wayland-N socket to appear, prefer the one Weston set.
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

# Remove stale Chromium singleton lock (left by unclean shutdown)
rm -f "${HOME}/.config/chromium-kiosk/Singleton"*

# Decide what to show:
# - If HA kiosk is enabled (modules/homeassistant.sh was run): open HA dashboard
# - Otherwise: open local HUD page (face + clock only, no HA)
if [ -f "${HOME}/.config/mark2/ha-kiosk-enabled" ] && [ -n "$HA_URL" ]; then
    # Wait for HA to respond (401 Unauthorized is fine — means HA is running)
    until curl -o /dev/null -sf --max-time 3 -w "%{http_code}" "${HA_URL}" \
        2>/dev/null | grep -qE '200|401|302'; do
        sleep 3
    done
    sleep 3
    START_URL="${HA_URL}"
    echo "[$(date)] HA ready, opening dashboard: ${START_URL}"
else
    # No HA dashboard — open local HUD page (face animation + clock)
    START_URL="file://${HOME}/.config/mark2-kiosk/hud.html"
    echo "[$(date)] HA kiosk not enabled, opening local HUD"
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
    --user-data-dir="${HOME}/.config/chromium-kiosk" \
    "${START_URL}"
