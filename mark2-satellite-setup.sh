#!/bin/bash
# =============================================================================
# mark2-satellite-setup.sh
# Mycroft Mark II — Linux Voice Assistant + HA Kiosk Display
#
# Run AFTER mark2-hardware-setup.sh and a reboot.
#
# Zero-config install: no prompts. Everything configurable in HA UI.
#
# What this script does:
#   1. Installs Linux Voice Assistant (ESPHome protocol, auto-discovered by HA)
#   2. Creates mark2-audio-init.service (MCLK fix + SPI flash + PipeWire restart)
#   3. Installs face event bridge (LVA state → face animation overlay)
#   4. Installs hardware volume button handler (vol up/down/mute → TAS5806)
#   5. Installs Weston + Chromium kiosk opening Home Assistant directly
#   6. Face animation runs as transparent always-on-top overlay window
#   7. Screensaver timeout configurable via HA ESPHome entity
#
# After install + reboot:
#   - Touchscreen shows your HA dashboard (homeassistant.local by default)
#   - Say "okay nabu" to activate voice — face animates during interaction
#   - LVA auto-discovered in HA as ESPHome device (Settings → Devices)
#   - Configure satellite name, wake word, volume in HA UI
#
# Optional config (~/.config/mark2/config):
#   HA_URL=http://192.168.1.100:8123   (if mDNS doesn't work)
#   HA_TOKEN=<long-lived access token> (for face bridge + screensaver)
#   SCREEN_BLANK_SECONDS=300           (screensaver timeout, default 5 min)
#
# Requirements:
#   - mark2-hardware-setup.sh completed + rebooted
#   - Raspberry Pi OS Trixie (Debian 13, 64-bit)
#   - sudo access, internet connection
# =============================================================================

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

check_not_root
setup_paths
config_load

# Satellite name: use hostname so each device is unique.
# Can be renamed in HA UI after discovery.
SATELLITE_NAME="${SATELLITE_NAME:-$(hostname)}"

# Wake word: okay_nabu (default). Change in HA UI via ESPHome select entity.
WAKE_WORD="${WAKE_WORD:-okay_nabu}"

LVA_DIR="${USER_HOME}/lva"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# FUNCTIONS
# =============================================================================

detect_sj201_audio() {
    section "Detecting SJ201 audio device"
    if ! aplay -l 2>/dev/null | grep -q "sj201"; then
        die "SJ201 sound card not found. Run mark2-hardware-setup.sh first and reboot."
    fi
    log "SJ201 audio device detected ✓"
}

install_dependencies() {
    section "Installing dependencies"
    apt_update
    apt_install \
        git python3 python3-venv python3-pip python3-dev \
        alsa-utils curl wget unzip \
        pipewire pipewire-pulse wireplumber gstreamer1.0-pipewire
}

install_lva() {
    section "Installing Linux Voice Assistant"
    # linux-voice-assistant uses ESPHome protocol — same as HA Voice Preview Edition.
    # ESPHome protocol satellite for Home Assistant. Integrates OWW wake word,
    # timers, announcements, media player, and auto-discovery in one service.
    # HA discovers it automatically as an ESPHome device (no manual integration needed).
    apt_install libmpv2 python3-evdev

    LVA_DIR="${USER_HOME}/lva"
    info "Cloning/updating linux-voice-assistant..."
    git_clone_or_pull "https://github.com/OHF-Voice/linux-voice-assistant.git" "$LVA_DIR"

    systemctl --user stop lva.service 2>/dev/null || true
    rm -rf "${LVA_DIR}/.venv"
    info "Running LVA setup (creates venv + installs Python deps)..."
    cd "$LVA_DIR"
    python3 script/setup >> "${MARK2_LOG}" 2>&1 || die "LVA setup failed — check ${MARK2_LOG}"
    log "Linux Voice Assistant installed"

    # ── numpy 2.x patch for pymicro-wakeword ─────────────────────────────────
    # pymicro-wakeword 2.2.1 uses .astype(np.uint8) without clipping first.
    # numpy 2.x changed overflow behaviour: values outside [0,255] no longer
    # wrap silently but emit a RuntimeWarning and produce incorrect values.
    # This corrupts the quantized TFLite tensor, causing the model to never
    # score above threshold — wake word detection silently fails.
    # Fix: clip to [0,255] before cast. See issue #24.
    info "Patching pymicro-wakeword for numpy 2.x compatibility..."
    sudo -u "$CURRENT_USER" "${LVA_DIR}/.venv/bin/python3" - << 'PYEOF' >> "${MARK2_LOG}" 2>&1
import pathlib
matches = list(pathlib.Path('.').rglob('pymicro_wakeword/microwakeword.py'))
if not matches:
    print('WARNING: microwakeword.py not found — skipping numpy patch')
else:
    p = matches[0]
    old = ').astype(np.uint8)'
    new = ').clip(0, 255).astype(np.uint8)'
    t = p.read_text()
    if new in t:
        print('numpy patch already applied')
    elif old in t:
        p.write_text(t.replace(old, new))
        print('numpy patch applied OK')
    else:
        print('WARNING: expected line not found in microwakeword.py')
PYEOF
    log "pymicro-wakeword numpy patch applied"

    section "Installing XVF3510 init service (Mycroft-style MCLK sequence)"
    # ROOT CAUSE (found session 4-5): XVF3510 needs MCLK=12.288MHz.
    # sj201.dtbo wrongly sets MCLK=24.576MHz — audio pipeline never starts.
    # Fix: run setup_mclk (12.288MHz) + setup_bclk before SPI flash.
    # This user-scope oneshot service runs at boot, handles everything:
    #   stops PipeWire → setup_mclk → setup_bclk → flash → restart PipeWire → start LVA
    sudo cp "${SCRIPT_DIR}/lib/mark2-xvf-post-wp.sh" /usr/local/bin/mark2-xvf-post-wp.sh
    sudo chmod +x /usr/local/bin/mark2-xvf-post-wp.sh
    log "mark2-xvf-post-wp.sh installed"
    sudo cp "${SCRIPT_DIR}/lib/mark2-wait-pipewire.sh" /usr/local/bin/mark2-wait-pipewire
    sudo chmod +x /usr/local/bin/mark2-wait-pipewire
    log "mark2-wait-pipewire installed"

    local USER_UID
    USER_UID=$(id -u "$CURRENT_USER")
    cat > "${SYSTEMD_USER_DIR}/mark2-audio-init.service" << EOF
[Unit]
Description=Mark II XVF3510 init — MCLK + SPI flash + PipeWire restart
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mark2-xvf-post-wp.sh
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus
Environment=PULSE_RUNTIME_PATH=/run/user/${USER_UID}/pulse

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --quiet mark2-audio-init.service
    log "mark2-audio-init.service enabled"

    # Disable old services replaced by mark2-audio-init
    systemctl --user disable --quiet sj201.service mark2-reflash.service mark2-audio-init.service 2>/dev/null || true
    systemctl --user enable --quiet  mark2-audio-init.service

    # Install pipewire-alsa for PipeWire ALSA routing
    sudo apt-get install -y pipewire-alsa 2>/dev/null | grep -E "Installing|already" || true

    section "Configuring WirePlumber for SJ201"

    section "Creating lva.service"
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "${SYSTEMD_USER_DIR}/lva.service" << EOF
[Unit]
Description=Linux Voice Assistant (ESPHome protocol) for Home Assistant
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Wait for PipeWire virtual devices before starting (wireplumber gives no ready signal)
ExecStartPre=/usr/local/bin/mark2-wait-pipewire
ExecStart=${LVA_DIR}/.venv/bin/python3 -m linux_voice_assistant \\
    --name '${SATELLITE_NAME}' \\
    --wake-model '${WAKE_WORD}' \\
    --audio-input-device 'alsa_input.platform-soc_sound.pro-input-1' \\
    --audio-output-device 'alsa_output.platform-soc_sound.pro-output-0'
WorkingDirectory=${LVA_DIR}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$CURRENT_USER")
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$CURRENT_USER")/bus
Environment=PIPEWIRE_RUNTIME_DIR=/run/user/$(id -u "$CURRENT_USER")
Environment=PULSE_RUNTIME_PATH=/run/user/$(id -u "$CURRENT_USER")/pulse
Environment=WAYLAND_DISPLAY=wayland-1
# Note: wayland-1 because pipewire/xdg-desktop-portal claim wayland-0 first on this system.
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload 2>/dev/null
    systemctl --user enable --quiet lva.service 2>/dev/null
    log "lva.service created and enabled"
    log "LVA auto-discovers in HA as ESPHome device — no manual integration needed"
    log "To start now: systemctl --user start lva"
}

install_face_event_bridge() {
    section "Installing face event bridge"
    # Monitors HA satellite entity state and writes current voice state to
    # /tmp/mark2-face-event.json. The HUD overlay reads this file for face
    # animation. Installed here so it works even without the optional face module.
    BRIDGE_SCRIPT="${MARK2_DIR}/face-event-bridge.py"

    cp "${SCRIPT_DIR}/lib/face-event-bridge.py" "$BRIDGE_SCRIPT"
    chmod +x "$BRIDGE_SCRIPT"

    cat > "${SYSTEMD_USER_DIR}/mark2-face-events.service" << EOF
[Unit]
Description=Mark II face event bridge (LVA state → /tmp/mark2-face-event.json)
After=lva.service
Wants=lva.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${BRIDGE_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload 2>/dev/null
    systemctl --user enable --quiet mark2-face-events.service 2>/dev/null
    log "Face event bridge installed"
}

install_volume_buttons() {
    section "Installing hardware volume button handler"
    # Installs mark2-volume-buttons: reads KEY_VOLUMEUP/DOWN/MICMUTE from
    # /dev/input/event0 and adjusts TAS5806 I2C register + ALSA PCM softvol.
    # Also writes /tmp/mark2-volume.json for the overlay.
    sudo apt-get install -y --no-install-recommends python3-evdev         >> "${MARK2_LOG}" 2>&1 || warn "python3-evdev install failed"

    sudo install -m 755 "${SCRIPT_DIR}/lib/volume-buttons.py"         /usr/local/bin/mark2-volume-buttons

    cat > "${SYSTEMD_USER_DIR}/mark2-volume-buttons.service" << EOF
[Unit]
Description=Mark II hardware volume buttons (vol up/down/mute → TAS5806)
After=sound.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/mark2-volume-buttons
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload 2>/dev/null
    systemctl --user enable --quiet mark2-volume-buttons.service 2>/dev/null
    log "Volume button handler installed"
}


install_kiosk_packages() {
    section "Installing kiosk and media packages"
    apt_install \
        weston \
        labwc wlr-randr \
        seatd dbus-user-session xdg-user-dirs \
        chromium grim mpv

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

    sudo systemctl enable --quiet seatd >> "${MARK2_LOG}" 2>&1
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

    # startup.sh — session command called by Weston via weston -- ~/startup.sh
    # Uses ${HOME}/kiosk.sh and ${HOME}/hud.sh — no hardcoded /home/pi paths.
    STARTUP_SCRIPT="${USER_HOME}/startup.sh"
    cp "${SCRIPT_DIR}/lib/startup.sh" "$STARTUP_SCRIPT"
    chmod +x "$STARTUP_SCRIPT"
    log "Installed ~/startup.sh"

    # ~/.bash_profile — starts Weston when user logs in on tty1.
    # Weston --backend=drm uses the DRM/KMS display (Pi4 vc4-kms-v3d driver).
    # Weston --shell=kiosk provides a minimal fullscreen compositor without
    # window decorations, taskbars or desktop environment.
    # Weston -- <cmd> runs the startup script as the Weston session.
    BASH_PROFILE="${USER_HOME}/.bash_profile"
    # Remove any old compositor block using unique markers so we never
    # accidentally eat an unrelated if/fi from the existing .bash_profile.
    sed -i '/# mark2-weston-start/,/# mark2-weston-end/d' "$BASH_PROFILE" 2>/dev/null || true
    # Also clean up older installs that used the old unbounded sed pattern
    if grep -q "# Start Weston kiosk compositor" "$BASH_PROFILE" 2>/dev/null; then
        sed -i '/# Start Weston kiosk compositor/,/^fi$/d' "$BASH_PROFILE" || true
        log "Removed old compositor block from ~/.bash_profile"
    fi
    cat >> "$BASH_PROFILE" << 'EOF'

# mark2-weston-start
# Start Weston kiosk compositor on tty1 (Mark II touchscreen display)
# Weston is used instead of labwc because Chromium 146 on Trixie does not
# composite its render surfaces correctly in labwc on Pi4 with vc4-kms-v3d.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    # Hide terminal cursor and set background to black so the login
    # prompt and any residual text are invisible before Weston takes over.
    # Plymouth hands off to tty1 — without this a brief terminal flash is visible.
    setterm -cursor off -blank 0 2>/dev/null || true
    printf '\033[2J\033[H\033[?25l'   # clear screen + hide cursor (ANSI)
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    export XDG_SESSION_TYPE=wayland
    weston --backend=drm --shell=kiosk --idle-time=300 --log=/tmp/weston.log \
        --config="${HOME}/.config/weston.ini" -- "${HOME}/startup.sh"
fi
# mark2-weston-end
EOF
    log "Weston autostart added to ~/.bash_profile"

    # weston.ini — pin Weston to DSI-1 (Mark II touchscreen).
    # Without this, if an HDMI monitor is connected Weston opens on HDMI
    # and the touchscreen stays dark. We explicitly enable only DSI-1 and
    # disable both HDMI outputs so the kiosk always renders on the panel.
    cat > "${USER_HOME}/.config/weston.ini" << 'WESTONEOF'
[output]
name=DSI-1
mode=800x480

[output]
name=HDMI-A-1
mode=off

[output]
name=HDMI-A-2
mode=off
WESTONEOF
    log "Weston configured to use DSI-1 only (~/.config/weston.ini)"

    sudo systemctl daemon-reload
}

configure_kiosk() {
    section "Configuring Chromium kiosk + face overlay"

    # ── mark2-httpd.py — minimal local server (screen-on/off + sounds) ──
    cp "${SCRIPT_DIR}/lib/mark2-httpd.py" "${USER_HOME}/mark2-httpd.py"
    chmod +x "${USER_HOME}/mark2-httpd.py"
    log "Installed ~/mark2-httpd.py (backlight control server)"

    # ── kiosk.sh — main display launcher ──
    # Opens HA directly. Face animation runs as a separate overlay window.
    KIOSK_SCRIPT="${USER_HOME}/kiosk.sh"
    cp "${SCRIPT_DIR}/lib/kiosk.sh" "$KIOSK_SCRIPT"
    chmod +x "$KIOSK_SCRIPT"
    log "Installed ~/kiosk.sh"

    # ── labwc rc.xml — window rules for face overlay ──
    # face.html runs as a transparent always-on-top Chromium window above HA.
    # Weston kiosk shell is used for the main window; labwc handles the overlay.
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
    <!-- Maximize main Chromium kiosk window (HA) -->
    <windowRule identifier="org.chromium.Chromium">
      <action name="Maximize"/>
    </windowRule>
    <!-- Keep face overlay always on top -->
    <windowRule identifier="face.html" matchType="substring">
      <action name="ToggleAlwaysOnTop"/>
    </windowRule>
  </windowRules>
</labwc_config>
EOF
    log "Configured labwc: face overlay always-on-top"
}

configure_screen_no_blank() {
    section "Disabling screen blanking"
    detect_boot_dir

    # Disable console blanking at kernel level
    BOOT_CMDLINE="/boot/firmware/cmdline.txt"
    if [ -f "$BOOT_CMDLINE" ]; then
        if ! grep -q "consoleblank=0" "$BOOT_CMDLINE"; then
            sudo sed -i 's/$/ consoleblank=0/' "$BOOT_CMDLINE"
            log "Disabled console blanking (consoleblank=0 in cmdline.txt)"
        fi
        # Workaround for Pi4 DSI display staying blank after warm reboot.
        # The vc4-kms-v3d driver sometimes fails to reinitialise the DSI panel
        # on warm reboot. force_hotplug forces hotplug re-detection on every boot
        # and is the most effective known workaround for this upstream kernel bug.
        # See: https://github.com/agherzan/meta-raspberrypi/issues/1368
        if ! grep -q "vc4.force_hotplug=1" "$BOOT_CMDLINE"; then
            sudo sed -i 's/$/ vc4.force_hotplug=1/' "$BOOT_CMDLINE"
            log "Added vc4.force_hotplug=1 to cmdline.txt (DSI warm-reboot workaround)"
        fi
    fi

    # disable_fw_kms_setup=1: let the kernel own KMS setup rather than firmware.
    # Second layer of the same DSI warm-reboot workaround.
    if [ -f "$BOOT_CONFIG" ] && ! grep -q "disable_fw_kms_setup" "$BOOT_CONFIG"; then
        echo "disable_fw_kms_setup=1" | sudo tee -a "$BOOT_CONFIG" > /dev/null
        log "Added disable_fw_kms_setup=1 to config.txt (DSI warm-reboot workaround)"
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
    systemctl --user enable --quiet pipewire.service 2>/dev/null || true
    systemctl --user enable --quiet pipewire-pulse.service 2>/dev/null || true
    systemctl --user enable --quiet wireplumber.service 2>/dev/null || true
    log "Enabled PipeWire user services"
}

print_summary() {
    local IP
    IP=$(hostname -I | awk '{print $1}')

    log "Mark II Satellite + Kiosk setup complete!"
    echo ""
    echo "========================================"
    echo "  Mark II Linux Voice Assistant + Kiosk"
    echo "========================================"
    echo ""
    echo "  Next steps:"
    echo ""
    echo "  1. Reboot:"
    echo "     sudo reboot"
    echo ""
    echo "  2. Touchscreen shows Home Assistant (homeassistant.local)"
    echo "     If mDNS doesn't work, set HA URL:"
    echo "     echo 'HA_URL=http://192.168.x.x:8123' >> ~/.config/mark2/config"
    echo ""
    echo "  3. In Home Assistant — ESPHome device auto-discovered:"
    echo "     Settings → Devices & Services → ESPHome → ${SATELLITE_NAME}"
    echo "     Configure: satellite name, wake word, volume, screensaver"
    echo ""
    echo "  4. Set voice pipeline:"
    echo "     Settings → Voice Assistants → ${SATELLITE_NAME}"
    echo ""
    echo "  5. Say '${WAKE_WORD}' — face animates, voice command processed"
    echo "========================================"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

[ "${MARK2_CALLED_FROM_INSTALLER:-0}" = "1" ] || print_banner "Satellite + Kiosk Setup"
echo "  User:     ${CURRENT_USER}"
echo "  Hostname: $(hostname)"
echo ""

detect_sj201_audio
install_dependencies
install_lva
install_face_event_bridge
install_volume_buttons
install_kiosk_packages
configure_autologin
configure_screen_no_blank
configure_kiosk
configure_pipewire_media

[ "${MARK2_CALLED_FROM_INSTALLER:-0}" = "1" ] || print_summary

if [ "${MARK2_MODULE_CONFIRMED:-0}" != "1" ]; then
    if ask_yes_no "Reboot now to apply all changes?"; then
        log "Rebooting..."
        sleep 2
        sudo reboot
    fi
fi
