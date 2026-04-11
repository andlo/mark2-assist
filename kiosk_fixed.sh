#!/bin/bash
exec >> /tmp/mark2-kiosk.log 2>&1
echo "[$(date)] kiosk.sh starting"

export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR=/run/user/$(id -u)

CONFIG="${HOME}/.config/mark2/config"
HA_URL=""; HA_TOKEN=""
[ -f "$CONFIG" ] && source "$CONFIG"

echo "[$(date)] Waiting for Wayland display..."
for i in $(seq 1 30); do
    [ -S "/run/user/$(id -u)/wayland-0" ] && break
    sleep 1
done

echo "[$(date)] Waiting for Home Assistant at ${HA_URL}..."
until curl -sf --max-time 3 "${HA_URL}" > /dev/null 2>&1; do
    sleep 5
done
echo "[$(date)] Home Assistant is up, starting Chromium"

if [ -n "${HA_TOKEN}" ]; then
    START_URL="${HA_URL}?auth_callback=1&code=${HA_TOKEN}&state=/"
else
    START_URL="${HA_URL}"
fi

exec chromium \
    --kiosk --noerrdialogs --disable-infobars --no-first-run \
    --disable-session-crashed-bubble --disable-component-update \
    --password-store=basic --ozone-platform=wayland \
    --enable-features=UseOzonePlatform \
    --autoplay-policy=no-user-gesture-required \
    --disable-background-timer-throttling \
    --user-data-dir="${HOME}/.config/chromium-kiosk" \
    "${START_URL}"
