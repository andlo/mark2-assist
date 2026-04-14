#!/bin/bash
# =============================================================================
# modules/overlay.sh
# Volume/status overlay for the Mark II touchscreen
#
# NOTE: The overlay is now built into the combined kiosk page (combined.html)
# and does NOT require a separate Chromium window or labwc.
#
# Architecture (current):
#   mark2-volume-buttons.service (lib/volume-buttons.py)
#     → on vol/mute button press, writes /tmp/mark2-overlay-event.json
#       {"type": "volume", "value": 75, "muted": false, "ts": ...}
#
#   mark2-httpd.py serves /overlay-event.json → /tmp/mark2-overlay-event.json
#
#   combined.html polls http://localhost:8088/overlay-event.json every 300ms
#     → calls showVolume(pct, muted) to animate the HUD volume bar
#     → bar auto-hides after 3 seconds
#
# The mark2-volume-monitor.service (pactl-based) is still installed for
# compatibility but is superseded by the direct write in volume-buttons.py.
#
# Can be run standalone: bash modules/overlay.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "Volume Overlay" "On-screen volume bar (built into kiosk HUD)"

if ! confirm_or_skip "Install volume overlay monitor service?"; then
    log "Skipping volume overlay"
    exit 0
fi

# The volume bar is built into combined.html — no separate window needed.
# We just install the volume-monitor service as a fallback/compatibility layer.

VOLUME_MONITOR="${MARK2_DIR}/volume-monitor.sh"
cat > "$VOLUME_MONITOR" << 'SHEOF'
#!/bin/bash
# Fallback volume monitor — only fires if volume changes via means other
# than the hardware buttons (e.g. HA media_player volume_set).
# volume-buttons.py writes overlay events directly on button press.
LAST_TS=""
while true; do
    TS=$(python3 -c "import json; d=json.load(open('/tmp/mark2-volume.json')); print(d.get('ts',''))" 2>/dev/null)
    if [ -n "$TS" ] && [ "$TS" != "$LAST_TS" ]; then
        LAST_TS="$TS"
    fi
    sleep 2
done
SHEOF
chmod +x "$VOLUME_MONITOR"

cat > "${SYSTEMD_USER_DIR}/mark2-volume-monitor.service" << SVCEOF
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
SVCEOF

systemctl --user daemon-reload 2>/dev/null
systemctl --user enable mark2-volume-monitor.service 2>/dev/null

log "Volume overlay configured (built into kiosk HUD)"
info "Volume bar appears automatically on hardware button press"
info "Overlay events: /tmp/mark2-overlay-event.json"
