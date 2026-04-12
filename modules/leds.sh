#!/bin/bash
# =============================================================================
# modules/leds.sh
# SJ201 LED ring control for LVA/HA voice satellite events
#
# Can be run standalone: bash modules/leds.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "LED Ring Control" "SJ201 LED ring follows LVA satellite state"


if ! confirm_or_skip "Install LED ring control?"; then
    log "Skipping LED control"
    exit 0
fi

apt_install python3-spidev python3-libgpiod python3-smbus2 i2c-tools socat

# Install NeoPixel library (required for GPIO12 WS2812 LED ring)
pip3 install --break-system-packages --quiet adafruit-circuitpython-neopixel rpi_ws281x adafruit-blinka 2>/dev/null || true

LED_SCRIPT="${MARK2_DIR}/led_control.py"
LED_EVENT_SCRIPT="${MARK2_DIR}/led_event_handler.py"

# --- LED controller (NeoPixel WS2812 on GPIO12) ---
cp "${SCRIPT_DIR}/lib/led_control.py" "$LED_SCRIPT"
chmod +x "$LED_SCRIPT"

# --- LVA event bridge ---
cp "${SCRIPT_DIR}/lib/led_event_handler.py" "$LED_EVENT_SCRIPT"
chmod +x "$LED_EVENT_SCRIPT"

# --- Systemd services ---
# mark2-leds runs as a SYSTEM service (not user) because NeoPixel needs root/GPIO
sudo tee /etc/systemd/system/mark2-leds.service > /dev/null << EOF
[Unit]
Description=Mark II LED Ring Controller (NeoPixel GPIO12)
After=sj201.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u ${LED_SCRIPT}
Restart=on-failure
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal
# BLINKA_FORCEBOARD avoids NeoPixel DMA hangs under systemd
Environment=BLINKA_FORCEBOARD=RASPBERRY_PI_4B
# Give NeoPixel DMA time to shut down cleanly on stop
TimeoutStopSec=15
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

cat > "${SYSTEMD_USER_DIR}/mark2-led-events.service" << EOF
[Unit]
Description=Mark II LED Event Bridge (polls face-event JSON → LED socket)
After=lva.service mark2-face-events.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${LED_EVENT_SCRIPT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Note: Wyoming --event-uri patching is no longer needed with LVA.
# LVA state is read via HA API by face-event-bridge.
# This block kept for reference only.
# We add --event-uri on a new line AFTER --wake-word-name line.
# Uses Python for reliable multi-line sed replacement to avoid
# shell escaping issues that cause double backslash (\ \) corruption.
# Note: Wyoming --event-uri patching is no longer needed with LVA.
# LVA state is read via HA API by mark2-face-events.service.

# Enable system service (mark2-leds needs root for GPIO)
sudo systemctl daemon-reload 2>/dev/null
sudo systemctl enable mark2-leds.service 2>/dev/null
# Enable user service (mark2-led-events runs as pi)
systemctl --user daemon-reload 2>/dev/null
systemctl --user enable mark2-led-events.service 2>/dev/null

log "LED ring control installed"
info "Test: echo 'listen' | socat - UNIX-CONNECT:/tmp/mark2-leds.sock"
info "States: idle, wake, listen, think, speak, error, mute, volume"
