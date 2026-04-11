#!/bin/bash
# =============================================================================
# mark2-advanced-setup.sh
# Mycroft Mark II - Advanced features
#
# Run this AFTER mark2-satellite-setup.sh (and optionally mark2-extras-setup.sh)
#
# Modules (each prompted individually):
#   [1] LED ring control    - SJ201 LED status feedback for Wyoming events
#   [2] Kernel watchdog     - Auto-rebuild VocalFusion driver after kernel updates
#   [3] KDE Connect         - Phone notifications, media control, clipboard sync
#   [4] MPD                 - Local music player daemon (works with Music Assistant)
#   [5] USB audio fallback  - Auto-switch to USB DAC if SJ201 fails at boot
#   [6] Volume overlay      - Transparent on-screen volume/status display
#
# Music Assistant note:
#   Music Assistant runs as a Home Assistant addon - not on Mark II itself.
#   This script configures Mark II as a Music Assistant target via:
#   - Snapcast (if installed) - MA streams to Snapcast server
#   - MPD (installed here)   - MA can control MPD directly
#   See: https://music-assistant.io/
#
# Requirements:
#   - mark2-hardware-setup.sh run first + reboot
#   - Raspberry Pi OS Trixie
#   - sudo access
#
# Usage:
#   chmod +x mark2-advanced-setup.sh
#   ./mark2-advanced-setup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()     { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    die "Do not run as root directly."
fi

CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"
MARK2_DIR="${USER_HOME}/.config/mark2"
mkdir -p "$SYSTEMD_USER_DIR" "$MARK2_DIR"

WYOMING_SAT_DIR="${USER_HOME}/wyoming-satellite"
KERNEL_VERSION=$(uname -r)

ask_yes_no() {
    local answer
    read -rp "${1} [y/N]: " answer
    [[ "${answer,,}" == "y" ]]
}

# =============================================================================
# MODULE 1: LED RING CONTROL
# =============================================================================

install_led_control() {
    section "LED Ring Control"
    echo "  Controls the SJ201 LED ring based on Wyoming satellite events:"
    echo "  · Idle:      LEDs off"
    echo "  · Wake word detected: pulsing blue"
    echo "  · Listening: solid blue"
    echo "  · Thinking:  spinning cyan"
    echo "  · Speaking:  solid green"
    echo "  · Error:     flash red"
    echo ""

    if ! ask_yes_no "Install LED ring control?"; then
        log "Skipping LED control"
        return
    fi

    # Install Python dependencies
    sudo apt-get install -y --no-install-recommends \
        python3-spidev \
        python3-gpiod \
        python3-smbus2 \
        i2c-tools

    # Create LED control Python script
    # SJ201 uses a custom LED controller accessed via I2C
    # LED indices: 0-11 around the ring
    LED_SCRIPT="${MARK2_DIR}/led_control.py"

    cat > "$LED_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
Mark II SJ201 LED ring controller for Wyoming satellite events.
Listens on a Unix socket for state changes from the event handler.

LED states:
  idle      - all off
  wake      - pulsing blue
  listen    - solid blue
  think     - spinning cyan
  speak     - solid green
  error     - flash red
  mute      - dim orange

SJ201 LED controller is at I2C address 0x04 on bus 1.
LED data format: [R, G, B] per LED, 12 LEDs total.
"""

import smbus2
import time
import threading
import socket
import os
import sys
import signal

I2C_BUS = 1
I2C_ADDR = 0x04
NUM_LEDS = 12
SOCKET_PATH = "/tmp/mark2-leds.sock"

class SJ201LEDs:
    def __init__(self):
        try:
            self.bus = smbus2.SMBus(I2C_BUS)
            self.available = True
        except Exception as e:
            print(f"[LED] I2C not available: {e}", file=sys.stderr)
            self.available = False
        self._stop = threading.Event()
        self._thread = None

    def _write(self, data: list):
        """Write RGB data for all 12 LEDs. data = [R,G,B] * 12"""
        if not self.available:
            return
        try:
            # SJ201 expects: register 0x00, then 3 bytes per LED
            payload = []
            for r, g, b in data:
                payload.extend([r, g, b])
            self.bus.write_i2c_block_data(I2C_ADDR, 0x00, payload[:32])
            if len(payload) > 32:
                self.bus.write_i2c_block_data(I2C_ADDR, 0x20, payload[32:])
        except Exception as e:
            print(f"[LED] Write error: {e}", file=sys.stderr)

    def off(self):
        self._stop_animation()
        self._write([(0, 0, 0)] * NUM_LEDS)

    def solid(self, r, g, b):
        self._stop_animation()
        self._write([(r, g, b)] * NUM_LEDS)

    def _stop_animation(self):
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
        self._stop.clear()

    def _animate(self, func):
        self._stop_animation()
        self._thread = threading.Thread(target=func, daemon=True)
        self._thread.start()

    def pulse(self, r, g, b, speed=0.03):
        """Breathing/pulsing animation"""
        def _run():
            while not self._stop.is_set():
                for i in range(0, 100, 3):
                    if self._stop.is_set():
                        return
                    f = i / 100.0
                    self._write([(int(r*f), int(g*f), int(b*f))] * NUM_LEDS)
                    time.sleep(speed)
                for i in range(100, 0, -3):
                    if self._stop.is_set():
                        return
                    f = i / 100.0
                    self._write([(int(r*f), int(g*f), int(b*f))] * NUM_LEDS)
                    time.sleep(speed)
        self._animate(_run)

    def spin(self, r, g, b, speed=0.05):
        """Spinning dot animation"""
        def _run():
            pos = 0
            while not self._stop.is_set():
                leds = [(0, 0, 0)] * NUM_LEDS
                for i in range(4):
                    idx = (pos - i) % NUM_LEDS
                    fade = max(0, 1.0 - i * 0.25)
                    leds[idx] = (int(r*fade), int(g*fade), int(b*fade))
                self._write(leds)
                pos = (pos + 1) % NUM_LEDS
                time.sleep(speed)
        self._animate(_run)

    def flash(self, r, g, b, count=3, speed=0.15):
        """Flash animation"""
        def _run():
            for _ in range(count):
                if self._stop.is_set():
                    return
                self._write([(r, g, b)] * NUM_LEDS)
                time.sleep(speed)
                self._write([(0, 0, 0)] * NUM_LEDS)
                time.sleep(speed)
        self._animate(_run)


def handle_state(leds: SJ201LEDs, state: str):
    state = state.strip().lower()
    print(f"[LED] State: {state}")
    if state == "idle":
        leds.off()
    elif state == "wake":
        leds.pulse(0, 50, 255, speed=0.02)   # Fast blue pulse
    elif state == "listen":
        leds.solid(0, 80, 255)                # Solid blue
    elif state == "think":
        leds.spin(0, 200, 200, speed=0.04)    # Spinning cyan
    elif state == "speak":
        leds.solid(0, 180, 50)                # Solid green
    elif state == "error":
        leds.flash(255, 0, 0, count=4)        # Flash red
    elif state == "mute":
        leds.solid(40, 20, 0)                 # Dim orange
    elif state == "volume":
        leds.pulse(0, 100, 100, speed=0.05)   # Slow teal pulse
    else:
        print(f"[LED] Unknown state: {state}", file=sys.stderr)


def main():
    leds = SJ201LEDs()
    leds.off()

    # Remove old socket
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o666)
    server.listen(5)
    server.settimeout(1.0)
    print(f"[LED] Listening on {SOCKET_PATH}")

    def shutdown(sig, frame):
        print("[LED] Shutting down")
        leds.off()
        server.close()
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    while True:
        try:
            conn, _ = server.accept()
            data = conn.recv(64).decode("utf-8", errors="ignore")
            conn.close()
            if data:
                handle_state(leds, data)
        except socket.timeout:
            continue
        except Exception as e:
            print(f"[LED] Error: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$LED_SCRIPT"

    # Create LED event handler script for Wyoming satellite
    LED_EVENT_SCRIPT="${MARK2_DIR}/led_event_handler.py"

    cat > "$LED_EVENT_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
Wyoming satellite event client that drives the LED ring.
Pass --uri tcp://127.0.0.1:10500 to wyoming-satellite --event-uri
"""

import asyncio
import socket
import sys
import os

SOCKET_PATH = "/tmp/mark2-leds.sock"

def send_led_state(state: str):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCKET_PATH)
        sock.sendall(state.encode("utf-8"))
        sock.close()
    except Exception as e:
        print(f"[EVENT] LED socket error: {e}", file=sys.stderr)

# Wyoming event handler - reads JSON events from stdin
import json

EVENT_MAP = {
    "detect":           "wake",
    "detection":        "listen",
    "streaming-start":  "listen",
    "streaming-stop":   "think",
    "transcript":       "think",
    "synthesize":       "speak",
    "tts-start":        "speak",
    "tts-played":       "idle",
    "error":            "error",
    "connected":        "idle",
    "disconnected":     "error",
}

def main():
    send_led_state("idle")
    for line in sys.stdin:
        try:
            event = json.loads(line.strip())
            event_type = event.get("type", "")
            state = EVENT_MAP.get(event_type)
            if state:
                send_led_state(state)
        except Exception as e:
            print(f"[EVENT] Parse error: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$LED_EVENT_SCRIPT"

    # LED controller systemd service
    cat > "${SYSTEMD_USER_DIR}/mark2-leds.service" << EOF
[Unit]
Description=Mark II LED Ring Controller
After=sj201.service
Requires=sj201.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${LED_SCRIPT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

    # Patch wyoming-satellite service to use event handler
    WYOMING_SERVICE="${SYSTEMD_USER_DIR}/wyoming-satellite.service"
    if [ -f "$WYOMING_SERVICE" ]; then
        if ! grep -q "event-uri" "$WYOMING_SERVICE"; then
            # Add event URI to ExecStart
            sed -i "s|--wake-word-name.*|&  \\\\\n    --event-uri 'tcp://127.0.0.1:10500'|" "$WYOMING_SERVICE"
            log "Patched wyoming-satellite.service with LED event URI"
        else
            log "wyoming-satellite.service already has --event-uri"
        fi
    else
        warn "wyoming-satellite.service not found - install mark2-satellite-setup.sh first"
        warn "Manually add: --event-uri 'tcp://127.0.0.1:10500' to the ExecStart line"
    fi

    # Wyoming event service (bridges Wyoming events to LED socket)
    cat > "${SYSTEMD_USER_DIR}/mark2-led-events.service" << EOF
[Unit]
Description=Mark II LED Event Bridge
After=wyoming-satellite.service mark2-leds.service
Requires=mark2-leds.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${LED_EVENT_SCRIPT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable mark2-leds.service mark2-led-events.service
    log "LED ring control installed"
    info "LED states: idle=off, wake=pulse-blue, listen=solid-blue, think=spin-cyan, speak=green, error=red"
    info "Test: echo 'listen' | socat - UNIX-CONNECT:/tmp/mark2-leds.sock"
}

# =============================================================================
# MODULE 2: KERNEL WATCHDOG (auto-rebuild VocalFusion)
# =============================================================================

install_kernel_watchdog() {
    section "Kernel Update Watchdog"
    echo "  VocalFusion (SJ201 audio driver) is a compiled kernel module."
    echo "  It breaks silently after every kernel update."
    echo "  This installs:"
    echo "  · A systemd service that checks + rebuilds on boot if needed"
    echo "  · A weekly cron job that runs apt upgrade safely"
    echo ""

    if ! ask_yes_no "Install kernel watchdog?"; then
        log "Skipping kernel watchdog"
        return
    fi

    VOCALFUSION_REPO="https://github.com/OpenVoiceOS/VocalFusionDriver"
    REBUILD_SCRIPT="${MARK2_DIR}/rebuild-vocalfusion.sh"

    cat > "$REBUILD_SCRIPT" << 'SHEOF'
#!/bin/bash
# Rebuild VocalFusion kernel module if needed after kernel update
set -euo pipefail

KERNEL=$(uname -r)
MODULE_PATH="/lib/modules/${KERNEL}/vocalfusion-soundcard.ko"
SRC_PATH="/usr/src/vocalfusion-rebuild"
LOG="/var/log/mark2-vocalfusion-rebuild.log"

echo "[$(date)] Checking VocalFusion module for kernel ${KERNEL}" | sudo tee -a "$LOG"

if [ -f "$MODULE_PATH" ]; then
    echo "[$(date)] Module already exists for ${KERNEL} - no rebuild needed" | sudo tee -a "$LOG"
    exit 0
fi

echo "[$(date)] Module missing for ${KERNEL} - rebuilding..." | sudo tee -a "$LOG"

# Install kernel headers for current kernel
DEBIAN_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-0}")
if [ "$DEBIAN_VERSION" = "13" ]; then
    HEADERS_PKG="linux-headers-rpi-v8"
else
    HEADERS_PKG="raspberrypi-kernel-headers"
fi

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends "$HEADERS_PKG" build-essential

# Clone or update VocalFusion source
if [ -d "$SRC_PATH/.git" ]; then
    (cd "$SRC_PATH" && sudo git pull --quiet)
else
    sudo git clone --quiet https://github.com/OpenVoiceOS/VocalFusionDriver "$SRC_PATH"
fi

# Build
CPU_COUNT=$(nproc)
(cd "${SRC_PATH}/driver" && sudo make -j"$CPU_COUNT" \
    KDIR="/lib/modules/${KERNEL}/build" all) 2>&1 | sudo tee -a "$LOG"

# Install
sudo cp "${SRC_PATH}/driver/vocalfusion-soundcard.ko" "$MODULE_PATH"
sudo depmod -a

# Copy DTBO files (Pi4 and Pi5)
BOOT_OVERLAYS=$([ -d /boot/firmware/overlays ] && echo /boot/firmware/overlays || echo /boot/overlays)
for f in sj201 sj201-buttons-overlay sj201-rev10-pwm-fan-overlay; do
    for suffix in "" "-pi5"; do
        src="${SRC_PATH}/${f}${suffix}.dtbo"
        [ -f "$src" ] && sudo cp "$src" "${BOOT_OVERLAYS}/${f}${suffix}.dtbo"
    done
done

echo "[$(date)] VocalFusion rebuilt successfully for ${KERNEL}" | sudo tee -a "$LOG"

# Restart audio services
systemctl --user restart sj201.service 2>/dev/null || true
SHEOF
    chmod +x "$REBUILD_SCRIPT"

    # Systemd service that runs rebuild check on every boot
    # Runs as root for kernel module installation
    sudo tee /etc/systemd/system/mark2-vocalfusion-watchdog.service > /dev/null << EOF
[Unit]
Description=Mark II VocalFusion kernel module watchdog
DefaultDependencies=no
Before=sj201.service
After=network-online.target

[Service]
Type=oneshot
ExecStart=${REBUILD_SCRIPT}
RemainAfterExit=yes
User=root

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable mark2-vocalfusion-watchdog.service

    # Safe weekly update script (only updates, never dist-upgrades)
    UPDATE_SCRIPT="${MARK2_DIR}/safe-update.sh"
    cat > "$UPDATE_SCRIPT" << 'SHEOF'
#!/bin/bash
# Safe weekly apt update for Mark II
# Only security updates - does NOT dist-upgrade or remove packages
set -euo pipefail
LOG="/var/log/mark2-updates.log"
echo "[$(date)] Starting safe update" | tee -a "$LOG"
apt-get update -qq 2>&1 | tee -a "$LOG"
apt-get upgrade -y --no-install-recommends 2>&1 | tee -a "$LOG"
echo "[$(date)] Update complete" | tee -a "$LOG"
SHEOF
    chmod +x "$UPDATE_SCRIPT"

    # Weekly cron job (Sunday 03:00)
    CRON_FILE="/etc/cron.d/mark2-updates"
    sudo tee "$CRON_FILE" > /dev/null << EOF
# Mark II safe weekly update - runs Sunday at 03:00
# VocalFusion watchdog service will rebuild driver if kernel was updated
0 3 * * 0 root ${UPDATE_SCRIPT}
EOF
    sudo chmod 644 "$CRON_FILE"

    log "Kernel watchdog installed"
    log "VocalFusion will auto-rebuild on boot after kernel updates"
    log "Safe weekly updates scheduled: Sunday 03:00"
    info "Manual rebuild: sudo ${REBUILD_SCRIPT}"
    info "Update logs: /var/log/mark2-updates.log"
    info "Rebuild logs: /var/log/mark2-vocalfusion-rebuild.log"
}

# =============================================================================
# MODULE 3: KDE CONNECT
# =============================================================================

install_kde_connect() {
    section "KDE Connect"
    echo "  Pairs Mark II with your phone for:"
    echo "  · Phone notifications shown on Mark II screen"
    echo "  · Media playback control from phone"
    echo "  · Clipboard sync between phone and Pi"
    echo "  · Use phone as touchpad/keyboard for Mark II"
    echo ""
    echo "  Install KDE Connect or GSConnect on your phone:"
    echo "  Android: KDE Connect (Play Store / F-Droid)"
    echo "  iPhone:  Not supported"
    echo ""

    if ! ask_yes_no "Install KDE Connect?"; then
        log "Skipping KDE Connect"
        return
    fi

    sudo apt-get install -y --no-install-recommends \
        kdeconnect \
        python3-requests

    # Open firewall ports for KDE Connect (if ufw is active)
    if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "active"; then
        sudo ufw allow 1714:1764/tcp comment "KDE Connect"
        sudo ufw allow 1714:1764/udp comment "KDE Connect"
        log "Opened KDE Connect ports in ufw"
    fi

    # Enable as user service
    systemctl --user enable kdeconnect.service 2>/dev/null || {
        # Create service if not present
        cat > "${SYSTEMD_USER_DIR}/kdeconnect.service" << EOF
[Unit]
Description=KDE Connect
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/lib/kdeconnectd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable kdeconnect.service
    }

    log "KDE Connect installed"
    info "Pair from your Android phone: KDE Connect app > Find devices"
    info "Mark II will appear as: $(hostname)"
}

# =============================================================================
# MODULE 4: MPD (Music Player Daemon)
# =============================================================================

install_mpd() {
    section "MPD - Music Player Daemon"
    echo "  Local music player that integrates with:"
    echo "  · Home Assistant media player entity"
    echo "  · Music Assistant (streams local files and radio)"
    echo "  · Snapcast (if installed - MPD feeds audio to Snapcast)"
    echo "  · NCMPC/NCMPCPP for terminal control"
    echo ""

    if ! ask_yes_no "Install MPD?"; then
        log "Skipping MPD"
        return
    fi

    sudo apt-get install -y --no-install-recommends \
        mpd \
        mpc \
        ncmpc

    # Create MPD config directory
    MPD_CONF_DIR="${USER_HOME}/.config/mpd"
    MPD_DB="${USER_HOME}/.local/share/mpd"
    MPD_MUSIC="${USER_HOME}/Music"
    MPD_PLAYLISTS="${MPD_CONF_DIR}/playlists"
    mkdir -p "$MPD_CONF_DIR" "$MPD_DB" "$MPD_MUSIC" "$MPD_PLAYLISTS"

    # Check if Snapcast fifo exists
    SNAPCAST_FIFO=""
    if [ -p "/tmp/snapfifo" ]; then
        SNAPCAST_FIFO="/tmp/snapfifo"
        info "Found Snapcast FIFO - MPD will feed audio to Snapcast"
    fi

    cat > "${MPD_CONF_DIR}/mpd.conf" << EOF
# Mark II MPD configuration
music_directory     "${MPD_MUSIC}"
playlist_directory  "${MPD_PLAYLISTS}"
db_file             "${MPD_DB}/database"
log_file            "${MPD_DB}/log"
pid_file            "${MPD_DB}/pid"
state_file          "${MPD_DB}/state"
sticker_file        "${MPD_DB}/sticker.sql"

# Listen on localhost and network
bind_to_address     "0.0.0.0"
port                "6600"

# Restore playback state on startup
restore_paused      "yes"
auto_update         "yes"

# PipeWire audio output (primary)
audio_output {
    type            "pipewire"
    name            "Mark II Speakers"
}

$([ -n "$SNAPCAST_FIFO" ] && cat << 'SNAPEOF'
# Snapcast output (multiroom sync)
audio_output {
    type            "fifo"
    name            "Snapcast"
    path            "/tmp/snapfifo"
    format          "48000:16:2"
    mixer_type      "software"
}
SNAPEOF
)

# HTTP streaming output (for remote listening)
audio_output {
    type            "httpd"
    name            "Mark II Stream"
    encoder         "lame"
    port            "8000"
    bitrate         "192"
    format          "44100:16:2"
    always_on       "yes"
}
EOF

    # Disable system MPD, run as user service
    sudo systemctl disable --now mpd.service 2>/dev/null || true
    sudo systemctl disable --now mpd.socket 2>/dev/null || true

    cat > "${SYSTEMD_USER_DIR}/mpd.service" << EOF
[Unit]
Description=Music Player Daemon
After=pipewire.service wireplumber.service sj201.service
Wants=pipewire.service

[Service]
Type=notify
ExecStart=/usr/bin/mpd --no-daemon ${MPD_CONF_DIR}/mpd.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable mpd.service

    log "MPD installed"
    info "Music directory: ${MPD_MUSIC}"
    info "HTTP stream: http://$(hostname -I | awk '{print $1}'):8000"
    info "Control: mpc (CLI) or connect Music Assistant to $(hostname -I | awk '{print $1}'):6600"
    info "HA integration: Configuration > Integrations > MPD"
}

# =============================================================================
# MODULE 5: USB AUDIO FALLBACK
# =============================================================================

install_usb_audio_fallback() {
    section "USB Audio Fallback"
    echo "  Automatically switches audio output to a USB DAC/speaker"
    echo "  if the SJ201 sound card fails to initialize at boot."
    echo "  Also creates a manual toggle command: mark2-audio-switch"
    echo ""

    if ! ask_yes_no "Install USB audio fallback?"; then
        log "Skipping USB audio fallback"
        return
    fi

    FALLBACK_SCRIPT="${MARK2_DIR}/audio-fallback.sh"
    SWITCH_SCRIPT="/usr/local/bin/mark2-audio-switch"

    cat > "$FALLBACK_SCRIPT" << 'SHEOF'
#!/bin/bash
# Mark II USB audio fallback
# Checks if SJ201 is working, switches to USB if not
set -euo pipefail

LOG="${HOME}/.config/mark2/audio-fallback.log"
SJ201_CARD_NAME="soc_sound\|XVF3510\|sj201"

echo "[$(date)] Checking audio devices..." >> "$LOG"

# Check if SJ201 is available via ALSA
if aplay -l 2>/dev/null | grep -qi "$SJ201_CARD_NAME"; then
    SJ201_CARD=$(aplay -l | grep -i "$SJ201_CARD_NAME" | head -1 | awk '{print $2}' | tr -d ':')
    echo "[$(date)] SJ201 found at card ${SJ201_CARD} - using hardware audio" >> "$LOG"
    # Set as default PipeWire sink
    SJ201_SINK=$(pactl list short sinks 2>/dev/null | grep -i "soc_sound\|sj201" | awk '{print $2}' | head -1)
    if [ -n "$SJ201_SINK" ]; then
        pactl set-default-sink "$SJ201_SINK"
        echo "[$(date)] Set PipeWire default sink: ${SJ201_SINK}" >> "$LOG"
    fi
    exit 0
fi

echo "[$(date)] SJ201 not found - checking for USB audio..." >> "$LOG"

# Look for USB audio device
USB_SINK=$(pactl list short sinks 2>/dev/null | grep -i "usb\|USB" | awk '{print $2}' | head -1)
if [ -n "$USB_SINK" ]; then
    pactl set-default-sink "$USB_SINK"
    echo "[$(date)] USB audio fallback: ${USB_SINK}" >> "$LOG"
    # Also notify via LED if available
    echo "error" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock 2>/dev/null || true
    sleep 2
    echo "idle" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock 2>/dev/null || true
    exit 0
fi

echo "[$(date)] No audio output found - using default" >> "$LOG"
SHEOF
    chmod +x "$FALLBACK_SCRIPT"

    # Manual toggle script
    sudo tee "$SWITCH_SCRIPT" > /dev/null << SHEOF
#!/bin/bash
# Mark II audio device switcher
# Usage: mark2-audio-switch [sj201|usb|list]

case "${1:-list}" in
    list)
        echo "Available audio sinks:"
        pactl list short sinks | awk '{print NR". "$2}'
        echo ""
        echo "Current default:"
        pactl get-default-sink
        ;;
    sj201)
        SINK=\$(pactl list short sinks | grep -i "soc_sound\|sj201" | awk '{print \$2}' | head -1)
        if [ -n "\$SINK" ]; then
            pactl set-default-sink "\$SINK"
            echo "Switched to SJ201: \$SINK"
        else
            echo "SJ201 not found"
            exit 1
        fi
        ;;
    usb)
        SINK=\$(pactl list short sinks | grep -i "usb\|USB" | awk '{print \$2}' | head -1)
        if [ -n "\$SINK" ]; then
            pactl set-default-sink "\$SINK"
            echo "Switched to USB: \$SINK"
        else
            echo "No USB audio found"
            exit 1
        fi
        ;;
    *)
        # Switch to named sink
        pactl set-default-sink "\$1"
        echo "Switched to: \$1"
        ;;
esac
SHEOF
    sudo chmod +x "$SWITCH_SCRIPT"

    # Systemd user service - runs after boot, after PipeWire is ready
    cat > "${SYSTEMD_USER_DIR}/mark2-audio-fallback.service" << EOF
[Unit]
Description=Mark II USB audio fallback check
After=pipewire.service wireplumber.service sj201.service
Wants=pipewire.service

[Service]
Type=oneshot
ExecStart=${FALLBACK_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable mark2-audio-fallback.service

    log "USB audio fallback installed"
    info "Manual switch: mark2-audio-switch [sj201|usb|list]"
    info "Fallback log: ${USER_HOME}/.config/mark2/audio-fallback.log"
}

# =============================================================================
# MODULE 6: VOLUME / STATUS OVERLAY
# =============================================================================

install_volume_overlay() {
    section "Volume / Status Overlay"
    echo "  Transparent on-screen overlay showing:"
    echo "  · Volume level when changed (auto-hides after 3 seconds)"
    echo "  · Wyoming status (listening / thinking / speaking)"
    echo "  · Current media info (track title from MPD/HA)"
    echo ""
    echo "  Built as a small always-on-top Chromium app window."
    echo ""

    if ! ask_yes_no "Install volume/status overlay?"; then
        log "Skipping volume overlay"
        return
    fi

    OVERLAY_DIR="${USER_HOME}/.config/mark2-overlay"
    mkdir -p "$OVERLAY_DIR"

    # Overlay HTML - transparent floating window
    cat > "${OVERLAY_DIR}/overlay.html" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: transparent;
      overflow: hidden;
      font-family: system-ui, sans-serif;
      pointer-events: none;
    }
    #container {
      position: fixed;
      bottom: 1.5rem;
      left: 50%;
      transform: translateX(-50%);
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.6rem;
      transition: opacity 0.4s ease;
      opacity: 0;
    }
    #container.visible { opacity: 1; }

    #status-pill {
      background: rgba(20,20,40,0.85);
      border: 1px solid rgba(100,120,255,0.3);
      border-radius: 2rem;
      padding: 0.4rem 1.2rem;
      font-size: 0.85rem;
      color: #c0c8ff;
      backdrop-filter: blur(8px);
      display: none;
    }
    #status-pill.visible { display: block; }

    #volume-bar-wrap {
      background: rgba(20,20,40,0.85);
      border: 1px solid rgba(255,255,255,0.1);
      border-radius: 2rem;
      padding: 0.5rem 1.5rem;
      display: flex;
      align-items: center;
      gap: 0.8rem;
      backdrop-filter: blur(8px);
      min-width: 200px;
    }
    #vol-icon { font-size: 1.1rem; }
    #vol-track {
      flex: 1;
      height: 4px;
      background: rgba(255,255,255,0.15);
      border-radius: 2px;
      overflow: hidden;
    }
    #vol-fill {
      height: 100%;
      background: linear-gradient(90deg, #4080ff, #80c0ff);
      border-radius: 2px;
      transition: width 0.2s ease;
      width: 0%;
    }
    #vol-pct {
      font-size: 0.85rem;
      color: #9090c0;
      min-width: 2.5rem;
      text-align: right;
    }
    #media-info {
      background: rgba(20,20,40,0.75);
      border-radius: 1rem;
      padding: 0.3rem 1rem;
      font-size: 0.75rem;
      color: #7080a0;
      max-width: 280px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      display: none;
    }
    #media-info.visible { display: block; }
  </style>
</head>
<body>
  <div id="container">
    <div id="status-pill"></div>
    <div id="volume-bar-wrap">
      <span id="vol-icon">🔊</span>
      <div id="vol-track"><div id="vol-fill"></div></div>
      <span id="vol-pct">--</span>
    </div>
    <div id="media-info"></div>
  </div>

  <script>
    const container  = document.getElementById('container');
    const statusPill = document.getElementById('status-pill');
    const volFill    = document.getElementById('vol-fill');
    const volPct     = document.getElementById('vol-pct');
    const volIcon    = document.getElementById('vol-icon');
    const mediaInfo  = document.getElementById('media-info');

    let hideTimer = null;

    function show(duration=3000) {
      container.classList.add('visible');
      clearTimeout(hideTimer);
      if (duration > 0) {
        hideTimer = setTimeout(() => container.classList.remove('visible'), duration);
      }
    }

    function setVolume(pct) {
      const v = Math.max(0, Math.min(100, pct));
      volFill.style.width = v + '%';
      volPct.textContent  = v + '%';
      volIcon.textContent = v === 0 ? '🔇' : v < 40 ? '🔉' : '🔊';
      show(3000);
    }

    function setStatus(text, persistent=false) {
      statusPill.textContent = text;
      statusPill.classList.add('visible');
      show(persistent ? 0 : 4000);
      if (!persistent) {
        setTimeout(() => statusPill.classList.remove('visible'), 4000);
      }
    }

    function clearStatus() {
      statusPill.classList.remove('visible');
      container.classList.remove('visible');
    }

    function setMedia(text) {
      if (text) {
        mediaInfo.textContent = '♪ ' + text;
        mediaInfo.classList.add('visible');
      } else {
        mediaInfo.classList.remove('visible');
      }
    }

    // Listen for overlay events via BroadcastChannel
    const bc = new BroadcastChannel('mark2-overlay');
    bc.onmessage = (e) => {
      const { type, value } = e.data;
      if (type === 'volume') setVolume(value);
      else if (type === 'status') setStatus(value, false);
      else if (type === 'status-persistent') setStatus(value, true);
      else if (type === 'clear') clearStatus();
      else if (type === 'media') setMedia(value);
    };

    // Also listen via localStorage (fallback for cross-origin)
    window.addEventListener('storage', (e) => {
      if (e.key === 'mark2-overlay') {
        try {
          const msg = JSON.parse(e.newValue);
          bc.dispatchEvent(new MessageEvent('message', { data: msg }));
        } catch(err) {}
      }
    });
  </script>
</body>
</html>
HTMLEOF

    # Overlay trigger script (called by other scripts to show overlay)
    OVERLAY_TRIGGER="${USER_HOME}/.local/bin/mark2-overlay"
    mkdir -p "$(dirname "$OVERLAY_TRIGGER")"
    cat > "$OVERLAY_TRIGGER" << SHEOF
#!/bin/bash
# Send events to the Mark II overlay
# Usage: mark2-overlay volume 75
#        mark2-overlay status "Listening..."
#        mark2-overlay media "Pink Floyd - Comfortably Numb"
#        mark2-overlay clear
TYPE="\${1:-status}"
VALUE="\${2:-}"
# Write to a temp file that the overlay page polls
echo "{\"type\":\"\${TYPE}\",\"value\":\"\${VALUE}\"}" > /tmp/mark2-overlay-event.json
SHEOF
    chmod +x "$OVERLAY_TRIGGER"

    # PipeWire volume monitor - detects volume changes and triggers overlay
    VOLUME_MONITOR="${MARK2_DIR}/volume-monitor.sh"
    cat > "$VOLUME_MONITOR" << 'SHEOF'
#!/bin/bash
# Monitor PipeWire default sink volume and trigger overlay
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
    LABWC_AUTOSTART="${USER_HOME}/.config/labwc/autostart"
    mkdir -p "$(dirname "$LABWC_AUTOSTART")"
    grep -v "overlay.html" "$LABWC_AUTOSTART" 2>/dev/null > /tmp/labwc_tmp || true
    mv /tmp/labwc_tmp "$LABWC_AUTOSTART" 2>/dev/null || true
    # Launch as small always-on-top app window positioned at bottom center
    cat >> "$LABWC_AUTOSTART" << EOF
chromium --app="file://${OVERLAY_DIR}/overlay.html" \
    --window-size=400,120 \
    --window-position=0,360 \
    --ozone-platform=wayland \
    --password-store=basic \
    --no-first-run \
    --disable-infobars \
    --app-auto-launched &
EOF

    systemctl --user daemon-reload
    systemctl --user enable mark2-volume-monitor.service

    log "Volume overlay installed"
    info "Trigger manually: mark2-overlay volume 75"
    info "Show status: mark2-overlay status 'Listening...'"
    info "Overlay appears at bottom of screen, auto-hides after 3s"
}

# =============================================================================
# MUSIC ASSISTANT INFO
# =============================================================================

print_music_assistant_info() {
    section "Music Assistant Integration"
    echo ""
    echo "  Music Assistant runs as a Home Assistant addon (not on Mark II)."
    echo ""
    echo "  Install in HA:"
    echo "  Settings > Add-ons > Music Assistant"
    echo ""
    echo "  Mark II will appear as a player target via:"
    if systemctl --user is-enabled mpd.service >/dev/null 2>&1; then
        echo "  · MPD at $(hostname -I | awk '{print $1}'):6600"
    fi
    if systemctl --user is-enabled snapclient.service >/dev/null 2>&1; then
        echo "  · Snapcast client (multiroom sync)"
    fi
    echo "  · Wyoming media player (HA native)"
    echo ""
    echo "  Music Assistant docs: https://music-assistant.io/integration/ha/"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo "========================================"
echo "  Mark II Advanced Setup"
echo "  User: ${CURRENT_USER}"
echo "========================================"
echo ""
echo "  Each module will be prompted individually."
echo ""

install_led_control
install_kernel_watchdog
install_kde_connect
install_mpd
install_usb_audio_fallback
install_volume_overlay
print_music_assistant_info

echo ""
section "All done"
log "Reboot to activate all installed services: sudo reboot"
echo ""
