#!/bin/bash
exec >> /tmp/mark2-kiosk.log 2>&1
echo "[$(date)] kiosk.sh starting"

export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR=/run/user/$(id -u)

CONFIG="${HOME}/.config/mark2/config"
HA_URL=""
[ -f "$CONFIG" ] && source "$CONFIG"

# Wait for Wayland socket
for i in $(seq 1 30); do
    [ -S "/run/user/$(id -u)/wayland-0" ] && break
    sleep 1
done
echo "[$(date)] Wayland ready"

# Remove stale singleton
rm -f "${HOME}/.config/chromium-kiosk/Singleton"*

# Wait for HA
until curl -sf --max-time 3 "${HA_URL}" > /dev/null 2>&1; do
    sleep 3
done
echo "[$(date)] HA ready, starting Chromium at ${HA_URL}"

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
    --disable-dev-shm-usage \
    --no-sandbox \
    --user-data-dir="${HOME}/.config/chromium-kiosk" \
    "${HA_URL}"
