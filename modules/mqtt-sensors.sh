#!/bin/bash
# =============================================================================
# modules/mqtt-sensors.sh
# Publish Mark II status as sensors to Home Assistant via MQTT
#
# Uses HA MQTT auto-discovery - sensors appear automatically in HA.
#
# Sensors:
#   - Wyoming state (idle/listening/speaking/thinking)
#   - MPD state + track + artist + volume
#   - CPU temperature, CPU usage, memory usage, disk usage
#
# Can be run standalone: bash modules/mqtt-sensors.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

section "MQTT Sensor Bridge"
echo "  Publishes Mark II status as sensors to Home Assistant via MQTT."
echo "  Uses HA MQTT auto-discovery — sensors appear automatically in HA."
echo ""
echo "  Sensors: Wyoming state, MPD track/state/volume,"
echo "           CPU temp, CPU/memory/disk usage."
echo ""
echo "  Requires: Mosquitto (or other MQTT broker) reachable from Mark II."
echo ""

if ! confirm_or_skip "Install MQTT sensor bridge?"; then
    log "Skipping MQTT sensors"
    exit 0
fi

# Load saved config
config_load

# MQTT host
MQTT_HOST="${MQTT_HOST:-}"
if [ -z "$MQTT_HOST" ]; then
    MQTT_HOST=$(ask_input "MQTT broker host/IP" "192.168.1.100") \
        || die "MQTT host required"
    [ -z "$MQTT_HOST" ] && die "MQTT host required"
    config_save "MQTT_HOST" "$MQTT_HOST"
else
    log "Using saved MQTT host: ${MQTT_HOST}"
fi

MQTT_PORT="${MQTT_PORT:-1883}"
_PORT=$(ask_input "MQTT port" "$MQTT_PORT") && MQTT_PORT="${_PORT:-1883}"
config_save "MQTT_PORT" "$MQTT_PORT"

MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
if ask_yes_no "Does your MQTT broker require authentication?"; then
    MQTT_USER=$(ask_input "MQTT username" "$MQTT_USER") || true
    MQTT_PASS=$(ask_password "MQTT password") || true
    config_save "MQTT_USER" "$MQTT_USER"
    config_save "MQTT_PASS" "$MQTT_PASS"
fi

# Install paho-mqtt
section "Installing paho-mqtt"
apt_install python3-pip
pip3 install --quiet paho-mqtt --break-system-packages \
    >> "${MARK2_LOG}" 2>&1
log "paho-mqtt installed"

# Install bridge script
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
sudo install -m 755 "${SCRIPT_DIR}/lib/mqtt-bridge.py" \
    /usr/local/bin/mark2-mqtt-bridge
log "Installed mark2-mqtt-bridge"

# Systemd user service
cat > "${SYSTEMD_USER_DIR}/mark2-mqtt-bridge.service" << EOF
[Unit]
Description=Mark II MQTT sensor bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mark2-mqtt-bridge
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable mark2-mqtt-bridge.service
systemctl --user start  mark2-mqtt-bridge.service

log "MQTT bridge installed and started"
info "Sensors will appear in HA under: Settings > Devices > Mark II (${MQTT_HOST})"
info "Topic: mark2/$(hostname)/state"
info "Logs:  journalctl --user -u mark2-mqtt-bridge -f"
