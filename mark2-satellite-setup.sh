#!/bin/bash

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# =============================================================================
# mark2-satellite-setup.sh
# Mycroft Mark II - Wyoming Voice Satellite + HA Kiosk Display + Media Player
#
# Run this AFTER mark2-hardware-setup.sh and a reboot.
#
# What this script does:
#   - Installs Wyoming Satellite + openWakeWord
#   - Detects SJ201 audio device automatically
#   - Creates and enables wyoming-satellite.service
#   - Creates and enables wyoming-openwakeword.service
#   - Installs Chromium and opens Home Assistant in kiosk mode on touchscreen
#   - Configures labwc autostart (Trixie Wayland compositor)
#   - Disables screen blanking / power management
#   - Installs MPV + sets up PipeWire for media playback (audio + video)
#   - Enables auto-login to graphical session
#
# Requirements:
#   - mark2-hardware-setup.sh has been run and device rebooted
#   - Raspberry Pi OS Trixie (Desktop or Lite with labwc)
#   - sudo access
#   - Internet connection
#
# Usage:
#   chmod +x mark2-satellite-setup.sh
#   ./mark2-satellite-setup.sh
#
# After running:
#   - Edit HA_URL below or answer the prompt during setup
#   - In Home Assistant: Settings > Devices > Add Integration > Wyoming Protocol
#     Host: <Mark II IP address>  Port: 10700
# =============================================================================

set -euo pipefail

# --- Output colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()     { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# --- Check not running as raw root ---
if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    die "Do not run as root directly. Use: ./mark2-satellite-setup.sh"
fi

CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"

# =============================================================================
# CONFIGURATION - Edit these or answer prompts
# =============================================================================

# Home Assistant URL - will prompt if empty
HA_URL="${HA_URL:-}"

# Wyoming satellite name (shown in HA) - defaults to hostname
SATELLITE_NAME="${SATELLITE_NAME:-$(hostname)}"

# Wake word - options: ok_nabu, hey_mycroft, alexa, hey_jarvis
WAKE_WORD="${WAKE_WORD:-ok_nabu}"

# Install paths
WYOMING_SAT_DIR="${USER_HOME}/wyoming-satellite"
WYOMING_OWW_DIR="${USER_HOME}/wyoming-openwakeword"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# FUNCTIONS
# =============================================================================

prompt_ha_url() {
    setup_paths
    config_load
    if [ -z "${HA_URL:-}" ]; then
        HA_URL=$(ask_input "Home Assistant URL" "http://192.168.1.100:8123") \
            || die "Home Assistant URL is required"
        [ -z "$HA_URL" ] && die "Home Assistant URL is required"
        config_save "HA_URL" "$HA_URL"
    else
        log "Using saved Home Assistant URL: ${HA_URL}"
    fi
    export HA_URL
}
detect_sj201_audio() {
    section "Detecting SJ201 audio device"

    # Give ALSA a moment after boot
    sleep 2

    # Look for the SJ201 / XVF3510 sound card
    MIC_DEVICE=""
    SPK_DEVICE=""

    # Try to find the soc_sound card (Mark II SJ201)
    if arecord -L 2>/dev/null | grep -q "soc_sound\|xvf3510\|sj201"; then
        CARD=$(arecord -L 2>/dev/null | grep -i "soc_sound\|xvf3510\|sj201" | grep "^plughw:" | head -1)
        MIC_DEVICE="$CARD"
        SPK_DEVICE="$CARD"
        log "Found SJ201 audio device: ${CARD}"
    else
        # Fallback: use card index 0 which should be SJ201 after our hardware setup
        MIC_DEVICE="plughw:0,0"
        SPK_DEVICE="plughw:0,0"
        warn "Could not auto-detect SJ201 device name - defaulting to plughw:0,0"
        warn "If audio does not work, run: arecord -L and update the service manually"
    fi
}

install_dependencies() {
    section "Installing dependencies"
    info "Installing dependencies..."
    apt_update
    apt_install \
        git python3 python3-venv python3-pip python3-dev \
        alsa-utils curl wget unzip
}

install_wyoming_satellite() {
    section "Installing Wyoming Satellite"
    info "Installing Wyoming Satellite (this may take a few minutes)..."
    git_clone_or_pull "https://github.com/rhasspy/wyoming-satellite.git" "$WYOMING_SAT_DIR"
    systemctl --user stop wyoming-satellite.service 2>/dev/null || true
    if [ -d "${WYOMING_SAT_DIR}/.venv" ]; then
        info "Removing existing Wyoming Satellite venv..."
        rm -rf "${WYOMING_SAT_DIR}/.venv"
    fi
    info "Running Wyoming Satellite setup..."
    cd "$WYOMING_SAT_DIR"
    python3 script/setup >> "${MARK2_LOG}" 2>&1 || die "Wyoming Satellite setup failed — check ${MARK2_LOG}"
    log "Wyoming Satellite installed"
}

install_wyoming_openwakeword() {
    section "Installing Wyoming openWakeWord"
    info "Installing Wyoming openWakeWord (this may take a few minutes)..."
    git_clone_or_pull "https://github.com/rhasspy/wyoming-openwakeword.git" "$WYOMING_OWW_DIR"
    systemctl --user stop wyoming-openwakeword.service 2>/dev/null || true
    if [ -d "${WYOMING_OWW_DIR}/.venv" ]; then
        info "Removing existing openWakeWord venv..."
        rm -rf "${WYOMING_OWW_DIR}/.venv"
    fi
    info "Running openWakeWord setup (downloading models)..."
    cd "$WYOMING_OWW_DIR"
    python3 script/setup >> "${MARK2_LOG}" 2>&1 || die "openWakeWord setup failed — check ${MARK2_LOG}"
    log "openWakeWord installed"
}

create_openwakeword_service() {
    section "Creating wyoming-openwakeword.service"
    mkdir -p "$SYSTEMD_USER_DIR"

    cat > "${SYSTEMD_USER_DIR}/wyoming-openwakeword.service" << EOF
[Unit]
Description=Wyoming openWakeWord
After=network-online.target sj201.service

[Service]
Type=simple
ExecStart=${WYOMING_OWW_DIR}/script/run \\
    --uri 'tcp://127.0.0.1:10400' \\
    --preload-model '${WAKE_WORD}'
WorkingDirectory=${WYOMING_OWW_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    log "Created wyoming-openwakeword.service"
}

create_satellite_service() {
    section "Creating wyoming-satellite.service"

    cat > "${SYSTEMD_USER_DIR}/wyoming-satellite.service" << EOF
[Unit]
Description=Wyoming Satellite (${SATELLITE_NAME})
Wants=network-online.target
After=network-online.target sj201.service wyoming-openwakeword.service
Requires=wyoming-openwakeword.service

[Service]
Type=simple
ExecStartPre=-/bin/sh -c 'fuser -k 10700/tcp 2>/dev/null; sleep 1'
ExecStart=${WYOMING_SAT_DIR}/script/run \\
    --name '${SATELLITE_NAME}' \\
    --uri 'tcp://0.0.0.0:10700' \\
    --mic-command 'arecord -D ${MIC_DEVICE} -r 16000 -c 1 -f S16_LE -t raw' \\
    --snd-command 'aplay -D ${SPK_DEVICE} -r 22050 -c 1 -f S16_LE -t raw' \\
    --mic-auto-gain 5 \\
    --mic-noise-suppression 2 \\
    --wake-uri 'tcp://127.0.0.1:10400' \\
    --wake-word-name '${WAKE_WORD}' \\
    --awake-wav ${WYOMING_SAT_DIR}/sounds/awake.wav \\
    --done-wav ${WYOMING_SAT_DIR}/sounds/done.wav
WorkingDirectory=${WYOMING_SAT_DIR}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$CURRENT_USER")
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$CURRENT_USER")/bus
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    log "Created wyoming-satellite.service"
}

install_face_event_bridge() {
    section "Installing face event bridge"

    # Writes Wyoming satellite state to /tmp/mark2-face-event.json
    # so the HUD face animation always works regardless of LED module
    BRIDGE_SCRIPT="${MARK2_DIR}/face-event-bridge.py"
    mkdir -p "$MARK2_DIR"

    cat > "$BRIDGE_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
Wyoming satellite event bridge.
Monitors wyoming-satellite journal and writes face state to
/tmp/mark2-face-event.json for the HUD to read.
"""
import subprocess
import json
import os
import re
import time

OUT = "/tmp/mark2-face-event.json"

STATE_MAP = {
    "detecting":  "idle",
    "detected":   "wake",
    "recording":  "listen",
    "processing": "think",
    "synthesizing": "think",
    "playing":    "speak",
    "done":       "idle",
    "error":      "error",
    "muted":      "idle",
    "StreamingStarted": "listen",
    "StreamingStopped": "idle",
    "RunSatellite": "idle",
}

def write_state(state):
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"state": state, "ts": time.time()}, f)
    os.replace(tmp, OUT)

def main():
    write_state("idle")
    cmd = ["journalctl", "--user", "-u", "wyoming-satellite",
           "-f", "-n", "0", "--output=cat"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True)
    for line in proc.stdout:
        line = line.strip()
        for key, state in STATE_MAP.items():
            if key.lower() in line.lower():
                write_state(state)
                break

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$BRIDGE_SCRIPT"

    cat > "${SYSTEMD_USER_DIR}/mark2-face-events.service" << EOF
[Unit]
Description=Mark II face event bridge (Wyoming → HUD)
After=wyoming-satellite.service
Wants=wyoming-satellite.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${BRIDGE_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable mark2-face-events.service
    log "Face event bridge installed"
}

enable_satellite_services() {
    section "Enabling Wyoming services"
    systemctl --user daemon-reload
    systemctl --user enable wyoming-openwakeword.service
    systemctl --user enable wyoming-satellite.service
    log "Wyoming services enabled (will start on next boot)"
    log "To start now: systemctl --user start wyoming-openwakeword wyoming-satellite"
}

install_kiosk_packages() {
    section "Installing kiosk and media packages"
    info "Installing kiosk packages (labwc, chromium, pipewire)..."
    apt_install \
        labwc wlr-randr seatd dbus-user-session xdg-user-dirs \
        chromium unclutter-xfixes mpv \
        pipewire pipewire-pulse wireplumber gstreamer1.0-pipewire
    sudo systemctl enable seatd >> "${MARK2_LOG}" 2>&1
    sudo usermod -aG video,input "$CURRENT_USER"
    log "Kiosk packages installed, ${CURRENT_USER} added to video+input groups"
}

configure_autologin() {
    section "Configuring auto-login"

    # On RPi OS Lite with labwc we do NOT use raspi-config/lightdm.
    # Instead we configure getty to auto-login on tty1, and labwc
    # starts automatically from ~/.bash_profile when on tty1.

    # Auto-login on tty1 via getty override
    GETTY_OVERRIDE_DIR="/etc/systemd/system/getty@tty1.service.d"
    sudo mkdir -p "$GETTY_OVERRIDE_DIR"
    sudo tee "${GETTY_OVERRIDE_DIR}/autologin.conf" > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${CURRENT_USER} --noclear %I \$TERM
EOF
    log "Auto-login on tty1 configured for ${CURRENT_USER}"

    # Start labwc automatically when logging in on tty1
    BASH_PROFILE="${USER_HOME}/.bash_profile"
    # Startup wrapper called by labwc -s
    STARTUP_SCRIPT="${USER_HOME}/startup.sh"
    cat > "$STARTUP_SCRIPT" << 'EOF'
#!/bin/bash
exec >> /tmp/mark2-startup.log 2>&1
echo "[$(date)] startup.sh called by labwc"
/home/pi/kiosk.sh &
sleep 3
/home/pi/hud.sh &
EOF
    chmod +x "$STARTUP_SCRIPT"
    log "Created startup.sh"

    if ! grep -q "labwc" "$BASH_PROFILE" 2>/dev/null; then
        cat >> "$BASH_PROFILE" << 'EOF'

# Start labwc on tty1
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    export XDG_SESSION_TYPE=wayland
    export WAYLAND_DISPLAY=wayland-0
    labwc -s /home/pi/startup.sh
fi
EOF
        log "labwc autostart added to ~/.bash_profile"
    else
        log "labwc autostart already in ~/.bash_profile"
    fi

    sudo systemctl daemon-reload
}

configure_kiosk() {
    section "Configuring Chromium kiosk"

    TEMPLATE_DIR="${SCRIPT_DIR}/templates"
    KIOSK_DIR="${USER_HOME}/.config/mark2-kiosk"
    mkdir -p "$KIOSK_DIR"

    # Install MPD watcher
    sudo install -m 755 "${SCRIPT_DIR}/lib/mpd-watcher.py" /usr/local/bin/mark2-mpd-watcher

    cat > "${SYSTEMD_USER_DIR}/mark2-mpd-watcher.service" << EOF
[Unit]
Description=Mark II MPD state watcher
After=mpd.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mark2-mpd-watcher
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    # Copy HUD template
    cp "${TEMPLATE_DIR}/kiosk.html" "${KIOSK_DIR}/hud.html"
    log "Copied HUD template to ${KIOSK_DIR}/hud.html"

    # ── HA kiosk launcher ──
    KIOSK_SCRIPT="${USER_HOME}/kiosk.sh"
    cat > "$KIOSK_SCRIPT" << 'SCRIPTEOF'
#!/bin/bash
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR=/run/user/$(id -u)

CONFIG="${HOME}/.config/mark2/config"
HA_URL=""; HA_TOKEN=""
[ -f "$CONFIG" ] && source "$CONFIG"

until curl -sf --max-time 3 "${HA_URL}" > /dev/null 2>&1; do
    echo "Waiting for Home Assistant at ${HA_URL}..."; sleep 5
done

if [ -n "${HA_TOKEN}" ]; then
    START_URL="${HA_URL}?auth_callback=1&code=${HA_TOKEN}&state=/"
else
    START_URL="${HA_URL}"
fi

exec chromium \
    --kiosk --noerrdialogs --disable-infobars --no-first-run \
    --disable-session-crashed-bubble --disable-component-update \
    --password-store=basic --ozone-platform=wayland \
    --enable-features=UseOzonePlatform \
    --autoplay-policy=no-user-gesture-required \
    --disable-background-timer-throttling \
    --user-data-dir="${HOME}/.config/chromium-kiosk" \
    "${START_URL}"
SCRIPTEOF
    chmod +x "$KIOSK_SCRIPT"
    log "Created HA kiosk script: ${KIOSK_SCRIPT}"

    # ── HUD launcher ──
    HUD_SCRIPT="${USER_HOME}/hud.sh"
    cat > "$HUD_SCRIPT" << EOF
#!/bin/bash
export WAYLAND_DISPLAY=\${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
sleep 3
exec chromium \\
    --app="file://${KIOSK_DIR}/hud.html" \\
    --window-size=800,480 --window-position=0,0 \\
    --ozone-platform=wayland --password-store=basic \\
    --no-first-run --disable-infobars \\
    --disable-background-timer-throttling \\
    --app-auto-launched --enable-features=UseOzonePlatform
EOF
    chmod +x "$HUD_SCRIPT"
    log "Created HUD script: ${HUD_SCRIPT}"

    # ── labwc rc.xml ──
    LABWC_RC="${USER_HOME}/.config/labwc/rc.xml"
    mkdir -p "$(dirname "$LABWC_RC")"
    cat > "$LABWC_RC" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<labwc_config>
  <core><decoration>client</decoration><gap>0</gap></core>
  <windowRules>
    <windowRule identifier="hud.html" matchType="substring">
      <action name="ToggleAlwaysOnTop"/>
      <skipTaskbar>yes</skipTaskbar>
    </windowRule>
  </windowRules>
</labwc_config>
EOF
    log "Configured labwc window rules"

    labwc_autostart_add "kiosk.sh" "${KIOSK_SCRIPT} &"
    labwc_autostart_add "hud.sh"   "${HUD_SCRIPT} &"

    cat > "${SYSTEMD_USER_DIR}/ha-kiosk.service" << EOF
[Unit]
Description=Home Assistant Kiosk Display
After=graphical-session.target network-online.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStart=${KIOSK_SCRIPT}
Restart=on-failure
RestartSec=10
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$CURRENT_USER")

[Install]
WantedBy=graphical-session.target
EOF
    log "Created ha-kiosk.service"
}

configure_screen_no_blank() {
    section "Disabling screen blanking"

    # labwc config for Trixie
    LABWC_RC_DIR="${USER_HOME}/.config/labwc"
    mkdir -p "$LABWC_RC_DIR"

    # Disable DPMS in labwc if rc.xml exists or create minimal one
    LABWC_RC="${LABWC_RC_DIR}/rc.xml"
    if [ ! -f "$LABWC_RC" ]; then
        cat > "$LABWC_RC" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<labwc_config>
  <core>
    <decoration>client</decoration>
  </core>
</labwc_config>
EOF
    fi

    # Disable console blanking in kernel
    BOOT_CMDLINE="/boot/firmware/cmdline.txt"
    if [ -f "$BOOT_CMDLINE" ]; then
        if ! grep -q "consoleblank=0" "$BOOT_CMDLINE"; then
            sudo sed -i 's/$/ consoleblank=0/' "$BOOT_CMDLINE"
            log "Disabled console blanking in cmdline.txt"
        fi
    fi
}

configure_pipewire_media() {
    section "Configuring PipeWire for media playback"

    PIPEWIRE_CONF_DIR="${USER_HOME}/.config/pipewire"
    mkdir -p "$PIPEWIRE_CONF_DIR"

    # MPV config for hardware-accelerated playback on Pi
    MPV_CONF_DIR="${USER_HOME}/.config/mpv"
    mkdir -p "$MPV_CONF_DIR"
    cat > "${MPV_CONF_DIR}/mpv.conf" << 'EOF'
# Mark II MPV configuration
# Hardware-accelerated video decoding
hwdec=v4l2m2m-copy
vo=gpu
gpu-context=wayland
audio-device=pipewire/sink
volume=85
volume-max=100
# Loop media by default (useful for HA dashboards)
# loop=inf
EOF
    log "Created MPV config for PipeWire/Wayland"

    # Enable PipeWire user services
    systemctl --user enable pipewire.service 2>/dev/null || true
    systemctl --user enable pipewire-pulse.service 2>/dev/null || true
    systemctl --user enable wireplumber.service 2>/dev/null || true
    log "Enabled PipeWire user services"
}

enable_kiosk_service() {
    section "Enabling kiosk service"
    systemctl --user daemon-reload
    systemctl --user enable ha-kiosk.service 2>/dev/null || \
        warn "ha-kiosk.service enable failed - labwc autostart will be used instead"
    log "Kiosk service configured"
}

print_ha_instructions() {
    section "Home Assistant integration"
    local IP
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "  In Home Assistant:"
    echo "  1. Settings > Devices & Services > Add Integration"
    echo "  2. Search for: Wyoming Protocol"
    echo "  3. Host: ${IP}"
    echo "  4. Port: 10700"
    echo ""
    echo "  For media player (audio/video from HA to Mark II):"
    echo "  - Install 'Music Assistant' or use HA media player integrations"
    echo "  - MPV is installed and configured for PipeWire"
    echo "  - Alternatively use: Settings > Companion App > Assist satellite"
    echo ""
    echo "  Wake word: '${WAKE_WORD}'"
    echo "  To change wake word: edit ~/wyoming-satellite/wyoming-satellite.service"
    echo "  Available: ok_nabu, hey_mycroft, alexa, hey_jarvis"
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo "========================================"
echo "  Mark II Wyoming Satellite + Kiosk"
echo "  User:          ${CURRENT_USER}"
echo "  Hostname:      $(hostname)"
echo "  Satellite name:$(hostname) (shown in HA)"
echo "  Wake word:     ${WAKE_WORD}"
echo "========================================"
echo ""

prompt_ha_url
detect_sj201_audio
install_dependencies
install_wyoming_satellite
install_wyoming_openwakeword
create_openwakeword_service
create_satellite_service
enable_satellite_services
install_face_event_bridge
install_kiosk_packages
configure_autologin
configure_screen_no_blank
configure_kiosk
configure_pipewire_media
enable_kiosk_service

echo ""
echo "========================================"
log "Mark II Satellite + Kiosk setup complete!"
echo ""
echo "  Next steps:"
echo "  1. Reboot: sudo reboot"
echo "  2. After reboot, touchscreen will show Home Assistant"
echo "  3. Add Wyoming integration in HA (see instructions below)"
echo ""
print_ha_instructions
echo "========================================"
echo ""

if [ "${MARK2_MODULE_CONFIRMED:-0}" != "1" ]; then
    if ask_yes_no "Reboot now to apply all changes?"; then
        log "Rebooting..."
        sleep 2
        sudo reboot
    fi
fi
