#!/bin/bash
exec >> /tmp/mark2-kiosk.log 2>&1
echo "[$(date)] kiosk.sh starting"

export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR=/run/user/$(id -u)

CONFIG="${HOME}/.config/mark2/config"
HA_URL=""; HA_TOKEN=""
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
echo "[$(date)] HA ready"

# Generate auto-login page that injects token into HA's localStorage
AUTOLOGIN="${HOME}/.config/chromium-kiosk/autologin.html"
mkdir -p "${HOME}/.config/chromium-kiosk"
cat > "$AUTOLOGIN" << HTMLEOF
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Connecting...</title>
<script>
var token = "${HA_TOKEN}";
var haUrl = "${HA_URL}";
if (token) {
  var auth = {
    hassUrl: haUrl,
    clientId: haUrl + "/",
    expires: Math.floor(Date.now()/1000) + 86400*365,
    refresh_token: "",
    access_token: token,
    token_type: "Bearer",
    expires_in: 86400*365
  };
  localStorage.setItem("hassTokens", JSON.stringify(auth));
}
window.location.replace(haUrl);
</script>
</head><body style="background:#1c1c1c"></body></html>
HTMLEOF

echo "[$(date)] Starting Chromium"

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
    "file://${AUTOLOGIN}"
