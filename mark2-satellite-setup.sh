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

# Wyoming satellite name (shown in HA)
SATELLITE_NAME="${SATELLITE_NAME:-Mark II}"

# Wake word - options: ok_nabu, hey_mycroft, alexa, hey_jarvis
WAKE_WORD="${WAKE_WORD:-ok_nabu}"

# Install paths
WYOMING_SAT_DIR="${USER_HOME}/wyoming-satellite"
WYOMING_OWW_DIR="${USER_HOME}/wyoming-openwakeword"

# =============================================================================
# FUNCTIONS
# =============================================================================

prompt_ha_url() {
    # Uses common.sh: loads saved URL from config or prompts and saves it
    setup_paths
    config_load
    if [ -z "${HA_URL:-}" ]; then
        read -rp "Enter your Home Assistant URL (e.g. http://192.168.1.100:8123): " HA_URL
        [ -z "$HA_URL" ] && die "Home Assistant URL is required for kiosk mode"
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
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        git \
        python3 \
        python3-venv \
        python3-pip \
        python3-dev \
        alsa-utils \
        curl \
        wget \
        unzip
}

install_wyoming_satellite() {
    section "Installing Wyoming Satellite"

    if [ -d "$WYOMING_SAT_DIR" ]; then
        log "Wyoming Satellite already cloned - pulling latest..."
        (cd "$WYOMING_SAT_DIR" && git pull --quiet)
    else
        git clone --quiet https://github.com/rhasspy/wyoming-satellite.git "$WYOMING_SAT_DIR"
        log "Cloned wyoming-satellite"
    fi

    # Stop any running instance before touching the venv
    systemctl --user stop wyoming-satellite.service 2>/dev/null || true

    # Remove broken venv if it exists
    if [ -d "${WYOMING_SAT_DIR}/.venv" ]; then
        log "Removing existing venv to ensure clean setup..."
        rm -rf "${WYOMING_SAT_DIR}/.venv"
    fi

    log "Running Wyoming Satellite setup..."
    cd "$WYOMING_SAT_DIR"
    python3 script/setup
    log "Wyoming Satellite installed"
}

install_wyoming_openwakeword() {
    section "Installing Wyoming openWakeWord"

    if [ -d "$WYOMING_OWW_DIR" ]; then
        log "Wyoming openWakeWord already cloned - pulling latest..."
        (cd "$WYOMING_OWW_DIR" && git pull --quiet)
    else
        git clone --quiet https://github.com/rhasspy/wyoming-openwakeword.git "$WYOMING_OWW_DIR"
        log "Cloned wyoming-openwakeword"
    fi

    # Stop any running instance before touching the venv
    systemctl --user stop wyoming-openwakeword.service 2>/dev/null || true

    # Remove broken venv if it exists (avoids "Text file busy" error)
    if [ -d "${WYOMING_OWW_DIR}/.venv" ]; then
        log "Removing existing venv to ensure clean setup..."
        rm -rf "${WYOMING_OWW_DIR}/.venv"
    fi

    log "Running openWakeWord setup (downloads models - may take a while)..."
    cd "$WYOMING_OWW_DIR"
    python3 script/setup
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
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    log "Created wyoming-satellite.service"
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

    # Minimal Wayland kiosk stack for Raspberry Pi OS Lite.
    # labwc is a lightweight Wayland compositor - no full desktop needed.
    # seatd provides seat management without a display/login manager.
    sudo apt-get install -y --no-install-recommends \
        labwc \
        wlr-randr \
        seatd \
        dbus-user-session \
        xdg-user-dirs \
        chromium \
        unclutter-xfixes \
        mpv \
        pipewire \
        pipewire-pulse \
        wireplumber \
        gstreamer1.0-pipewire

    # Enable seatd (required for labwc to access display hardware without root)
    sudo systemctl enable seatd

    # Add user to video and input groups (required for Wayland/seat access)
    sudo usermod -aG video,input "$CURRENT_USER"
    log "Added ${CURRENT_USER} to video and input groups"
}

configure_autologin() {
    section "Configuring auto-login"
    # Enable auto-login for graphical session via raspi-config noninteractive
    if command -v raspi-config >/dev/null 2>&1; then
        sudo raspi-config nonint do_boot_behaviour B4 2>/dev/null || \
            warn "raspi-config auto-login failed - please enable manually via raspi-config > Boot Options > Desktop Autologin"
    else
        warn "raspi-config not found - please enable graphical auto-login manually"
    fi
    log "Auto-login configured"
}

configure_kiosk() {
    section "Configuring Chromium kiosk mode"

    # Trixie uses labwc (Wayland) - autostart goes here
    LABWC_AUTOSTART_DIR="${USER_HOME}/.config/labwc"
    LABWC_AUTOSTART="${LABWC_AUTOSTART_DIR}/autostart"
    mkdir -p "$LABWC_AUTOSTART_DIR"

    # Create kiosk launch script
    KIOSK_SCRIPT="${USER_HOME}/kiosk.sh"
    cat > "$KIOSK_SCRIPT" << EOF
#!/bin/bash
# Mark II Home Assistant Kiosk
# Waits for display to be ready, then launches Chromium

# Disable screen blanking and power management
wlr-randr 2>/dev/null || true
# For labwc/Wayland - disable dpms
export WAYLAND_DISPLAY=\${WAYLAND_DISPLAY:-wayland-1}

# Hide mouse cursor after 1 second of inactivity (Wayland)
unclutter-xfixes --timeout 1 &

# Disable screen saver / power saving (no-op on Wayland, kept for safety)
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true
xset s noblank 2>/dev/null || true

# Wait for network
until curl -sf --max-time 3 "${HA_URL}" > /dev/null 2>&1; do
    echo "Waiting for Home Assistant at ${HA_URL}..."
    sleep 5
done

# Launch Chromium in kiosk mode
exec chromium \\
    --kiosk \\
    --noerrdialogs \\
    --disable-infobars \\
    --no-first-run \\
    --disable-session-crashed-bubble \\
    --disable-component-update \\
    --disable-translate \\
    --disable-features=TranslateUI \\
    --password-store=basic \\
    --ozone-platform=wayland \\
    --enable-features=UseOzonePlatform \\
    --autoplay-policy=no-user-gesture-required \\
    --disk-cache-dir=/dev/null \\
    --media-router=1 \\
    --enable-media-session-service \\
    "${HA_URL}"
EOF
    chmod +x "$KIOSK_SCRIPT"
    log "Created kiosk script: ${KIOSK_SCRIPT}"

    # Add to labwc autostart
    # Remove old entry if exists
    grep -v "kiosk.sh" "$LABWC_AUTOSTART" 2>/dev/null > /tmp/labwc_autostart_tmp || true
    mv /tmp/labwc_autostart_tmp "$LABWC_AUTOSTART" 2>/dev/null || true
    echo "${KIOSK_SCRIPT} &" >> "$LABWC_AUTOSTART"
    log "Added kiosk to labwc autostart: ${LABWC_AUTOSTART}"

    # Also create a systemd user service as fallback/alternative
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
Environment=WAYLAND_DISPLAY=wayland-1
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
echo "  Wake word:     ${WAKE_WORD}"
echo "  Satellite:     ${SATELLITE_NAME}"
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
