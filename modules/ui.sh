#!/bin/bash
# =============================================================================
# modules/ui.sh
# Mark II physical user interface — display, LEDs and buttons
#
# Installs everything that gives the Mark II its look, feel and physical
# interaction model:
#
#   DISPLAY (built into the combined kiosk page):
#     - Animated robot face — reacts to voice events (idle/listen/think/speak)
#     - Volume bar overlay  — appears on hardware button press, auto-hides
#     - Passive clock + weather — shown when idle, fetched from HA
#     - Screen blanks after 5 min idle (Weston --idle-time)
#     - Tap screen → opens HA dashboard
#
#   LED RING (SJ201 NeoPixel WS2812, GPIO12):
#     - Follows LVA satellite state (idle/listen/think/speak/mute)
#     - mark2-leds.service      — GPIO/NeoPixel driver (runs as root)
#     - mark2-led-events.service — bridges face-event JSON → LED socket
#
#   HARDWARE BUTTONS (SJ201 /dev/input/event0):
#     - Vol up / Vol down  — TAS5806 amp + ALSA PCM + HUD overlay
#     - Mute               — hardware mute toggle + HUD indicator
#     - Action button      — wake LVA (idle) or stop speech/music (busy)
#     - mark2-volume-buttons.service
#
# The face animation and overlays are rendered inside combined.html which
# is built and served by mark2-httpd.py — no extra Chromium windows needed.
#
# Can be run standalone: bash modules/ui.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

check_not_root
setup_paths

module_header "Mark II UI" "Display (face+clock+weather), LED ring and hardware buttons"

if ! confirm_or_skip "Install Mark II UI (display, LEDs, buttons)?"; then
    log "Skipping UI"
    exit 0
fi

# ── Dependencies ──────────────────────────────────────────────────────────────
apt_install python3-spidev python3-libgpiod python3-smbus2 i2c-tools socat

# NeoPixel library for GPIO12 WS2812 LED ring
pip3 install --break-system-packages --quiet \
    adafruit-circuitpython-neopixel rpi_ws281x adafruit-blinka 2>/dev/null || true

# ── LED ring ──────────────────────────────────────────────────────────────────
LED_SCRIPT="${MARK2_DIR}/led_control.py"
LED_EVENT_SCRIPT="${MARK2_DIR}/led_event_handler.py"

cp "${SCRIPT_DIR}/lib/led_control.py"       "$LED_SCRIPT"
cp "${SCRIPT_DIR}/lib/led_event_handler.py" "$LED_EVENT_SCRIPT"
chmod +x "$LED_SCRIPT" "$LED_EVENT_SCRIPT"
log "LED scripts installed"

# mark2-leds runs as root (NeoPixel needs GPIO access)
sudo tee /etc/systemd/system/mark2-leds.service > /dev/null << SVCEOF
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
Environment=BLINKA_FORCEBOARD=RASPBERRY_PI_4B
TimeoutStopSec=15
KillMode=process

[Install]
WantedBy=multi-user.target
SVCEOF

# mark2-led-events runs as pi user
cat > "${SYSTEMD_USER_DIR}/mark2-led-events.service" << SVCEOF
[Unit]
Description=Mark II LED Event Bridge (polls face-event JSON → LED socket)
After=lva.service mark2-face-events.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${LED_EVENT_SCRIPT}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SVCEOF

sudo systemctl daemon-reload  2>/dev/null
sudo systemctl enable mark2-leds.service 2>/dev/null
systemctl --user daemon-reload 2>/dev/null
systemctl --user enable mark2-led-events.service 2>/dev/null
log "LED ring services installed and enabled"

# ── Hardware buttons ──────────────────────────────────────────────────────────
VOL_SCRIPT="/usr/local/bin/mark2-volume-buttons"
sudo cp "${SCRIPT_DIR}/lib/volume-buttons.py" "$VOL_SCRIPT"
sudo chmod +x "$VOL_SCRIPT"
log "Volume/action button script installed: $VOL_SCRIPT"

cat > "${SYSTEMD_USER_DIR}/mark2-volume-buttons.service" << SVCEOF
[Unit]
Description=Mark II hardware buttons (vol up/down/mute/action → TAS5806 + HUD + LVA)
After=sj201.service lva.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${VOL_SCRIPT}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SVCEOF

systemctl --user daemon-reload 2>/dev/null
systemctl --user enable mark2-volume-buttons.service 2>/dev/null
log "Hardware button service installed and enabled"

# ── Volume monitor (compat — overlay is built into combined.html) ─────────────
VOLUME_MONITOR="${MARK2_DIR}/volume-monitor.sh"
cat > "$VOLUME_MONITOR" << 'SHEOF'
#!/bin/bash
# Minimal volume monitor — keeps mark2-volume.json fresh.
# The HUD overlay is built into combined.html and reads overlay-event.json
# which is written directly by mark2-volume-buttons on every button press.
while true; do sleep 60; done
SHEOF
chmod +x "$VOLUME_MONITOR"

cat > "${SYSTEMD_USER_DIR}/mark2-volume-monitor.service" << SVCEOF
[Unit]
Description=Mark II volume monitor (overlay built into HUD)
After=pipewire.service

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

# ── Summary ───────────────────────────────────────────────────────────────────
log "Mark II UI installed"
echo ""
info "Display   — face animation, clock+weather and volume overlay are built"
info "            into the kiosk page (combined.html, served by mark2-httpd)"
info "LED ring  — test: echo 'listen' | socat - UNIX-CONNECT:/tmp/mark2-leds.sock"
info "Buttons   — vol up/down, mute, action (wake/stop)"
info ""
info "The display modules (face.sh, overlay.sh, screensaver.sh) are superseded"
info "by this module — do not install them alongside ui.sh."
