#!/bin/bash
# =============================================================================
# modules/overlay.sh
# Transparent volume/status overlay for the Mark II touchscreen
#
# Displays a semi-transparent volume bar in the lower portion of the screen
# that appears when the volume changes and auto-hides after 3 seconds.
#
# Architecture:
#   mark2-volume-monitor.service
#     → polls PipeWire default sink volume every second via pactl
#     → on change, writes /tmp/mark2-overlay-event.json
#     → triggers the overlay window to show and start its hide timer
#
#   Overlay window: Chromium --app window displaying overlay.html
#     → reads /tmp/mark2-overlay-event.json
#     → animates volume bar
#     → auto-hides after 3 seconds of no new events
#
# The mark2-overlay command (~/.local/bin/mark2-overlay) can also be called
# manually from scripts or HA automations:
#   mark2-overlay volume 75        — show volume at 75%
#   mark2-overlay status "Busy"    — show a status message
#
# The overlay window is launched via labwc autostart as a Chromium --app window.
# labwc is installed alongside Weston for this purpose.
#
# Window: 400×120 px, bottom-center of 800×480 display (position 200,360)
#
# Can be run standalone: bash modules/overlay.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "Volume Overlay" "On-screen volume indicator, auto-hides after 3 seconds"

if ! confirm_or_skip "Install volume/status overlay?"; then
    log "Skipping volume overlay"
    exit 0
fi

OVERLAY_DIR="${USER_HOME}/.config/mark2-overlay"
mkdir -p "$OVERLAY_DIR"

TEMPLATE_DIR="$(dirname "$0")/../templates"
cp "${TEMPLATE_DIR}/overlay.html" "${OVERLAY_DIR}/overlay.html"
log "Copied overlay template to ${OVERLAY_DIR}/overlay.html"

# mark2-overlay — CLI trigger for the overlay (also used by volume monitor)
OVERLAY_TRIGGER="${USER_HOME}/.local/bin/mark2-overlay"
mkdir -p "$(dirname "$OVERLAY_TRIGGER")"
cat > "$OVERLAY_TRIGGER" << 'SHEOF'
#!/bin/bash
# Trigger the Mark II overlay window.
# Usage: mark2-overlay volume 75
#        mark2-overlay status "Listening..."
#        mark2-overlay clear
# Writes /tmp/mark2-overlay-event.json which overlay.html polls.
echo "{\"type\":\"${1:-status}\",\"value\":\"${2:-}\"}" > /tmp/mark2-overlay-event.json
SHEOF
chmod +x "$OVERLAY_TRIGGER"

# Volume monitor — watches PipeWire default sink volume and triggers overlay
VOLUME_MONITOR="${MARK2_DIR}/volume-monitor.sh"
cat > "$VOLUME_MONITOR" << 'SHEOF'
#!/bin/bash
# Polls PipeWire default sink volume every second.
# On change, writes overlay event so the overlay window shows the new volume.
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
Description=Mark II volume monitor (triggers overlay on volume change)
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

# Add overlay window to labwc autostart.
# Positioned bottom-center of 800×480 display.
labwc_autostart_add "overlay.html" \
    "chromium --app=\"file://${OVERLAY_DIR}/overlay.html\" --window-size=400,120 --window-position=200,360 --ozone-platform=wayland --password-store=basic --no-first-run --disable-infobars --app-auto-launched &"

systemctl --user daemon-reload 2>/dev/null
systemctl --user enable mark2-volume-monitor.service 2>/dev/null

log "Volume overlay installed"
info "Trigger manually: mark2-overlay volume 75"
info "Or from HA automation: ssh pi@<ip> mark2-overlay status 'Listening...'"
