#!/bin/bash
# =============================================================================
# modules/face.sh
# Animated face display - reacts to Wyoming satellite events
#
# Shows an animated robot face on the Mark II touchscreen:
#   idle   - half-closed sleepy eyes, fades out after 3s
#   wake   - eyes pop open with "!" flash
#   listen - big open eyes, pupils wander, natural blinking
#   think  - squinting eyes, animated "..." dots
#   speak  - open eyes, animated mouth, blush
#   error  - worried brows, sad mouth
#
# Can be run standalone: bash modules/face.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "Animated Face Display" "Animated robot face reacting to voice events and music"

if ! confirm_or_skip "Install animated face?"; then
    log "Skipping face"
    exit 0
fi

TEMPLATE_DIR="$(dirname "$0")/../templates"
FACE_DIR="${USER_HOME}/.config/mark2-face"
mkdir -p "$FACE_DIR"

cp "${TEMPLATE_DIR}/face.html" "${FACE_DIR}/face.html"
log "Copied face template to ${FACE_DIR}/face.html"

# Event bridge: listens on LED socket and writes to face event file
FACE_BRIDGE="${MARK2_DIR}/face-bridge.sh"
cat > "$FACE_BRIDGE" << 'SHEOF'
#!/bin/bash
# Bridge Wyoming LED states to face events
# Reads from mark2-leds.sock and writes /tmp/mark2-face-event.json
SOCKET_PATH="/tmp/mark2-leds.sock"
while true; do
    if [ -S "$SOCKET_PATH" ]; then
        STATE=$(echo "" | socat -T1 - UNIX-CONNECT:"$SOCKET_PATH" 2>/dev/null | head -1 || true)
        [ -n "$STATE" ] && echo "{\"state\":\"${STATE}\"}" > /tmp/mark2-face-event.json
    fi
    sleep 0.15
done
SHEOF
chmod +x "$FACE_BRIDGE"

# Also write face events directly from the LED event handler
# by patching mark2-leds.sock - face polls /tmp/mark2-face-event.json
# We install a lightweight socat listener that mirrors states

# Systemd service for face bridge
cat > "${SYSTEMD_USER_DIR}/mark2-face-bridge.service" << EOF
[Unit]
Description=Mark II Face Event Bridge
After=mark2-leds.service
Wants=mark2-leds.service

[Service]
Type=simple
ExecStart=${FACE_BRIDGE}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Add face window to labwc autostart
# Positioned bottom-right, small enough not to cover HA dashboard
labwc_autostart_add "face.html" \
    "chromium --app=\"file://${FACE_DIR}/face.html\" --window-size=260,260 --window-position=760,220 --ozone-platform=wayland --password-store=basic --no-first-run --disable-infobars --disable-background-timer-throttling --app-auto-launched &"

systemctl --user daemon-reload
systemctl --user enable mark2-face-bridge.service

log "Animated face installed"
info "Face appears bottom-right of screen, reacts to Wyoming events"
info "Requires LED module (modules/leds.sh) for event bridging"
info "Preview: file://${FACE_DIR}/face.html"
