#!/bin/bash
# =============================================================================
# modules/overlay.sh
# Transparent volume/status overlay (Chromium app window)
#
# Can be run standalone: bash modules/overlay.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

section "Volume / Status Overlay"
echo "  Transparent on-screen overlay showing volume and Wyoming status."
echo "  Auto-hides after 3 seconds."
echo ""

if ! confirm_or_skip "Install volume/status overlay?"; then
    log "Skipping volume overlay"
    exit 0
fi

OVERLAY_DIR="${USER_HOME}/.config/mark2-overlay"
mkdir -p "$OVERLAY_DIR"

TEMPLATE_DIR="$(dirname "$0")/../templates"
cp "${TEMPLATE_DIR}/overlay.html" "${OVERLAY_DIR}/overlay.html"
log "Copied overlay template to ${OVERLAY_DIR}/overlay.html"

# mark2-overlay command
OVERLAY_TRIGGER="${USER_HOME}/.local/bin/mark2-overlay"
mkdir -p "$(dirname "$OVERLAY_TRIGGER")"
cat > "$OVERLAY_TRIGGER" << 'SHEOF'
#!/bin/bash
# Usage: mark2-overlay volume 75 | status "Listening..." | clear
echo "{\"type\":\"${1:-status}\",\"value\":\"${2:-}\"}" > /tmp/mark2-overlay-event.json
SHEOF
chmod +x "$OVERLAY_TRIGGER"

# Volume monitor service
VOLUME_MONITOR="${MARK2_DIR}/volume-monitor.sh"
cat > "$VOLUME_MONITOR" << 'SHEOF'
#!/bin/bash
LAST_VOL=""
while true; do
    SINK=$(pactl get-default-sink 2>/dev/null)
    VOL=$(pactl get-sink-volume "$SINK" 2>/dev/null | grep -oP '\d+(?=%)' | head -1)
    if [ -n "$VOL" ] && [ "$VOL" != "$LAST_VOL" ]; then
        mark2-overlay volume "$VOL" 2>/dev/null || true
        LAST_VOL="$VOL"
    fi
    sleep 1
done
SHEOF
chmod +x "$VOLUME_MONITOR"

cat > "${SYSTEMD_USER_DIR}/mark2-volume-monitor.service" << EOF
[Unit]
Description=Mark II Volume Monitor
After=pipewire.service
Wants=pipewire.service

[Service]
Type=simple
ExecStart=${VOLUME_MONITOR}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Add overlay window to labwc autostart
labwc_autostart_add "overlay.html" \
    "chromium --app=\"file://${OVERLAY_DIR}/overlay.html\" --window-size=400,120 --window-position=0,360 --ozone-platform=wayland --password-store=basic --no-first-run --disable-infobars --app-auto-launched &"

systemctl --user daemon-reload
systemctl --user enable mark2-volume-monitor.service

log "Volume overlay installed"
info "Trigger: mark2-overlay volume 75 | mark2-overlay status 'Listening...'"
