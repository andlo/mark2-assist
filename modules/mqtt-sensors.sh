#!/bin/bash
# =============================================================================
# modules/mqtt-sensors.sh
# Publish Mark II status as sensors to Home Assistant via MQTT
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

if ! confirm_or_skip "Install MQTT sensor bridge?"; then
    log "Skipping MQTT sensors"
    exit 0
fi

config_load

# MQTT host — reuse saved or ask
MQTT_HOST="${MQTT_HOST:-}"
if [ -z "$MQTT_HOST" ]; then
    MQTT_HOST=$(ask_input "MQTT broker host/IP" "192.168.1.100") \
        || die "MQTT host required"
    [ -z "$MQTT_HOST" ] && die "MQTT host required"
    config_save "MQTT_HOST" "$MQTT_HOST"
else
    log "Using saved MQTT host: ${MQTT_HOST}"
fi

# MQTT port — reuse saved or use default 1883, never ask again if already set
MQTT_PORT="${MQTT_PORT:-1883}"
config_save "MQTT_PORT" "$MQTT_PORT"
log "MQTT port: ${MQTT_PORT}"

# MQTT credentials — reuse saved or ask once
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
if [ -z "$MQTT_USER" ]; then
    if ask_yes_no "Does your MQTT broker require authentication?"; then
        MQTT_USER=$(ask_input "MQTT username" "") || true
        MQTT_PASS=$(ask_password "MQTT password") || true
        config_save "MQTT_USER" "$MQTT_USER"
        config_save "MQTT_PASS" "$MQTT_PASS"
    fi
else
    log "Using saved MQTT credentials for: ${MQTT_USER}"
fi

# Install paho-mqtt
info "Installing paho-mqtt and sensor bridge service..."
apt_install python3-pip
pip3 install --quiet paho-mqtt --break-system-packages \
    >> "${MARK2_LOG}" 2>&1
log "paho-mqtt installed"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
sudo install -m 755 "${SCRIPT_DIR}/lib/mqtt-bridge.py" \
    /usr/local/bin/mark2-mqtt-bridge
log "Installed mark2-mqtt-bridge"

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
log "Sensors appear in HA: Settings > Devices > Mark II (${MQTT_HOST})"
log "Topic: mark2/$(hostname)/state"
