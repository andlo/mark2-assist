#!/bin/bash
# =============================================================================
# mark2-satellite-setup.sh
# Mycroft Mark II — Wyoming Voice Satellite + HA Kiosk Display
#
# Run AFTER mark2-hardware-setup.sh and a reboot.
#
# What this script does:
#   1. Detects SJ201 audio device automatically
#   2. Installs Wyoming Satellite + openWakeWord (voice satellite for HA)
#   3. Creates wyoming-satellite.service + wyoming-openwakeword.service
#   4. Installs face event bridge (Wyoming state → /tmp/mark2-face-event.json)
#   5. Installs Weston + Chromium kiosk showing Home Assistant dashboard
#   6. Configures auto-login on tty1 + Weston session startup
#   7. Fixes Chromium GPU flags for Pi4 + Trixie (invalid gles ANGLE backend)
#   8. Disables screen blanking
#   9. Configures PipeWire + MPV for media playback
#
# Wayland compositor: Weston (not labwc)
#   labwc does not composite Chromium surfaces to the DSI display on Pi4
#   with vc4-kms-v3d. Weston renders correctly.
#
# Requirements:
#   - mark2-hardware-setup.sh has been run and device rebooted
#   - Raspberry Pi OS Trixie (Debian 13, 64-bit)
#   - sudo access, internet connection
#
# Usage:
#   chmod +x mark2-satellite-setup.sh
#   ./mark2-satellite-setup.sh
#
# After running, reboot. The touchscreen will show your HA dashboard.
# Add Wyoming integration in HA: Settings → Devices → Wyoming Protocol
# Host: <Mark II IP>  Port: 10700
# =============================================================================

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

check_not_root
setup_paths
config_load

# Satellite name shown in HA — use hostname so each device is unique
SATELLITE_NAME="${SATELLITE_NAME:-$(hostname)}"

# Wake word: ok_nabu, hey_mycroft, alexa, hey_jarvis
WAKE_WORD="${WAKE_WORD:-ok_nabu}"

WYOMING_SAT_DIR="${USER_HOME}/wyoming-satellite"
WYOMING_OWW_DIR="${USER_HOME}/wyoming-openwakeword"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# FUNCTIONS
# =============================================================================

prompt_ha_url() {
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
    sleep 2  # give ALSA a moment after boot

    MIC_DEVICE=""; SPK_DEVICE=""

    if arecord -L 2>/dev/null | grep -q "soc_sound\|xvf3510\|sj201"; then
        MIC_DEVICE=$(arecord -L 2>/dev/null \
               | grep -i "soc_sound\|xvf3510\|sj201" \
               | grep "^plughw:" | head -1)
        # Speaker uses DEV=0 (playback), mic uses DEV=1 (capture)
        # Replace DEV=1 with DEV=0 for speaker, or derive from aplay
        SPK_DEVICE=$(aplay -L 2>/dev/null \
               | grep -i "soc_sound\|xvf3510\|sj201" \
               | grep "^plughw:" | head -1)
        [ -z "$SPK_DEVICE" ] && SPK_DEVICE="${MIC_DEVICE/DEV=1/DEV=0}"
        [ -z "$SPK_DEVICE" ] && SPK_DEVICE="plughw:CARD=sj201,DEV=0"
        log "Mic device:     ${MIC_DEVICE}"
        log "Speaker device: ${SPK_DEVICE}"
    else
        MIC_DEVICE="plughw:0,0"
        SPK_DEVICE="plughw:0,0"
        warn "Could not auto-detect SJ201 — defaulting to plughw:0,0"
        warn "If audio does not work, run: arecord -L and check card name"
    fi
}

install_dependencies() {
    section "Installing dependencies"
    apt_update
    apt_install \
        git python3 python3-venv python3-pip python3-dev \
        alsa-utils curl wget unzip
}

install_wyoming_satellite() {
    section "Installing Wyoming Satellite"
    info "Cloning/updating wyoming-satellite..."
    git_clone_or_pull "https://github.com/rhasspy/wyoming-satellite.git" "$WYOMING_SAT_DIR"
    systemctl --user stop wyoming-satellite.service 2>/dev/null || true
    rm -rf "${WYOMING_SAT_DIR}/.venv"
    info "Running wyoming-satellite setup (creates venv + installs Python deps)..."
    cd "$WYOMING_SAT_DIR"
    python3 script/setup >> "${MARK2_LOG}" 2>&1 \
        || die "Wyoming Satellite setup failed — check ${MARK2_LOG}"
    # Install webrtc-noise-gain for --mic-noise-suppression support
    # This is an optional extra not installed by script/setup by default
    info "Installing webrtc-noise-gain for microphone noise suppression..."
    "${WYOMING_SAT_DIR}/.venv/bin/pip" install --quiet webrtc-noise-gain \
        >> "${MARK2_LOG}" 2>&1 \
        || warn "webrtc-noise-gain install failed — noise suppression disabled"
    log "Wyoming Satellite installed"
}

install_wyoming_openwakeword() {
    section "Installing Wyoming openWakeWord"
    info "Cloning/updating wyoming-openwakeword..."
    git_clone_or_pull "https://github.com/rhasspy/wyoming-openwakeword.git" "$WYOMING_OWW_DIR"
    systemctl --user stop wyoming-openwakeword.service 2>/dev/null || true
    rm -rf "${WYOMING_OWW_DIR}/.venv"
    info "Running openWakeWord setup (downloads wake word models)..."
    cd "$WYOMING_OWW_DIR"
    python3 script/setup >> "${MARK2_LOG}" 2>&1 \
        || die "openWakeWord setup failed — check ${MARK2_LOG}"
    log "openWakeWord installed"
}

create_openwakeword_service() {
    section "Creating wyoming-openwakeword.service"
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "${SYSTEMD_USER_DIR}/wyoming-openwakeword.service" << EOF
[Unit]
Description=Wyoming openWakeWord — local wake word detection for Mark II
After=network-online.target sj201.service

[Service]
Type=simple
ExecStartPre=-/bin/sh -c 'fuser -k 10400/tcp 2>/dev/null; sleep 1'
ExecStart=${WYOMING_OWW_DIR}/script/run \\
    --uri 'tcp://127.0.0.1:10400' \\
    --preload-model '${WAKE_WORD}'
WorkingDirectory=${WYOMING_OWW_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
    log "Created wyoming-openwakeword.service (loopback 127.0.0.1:10400)"
}

create_satellite_service() {
    section "Creating wyoming-satellite.service"
    cat > "${SYSTEMD_USER_DIR}/wyoming-satellite.service" << EOF
[Unit]
Description=Wyoming Satellite (${SATELLITE_NAME}) — HA voice satellite
Wants=network-online.target
After=network-online.target sj201.service wyoming-openwakeword.service
Requires=wyoming-openwakeword.service

[Service]
Type=simple
# Clear port before starting — handles stale processes after unclean shutdown
ExecStartPre=-/bin/sh -c 'fuser -k 10700/tcp 2>/dev/null; sleep 1'
ExecStart=${WYOMING_SAT_DIR}/script/run \\
    --name '${SATELLITE_NAME}' \\
    --uri 'tcp://0.0.0.0:10700' \\
    --mic-command 'arecord -D ${MIC_DEVICE} -r 16000 -c 1 -f S16_LE -t raw --period-size=1024 --buffer-size=4096' \\
    --snd-command 'aplay -D ${SPK_DEVICE} -r 48000 -c 2 -f S16_LE -t raw --period-size=1024 --buffer-size=4096' \\
    --mic-auto-gain 5 \\
    --mic-noise-suppression 2 \\
    --wake-uri 'tcp://127.0.0.1:10400' \\
    --wake-word-name '${WAKE_WORD}' \\
    --awake-wav ${WYOMING_SAT_DIR}/sounds/awake.wav \\
    --done-wav ${WYOMING_SAT_DIR}/sounds/done.wav
WorkingDirectory=${WYOMING_SAT_DIR}
# PATH, XDG_RUNTIME_DIR and DBUS are required for zeroconf/avahi mDNS discovery
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$CURRENT_USER")
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$CURRENT_USER")/bus
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
    # Note: --event-uri is NOT added here.
    # The LED module (modules/leds.sh) adds it when installed,
    # because --event-uri crashes Wyoming if nothing is listening on that port.
    log "Created wyoming-satellite.service (0.0.0.0:10700, zeroconf/mDNS enabled)"
}

enable_satellite_services() {
    section "Enabling Wyoming services"
    systemctl --user daemon-reload 2>/dev/null
    systemctl --user enable wyoming-openwakeword.service wyoming-satellite.service 2>/dev/null
    log "Wyoming services enabled — will start on next boot"
    log "To start now: systemctl --user start wyoming-openwakeword wyoming-satellite"
}

install_face_event_bridge() {
    section "Installing face event bridge"
    # Monitors wyoming-satellite journal and writes current voice state to
    # /tmp/mark2-face-event.json. The HUD overlay reads this file for face
    # animation. Installed here so it works even without the optional face module.
    BRIDGE_SCRIPT="${MARK2_DIR}/face-event-bridge.py"

    cat > "$BRIDGE_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
Wyoming satellite → face event bridge.

Tails the wyoming-satellite systemd journal and writes the current
voice state to /tmp/mark2-face-event.json (atomic write via temp file).

States: idle, wake, listen, think, speak, error
"""
import subprocess, json, os, time

OUT = "/tmp/mark2-face-event.json"

STATE_MAP = {
    "detecting":    "idle",
    "detected":     "wake",
    "recording":    "listen",
    "processing":   "think",
    "synthesizing": "think",
    "playing":      "speak",
    "done":         "idle",
    "error":        "error",
    "muted":        "idle",
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
    proc = subprocess.Popen(
        ["journalctl", "--user", "-u", "wyoming-satellite",
         "-f", "-n", "0", "--output=cat"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    for line in proc.stdout:
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
Description=Mark II face event bridge (Wyoming journal → /tmp/mark2-face-event.json)
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

    systemctl --user daemon-reload 2>/dev/null
    systemctl --user enable mark2-face-events.service 2>/dev/null
    log "Face event bridge installed"
}

install_kiosk_packages() {
    section "Installing kiosk and media packages"
    apt_install \
        weston \
        labwc wlr-randr \
        seatd dbus-user-session xdg-user-dirs \
        chromium grim mpv \
        pipewire pipewire-pulse wireplumber gstreamer1.0-pipewire

    # Chromium GPU fix for Pi4 + Debian Trixie:
    # Debian's /usr/bin/chromium wrapper sets want_gles=1 which appends
    # --use-angle=gles to CHROMIUM_FLAGS. However "gles" is not a valid
    # ANGLE backend on Trixie — only opengl/opengles/swiftshader/vulkan are valid.
    # This causes Chromium's GPU process to crash in a loop → blank/white page.
    # Fix: override want_gles before the wrapper applies it.
    sudo tee /etc/chromium.d/gpu-flags > /dev/null << 'EOF'
# Mark II: fix invalid --use-angle=gles set by Debian Trixie chromium wrapper
want_gles=0
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --use-angle=opengles"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ignore-gpu-blocklist"
EOF
    log "Chromium GPU flags installed (/etc/chromium.d/gpu-flags)"

    sudo systemctl enable seatd >> "${MARK2_LOG}" 2>&1
    sudo usermod -aG video,input "$CURRENT_USER"
    log "Kiosk packages installed"
}

configure_autologin() {
    section "Configuring auto-login and Weston session"

    # Configure getty to auto-login the user on tty1 (no password at boot).
    # Weston is then started from ~/.bash_profile when the session opens.
    GETTY_OVERRIDE_DIR="/etc/systemd/system/getty@tty1.service.d"
    sudo mkdir -p "$GETTY_OVERRIDE_DIR"
    sudo tee "${GETTY_OVERRIDE_DIR}/autologin.conf" > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${CURRENT_USER} --noclear %I \$TERM
EOF
    log "Auto-login on tty1 configured for ${CURRENT_USER}"

    # startup.sh — session command called by Weston via weston -- /path/startup.sh
    # Weston runs this script and exits when it finishes, so we use 'wait' at
    # the end to keep startup.sh alive while kiosk.sh (Chromium) is running.
    STARTUP_SCRIPT="${USER_HOME}/startup.sh"
    cat > "$STARTUP_SCRIPT" << 'EOF'
#!/bin/bash
# Weston session startup script.
# Called by: weston --shell=kiosk -- /home/pi/startup.sh
# Weston stays alive as long as this script is running.
exec >> /tmp/mark2-startup.log 2>&1
echo "[$(date)] startup.sh starting"
/home/pi/kiosk.sh &
sleep 3
/home/pi/hud.sh &
# Keep running so Weston does not exit
wait
EOF
    chmod +x "$STARTUP_SCRIPT"
    log "Created ~/startup.sh"

    # ~/.bash_profile — starts Weston when user logs in on tty1.
    # Weston --backend=drm uses the DRM/KMS display (Pi4 vc4-kms-v3d driver).
    # Weston --shell=kiosk provides a minimal fullscreen compositor without
    # window decorations, taskbars or desktop environment.
    # Weston -- <cmd> runs the startup script as the Weston session.
    BASH_PROFILE="${USER_HOME}/.bash_profile"
    # Remove any old labwc or weston block before writing the new one
    if grep -q "labwc\|weston" "$BASH_PROFILE" 2>/dev/null; then
        sed -i '/# Start Wayland\|labwc\|weston/,/^fi$/d' "$BASH_PROFILE" || true
        log "Removed old compositor block from ~/.bash_profile"
    fi
    cat >> "$BASH_PROFILE" << 'EOF'

# Start Weston kiosk compositor on tty1 (Mark II touchscreen display)
# Weston is used instead of labwc because Chromium 146 on Trixie does not
# composite its render surfaces correctly in labwc on Pi4 with vc4-kms-v3d.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    export XDG_SESSION_TYPE=wayland
    weston --backend=drm --shell=kiosk --log=/tmp/weston.log -- /home/pi/startup.sh
fi
EOF
    log "Weston autostart added to ~/.bash_profile"

    sudo systemctl daemon-reload
}

configure_kiosk() {
    section "Configuring Chromium kiosk and HUD"

    TEMPLATE_DIR="${SCRIPT_DIR}/templates"
    KIOSK_DIR="${USER_HOME}/.config/mark2-kiosk"
    mkdir -p "$KIOSK_DIR"

    # MPD watcher — polls MPD TCP port and writes /tmp/mark2-mpd-state.json
    # Used by MQTT sensors and face animation modules
    sudo install -m 755 "${SCRIPT_DIR}/lib/mpd-watcher.py" /usr/local/bin/mark2-mpd-watcher
    cat > "${SYSTEMD_USER_DIR}/mark2-mpd-watcher.service" << EOF
[Unit]
Description=Mark II MPD state watcher (for face animation and MQTT sensors)
After=mpd.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mark2-mpd-watcher
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    # HUD overlay template (face animation + volume bar)
    cp "${TEMPLATE_DIR}/kiosk.html" "${KIOSK_DIR}/hud.html"
    log "Installed HUD template → ${KIOSK_DIR}/hud.html"

    # ── kiosk.sh — main display launcher ──
    # If ~/.config/mark2/ha-kiosk-enabled exists (written by modules/homeassistant.sh),
    # Chromium opens the HA dashboard. Otherwise it opens the local HUD page,
    # showing only the face animation and clock — useful as a pure voice satellite
    # without an HA dashboard.
    KIOSK_SCRIPT="${USER_HOME}/kiosk.sh"
    cat > "$KIOSK_SCRIPT" << 'SCRIPTEOF'
#!/bin/bash
exec >> /tmp/mark2-kiosk.log 2>&1
echo "[$(date)] kiosk.sh starting"

export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR=/run/user/$(id -u)

CONFIG="${HOME}/.config/mark2/config"
HA_URL=""
[ -f "$CONFIG" ] && source "$CONFIG"

# Wait for Wayland socket (up to 30 seconds)
for i in $(seq 1 30); do
    [ -S "/run/user/$(id -u)/wayland-0" ] && break
    sleep 1
done
echo "[$(date)] Wayland ready"

# Remove stale Chromium singleton lock (left by unclean shutdown)
rm -f "${HOME}/.config/chromium-kiosk/Singleton"*

# Decide what to show:
# - If HA kiosk is enabled (modules/homeassistant.sh was run): open HA dashboard
# - Otherwise: open local HUD page (face + clock only, no HA)
if [ -f "${HOME}/.config/mark2/ha-kiosk-enabled" ] && [ -n "$HA_URL" ]; then
    # Wait for HA to respond (401 Unauthorized is fine — means HA is running)
    until curl -o /dev/null -sf --max-time 3 -w "%{http_code}" "${HA_URL}" \
        2>/dev/null | grep -qE '200|401|302'; do
        sleep 3
    done
    sleep 3
    START_URL="${HA_URL}"
    echo "[$(date)] HA ready, opening dashboard: ${START_URL}"
else
    # No HA dashboard — open local HUD page (face animation + clock)
    START_URL="file://${HOME}/.config/mark2-kiosk/hud.html"
    echo "[$(date)] HA kiosk not enabled, opening local HUD"
fi

exec chromium \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --no-first-run \
    --disable-session-crashed-bubble \
    --disable-component-update \
    --password-store=basic \
    --ozone-platform=wayland \
    --enable-features=UseOzonePlatform \
    --autoplay-policy=no-user-gesture-required \
    --disable-background-timer-throttling \
    --no-sandbox \
    --user-data-dir="${HOME}/.config/chromium-kiosk" \
    "${START_URL}"
SCRIPTEOF
    chmod +x "$KIOSK_SCRIPT"
    log "Created ~/kiosk.sh"

    # ── hud.sh — HUD overlay launcher ──
    # Starts a second Chromium window in --app mode (no browser UI) showing
    # the face animation + volume overlay on top of the kiosk.
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
    log "Created ~/hud.sh"

    # ── labwc rc.xml ──
    # labwc is installed alongside Weston for use by the optional face and
    # overlay modules which need window management (always-on-top windows).
    # rc.xml sets serverDecoration=no globally and maximizes Chromium.
    LABWC_RC="${USER_HOME}/.config/labwc/rc.xml"
    mkdir -p "$(dirname "$LABWC_RC")"
    cat > "$LABWC_RC" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<labwc_config>
  <core>
    <decoration>server</decoration>
    <gap>0</gap>
  </core>
  <windowRules>
    <!-- Remove title bars from all windows -->
    <windowRule identifier="*" serverDecoration="no"/>
    <!-- Maximize Chromium kiosk window -->
    <windowRule identifier="org.chromium.Chromium">
      <action name="Maximize"/>
    </windowRule>
    <!-- Keep HUD overlay always on top -->
    <windowRule identifier="hud.html" matchType="substring">
      <action name="ToggleAlwaysOnTop"/>
    </windowRule>
  </windowRules>
</labwc_config>
EOF
    log "Configured labwc window rules (for optional face/overlay modules)"
}

configure_screen_no_blank() {
    section "Disabling screen blanking"

    # Disable console blanking at kernel level
    BOOT_CMDLINE="/boot/firmware/cmdline.txt"
    if [ -f "$BOOT_CMDLINE" ]; then
        if ! grep -q "consoleblank=0" "$BOOT_CMDLINE"; then
            sudo sed -i 's/$/ consoleblank=0/' "$BOOT_CMDLINE"
            log "Disabled console blanking (consoleblank=0 in cmdline.txt)"
        fi
    fi
}

configure_pipewire_media() {
    section "Configuring PipeWire for media playback"

    # MPV config for hardware-accelerated playback on Pi4
    MPV_CONF_DIR="${USER_HOME}/.config/mpv"
    mkdir -p "$MPV_CONF_DIR"
    cat > "${MPV_CONF_DIR}/mpv.conf" << 'EOF'
# Mark II MPV configuration — hardware-accelerated, PipeWire output
hwdec=v4l2m2m-copy
vo=gpu
gpu-context=wayland
audio-device=pipewire/sink
volume=85
volume-max=100
EOF
    log "Created MPV config for PipeWire/Wayland"

    # Enable PipeWire user services (audio routing)
    systemctl --user enable pipewire.service 2>/dev/null || true
    systemctl --user enable pipewire-pulse.service 2>/dev/null || true
    systemctl --user enable wireplumber.service 2>/dev/null || true
    log "Enabled PipeWire user services"
}

print_summary() {
    local IP
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "========================================"
    log "Mark II Satellite + Kiosk setup complete!"
    echo ""
    echo "  Wyoming integration — add in Home Assistant:"
    echo "    Settings → Devices → Add Integration → Wyoming Protocol"
    echo "    Host: ${IP}   Port: 10700"
    echo ""
    echo "  Wake word: ${WAKE_WORD}"
    echo "  Satellite name: ${SATELLITE_NAME}"
    echo ""
    echo "  After reboot, the touchscreen shows your HA dashboard."
    echo "  For auto-login without keyboard, see README trusted_networks section."
    echo "========================================"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo "========================================"
echo "  Mark II Wyoming Satellite + Kiosk"
echo "  User:           ${CURRENT_USER}"
echo "  Hostname:       $(hostname)"
echo "  Satellite name: ${SATELLITE_NAME} (shown in HA)"
echo "  Wake word:      ${WAKE_WORD}"
echo "  Compositor:     Weston (kiosk shell)"
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

print_summary

if [ "${MARK2_MODULE_CONFIRMED:-0}" != "1" ]; then
    if ask_yes_no "Reboot now to apply all changes?"; then
        log "Rebooting..."
        sleep 2
        sudo reboot
    fi
fi
