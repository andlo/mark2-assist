#!/bin/bash
# =============================================================================
# mark2-satellite-setup.sh
# Mycroft Mark II — Linux Voice Assistant + HA Kiosk Display
#
# Run AFTER mark2-hardware-setup.sh and a reboot.
#
# Uses linux-voice-assistant (OHF-Voice/linux-voice-assistant) which replaces
# the deprecated wyoming-satellite. Uses ESPHome protocol — same as HA Voice PE.
# Features: local OWW wake word, timers, announcements, media player, auto-discovery.
#
# What this script does:
#   1. Detects SJ201 audio device automatically
#   2. Installs Linux Voice Assistant (ESPHome protocol, replaces Wyoming Satellite)
#   3. Creates lva.service (auto-discovered by HA as ESPHome device)
#   4. Installs face event bridge (LVA state → /tmp/mark2-face-event.json)
#   5. Installs hardware volume button handler (vol up/down/mute → TAS5806)
#   6. Installs Weston + Chromium kiosk showing Home Assistant dashboard
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
# LVA auto-discovers in HA as ESPHome device — no manual integration needed
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

# Wake word: okay_nabu, hey_mycroft, alexa, hey_jarvis, hey_rhasspy
# NOTE: pyopen_wakeword uses 'okay_nabu' (not 'ok_nabu') — must match exactly
WAKE_WORD="${WAKE_WORD:-okay_nabu}"

LVA_DIR="${USER_HOME}/lva"
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

    # Microphone: use ALSA 'default' device which resolves via ~/.asoundrc
    # to VF_ASR_(L) — XMOS XVF-3510's dedicated ASR output channel.
    # Do NOT use plughw:CARD=sj201,DEV=1 directly: that bypasses .asoundrc
    # and delivers raw 48kHz stereo from the XMOS chip before resampling,
    # which produces RMS~20 (unusable) vs RMS~500+ via the ASR channel.
    MIC_DEVICE="default"

    # Speaker: detect plughw device for aplay (needs explicit device + format)
    SPK_DEVICE=""
    if aplay -L 2>/dev/null | grep -q "soc_sound\|xvf3510\|sj201"; then
        SPK_DEVICE=$(aplay -L 2>/dev/null \
               | grep -i "soc_sound\|xvf3510\|sj201" \
               | grep "^plughw:" | head -1)
    fi
    [ -z "$SPK_DEVICE" ] && SPK_DEVICE="plughw:CARD=sj201,DEV=0"
    log "Mic device:     default (→ VF_ASR_(L) via .asoundrc)"
    log "Speaker device: ${SPK_DEVICE}"
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

    section "Installing XVF3510 system-level init service"
    # Install as a SYSTEM service (not user service) so it runs BEFORE
    # user@<uid>.service starts — and therefore before PipeWire/WirePlumber.
    # This eliminates the race condition where WirePlumber resets the XVF3510
    # DSP pipeline at the same moment as the flash is attempted.
    #
    # Runs as CURRENT_USER (not root) because xvf3510-flash uses
    # blinka/CircuitPython which requires SPI/GPIO group membership.
    # SupplementaryGroups ensures access without sudo.
    local USER_UID
    USER_UID=$(id -u "$CURRENT_USER")
    sudo bash -c "cat > /etc/systemd/system/mark2-xvf3510-init.service" << EOF
[Unit]
Description=XVF3510 firmware flash and TAS5806 init
Documentation=https://github.com/andlo/mark2-assist
Before=user@${USER_UID}.service
After=sound.target local-fs.target
DefaultDependencies=no
StartLimitBurst=3
StartLimitIntervalSec=30s

[Service]
Type=oneshot
RemainAfterExit=yes
User=${CURRENT_USER}
Group=${CURRENT_USER}
SupplementaryGroups=spi gpio audio
WorkingDirectory=/opt/sj201
Environment=PATH=/usr/local/bin:/usr/sbin:/usr/bin:/bin
ExecStart=${USER_HOME}/.venvs/sj201/bin/python /opt/sj201/xvf3510-flash --direct /opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin --verbose
ExecStartPost=${USER_HOME}/.venvs/sj201/bin/python /opt/sj201/init_tas5806
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable mark2-xvf3510-init.service
    log "mark2-xvf3510-init.service installed and enabled (system-level, Before=user@${USER_UID}.service)"

    # Disable the old user-scope sj201.service — replaced by mark2-xvf3510-init
    systemctl --user disable sj201.service 2>/dev/null || true
    systemctl --user stop   sj201.service 2>/dev/null || true

    section "Configuring PipeWire for SJ201"
    # Following the OVOS installer approach: no custom virtual PipeWire source.
    # WirePlumber's pro-audio profile exposes the XVF-3510 as
    # "Built-in Audio Pro 1" (alsa_input.platform-soc_sound.pro-input-1).
    # LVA uses this directly. The sj201-output.conf sink is still needed for audio out.
    mkdir -p "${USER_HOME}/.config/pipewire/pipewire.conf.d"
    cp "${SCRIPT_DIR}/assets/pipewire-sj201-output.conf" "${USER_HOME}/.config/pipewire/pipewire.conf.d/sj201-output.conf"
    log "PipeWire SJ201 Speaker sink installed"
    sudo cp "${SCRIPT_DIR}/lib/wait-pipewire.sh" /usr/local/bin/mark2-wait-pipewire
    sudo chmod +x /usr/local/bin/mark2-wait-pipewire
    log "PipeWire wait script installed: /usr/local/bin/mark2-wait-pipewire"
    sudo cp "${SCRIPT_DIR}/lib/mark2-reflash.sh" /usr/local/bin/mark2-reflash.sh
    sudo chmod +x /usr/local/bin/mark2-reflash.sh
    log "mark2-reflash.sh installed: /usr/local/bin/mark2-reflash.sh"
    cat > "${SYSTEMD_USER_DIR}/mark2-reflash.service" << EOF
[Unit]
Description=Re-flash XVF3510 after WirePlumber reset
Documentation=https://github.com/andlo/mark2-assist
After=wireplumber.service pipewire.service
Wants=wireplumber.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mark2-reflash.sh
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
EOF
    systemctl --user enable mark2-reflash.service 2>/dev/null || true
    log "mark2-reflash.service installed and enabled"
    systemctl --user stop pipewire.socket pipewire.service wireplumber.service 2>/dev/null || true
    sleep 1
    systemctl --user start pipewire.socket pipewire.service 2>/dev/null || true
    systemctl --user start wireplumber.service 2>/dev/null || true

    log "Waiting for SJ201 devices in PipeWire..."
    PW_OK=false
    for i in $(seq 1 15); do
        SPK=$(wpctl status 2>/dev/null | grep -c "SJ201 Speaker")
        SRC=$(wpctl status 2>/dev/null | grep -c "pro-input-1")
        if [ "$SPK" -gt 0 ] && [ "$SRC" -gt 0 ]; then
            log "PipeWire SJ201 devices ready after ${i}s ✓"
            PW_OK=true
            break
        fi
        sleep 1
    done
    if [ "$PW_OK" = false ]; then
        warn "PipeWire SJ201 devices not visible after 15s — audio may not work"
    fi

    section "Creating lva.service"
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "${SYSTEMD_USER_DIR}/lva.service" << EOF
[Unit]
Description=Linux Voice Assistant (ESPHome protocol) for Home Assistant
After=network-online.target mark2-reflash.service
Wants=network-online.target

[Service]
Type=simple
# Wait for PipeWire virtual devices before starting (wireplumber gives no ready signal)
ExecStartPre=/usr/local/bin/mark2-wait-pipewire
ExecStart=${LVA_DIR}/.venv/bin/python3 -m linux_voice_assistant \\
    --name '${SATELLITE_NAME}' \\
    --wake-model '${WAKE_WORD}' \\
    --audio-input-device 'Built-in Audio Pro 1' \\
    --audio-output-device 'pipewire/alsa_output.platform-soc_sound.pro-output-0'
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
    systemctl --user enable lva.service 2>/dev/null
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
    systemctl --user enable mark2-face-events.service 2>/dev/null
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
    systemctl --user enable mark2-volume-buttons.service 2>/dev/null
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
    cp "${TEMPLATE_DIR}/kiosk.html" "${KIOSK_DIR}/kiosk.html"
    log "Installed kiosk template → ${KIOSK_DIR}/kiosk.html"

    # ── mark2-httpd.py — local HTTP server on :8088 ──
    # Serves combined.html, splash.html, and proxies /ha/ to Home Assistant.
    # kiosk.sh starts this at boot; without it Chromium shows "site can't be reached".
    cp "${SCRIPT_DIR}/lib/mark2-httpd.py" "${USER_HOME}/mark2-httpd.py"
    chmod +x "${USER_HOME}/mark2-httpd.py"
    log "Installed ~/mark2-httpd.py"

    # ── kiosk.sh — main display launcher ──
    # Uses ${HOME} for paths — works with any username, not just pi.
    KIOSK_SCRIPT="${USER_HOME}/kiosk.sh"
    cp "${SCRIPT_DIR}/lib/kiosk.sh" "$KIOSK_SCRIPT"
    chmod +x "$KIOSK_SCRIPT"
    log "Installed ~/kiosk.sh"

    # ── hud.sh — HUD overlay launcher ──
    # Uses ${HOME} for paths — works with any username, not just pi.
    HUD_SCRIPT="${USER_HOME}/hud.sh"
    cp "${SCRIPT_DIR}/lib/hud.sh" "$HUD_SCRIPT"
    chmod +x "$HUD_SCRIPT"
    log "Installed ~/hud.sh"

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
    # Boot splash — covers kernel boot with Mark II branding
    log "Installing boot splash (Plymouth)..."
    sudo bash "${SCRIPT_DIR}/lib/install-plymouth.sh" \
        && log "Boot splash installed" \
        || warn "Boot splash install failed — rerun: sudo bash lib/install-plymouth.sh"

    log "Mark II Satellite + Kiosk setup complete!"
    echo ""
    echo "  Next steps:"
    echo ""
    echo "  1. Reboot the Mark II:"
    echo "     sudo reboot"
    echo ""
    echo "  2. In Home Assistant — add ESPHome device:"
    echo "     Settings → Devices & Services → Add Integration → ESPHome"
    echo "     Host: ${IP}   Port: 6053"
    echo "     (or wait for auto-discovery notification)"
    echo ""
    echo "  3. Set the voice pipeline (IMPORTANT — #9):"
    echo "     Settings → Voice Assistants → ${SATELLITE_NAME}"
    echo "     → Select pipeline (e.g. 'preferred', 'Whisper+Piper', 'Claude')"
    echo "     Without this step the satellite uses HA's default pipeline."
    echo ""
    echo "  4. Test: say '${WAKE_WORD}' and give a voice command."
    echo ""
    echo "  For auto-login on touchscreen without keyboard:"
    echo "  See README.md → Auto-login on the touchscreen"
    echo "========================================"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo "========================================"
echo "  Mark II Linux Voice Assistant + Kiosk"
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
install_lva
install_face_event_bridge
install_volume_buttons
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
