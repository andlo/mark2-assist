#!/bin/bash
# =============================================================================
# install.sh — Mark II Assist installer
#
# Orchestrates the two-step install with automatic reboot handling.
# No prompts — all configuration done in HA UI after install.
#
# Usage:
#   ./install.sh
#
# Steps:
#   1. mark2-hardware-setup.sh  → SJ201 drivers, clocks, PipeWire profile
#      (reboot required)
#   2. mark2-satellite-setup.sh → LVA, face overlay, kiosk, audio-init service
#      (reboot to activate)
#   3. Optional modules         → snapcast, airplay, mpd, kdeconnect, usb-audio
# =============================================================================

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"

RESUME=false
for arg in "$@"; do
    case "$arg" in
        --resume) RESUME=true ;;
        --help|-h)
            echo "Usage: $0 [--resume]"
            echo "  Run without arguments for guided install."
            echo "  --resume: skip hardware step (use after reboot)"
            exit 0 ;;
    esac
done

check_not_root
setup_paths
config_load

# =============================================================================
# SUDOERS — one sudo prompt upfront, then silence
# =============================================================================
SUDOERS_MARK2="/etc/sudoers.d/mark2-user"
if [ ! -f "${SUDOERS_MARK2}" ]; then
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${CURRENT_USER}" \
        | sudo tee "${SUDOERS_MARK2}" > /dev/null
    sudo chmod 0440 "${SUDOERS_MARK2}"
    if ! sudo visudo -c -f "${SUDOERS_MARK2}" &>/dev/null; then
        echo "[WARN] sudoers rule failed validation — removing"
        sudo rm -f "${SUDOERS_MARK2}"
    fi
fi

# =============================================================================
# RESUME HOOK — print reminder on next SSH login after reboot
# =============================================================================

BASH_PROFILE="${USER_HOME}/.bash_profile"

install_resume_hook() {
    remove_resume_hook
    cat >> "$BASH_PROFILE" << 'HOOKEOF'

# mark2-install-resume
echo ""
echo "  Mark II install paused for reboot."
echo "  Hardware setup complete. Run to continue:"
echo "    cd mark2-assist && ./install.sh"
echo ""
HOOKEOF
}

remove_resume_hook() {
    [ -f "$BASH_PROFILE" ] && sed -i "/# mark2-install-resume/,\$d" "$BASH_PROFILE" || true
}

# =============================================================================
# BANNER + PROGRESS
# =============================================================================

print_banner() {
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   Mark II Assist — Installer         ║"
    echo "  ║   github.com/andlo/mark2-assist       ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""
    echo "  Turns your Mycroft Mark II into a Home Assistant"
    echo "  voice satellite with animated face + kiosk display."
    echo ""
}

print_progress() {
    local steps=("hardware" "satellite" "snapcast" "airplay" "mpd" "kdeconnect" "usb-audio")
    echo "  Installation progress:"
    for s in "${steps[@]}"; do
        local status
        status=$(progress_get "$s" 2>/dev/null || echo "pending")
        case "$status" in
            done)    echo "    ✓ ${s}" ;;
            skipped) echo "    - ${s} (skipped)" ;;
            failed)  echo "    ✗ ${s} (FAILED — check ${MARK2_LOG})" ;;
            *)       echo "    · ${s} (pending)" ;;
        esac
    done
    echo ""
}

# =============================================================================
# OPTIONAL MODULES — only the ones that still need config
# =============================================================================

select_optional_modules() {
    echo "  Optional modules (press Enter to skip any):"
    echo ""

    INSTALL_SNAPCAST=false
    INSTALL_AIRPLAY=false
    INSTALL_MPD=false
    INSTALL_KDECONNECT=false
    INSTALL_USB_AUDIO=false

    local ans
    read -rp "    Snapcast — synchronized multiroom audio? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] && INSTALL_SNAPCAST=true

    read -rp "    AirPlay  — Mark II as AirPlay speaker?   [y/N]: " ans
    [[ "${ans,,}" == "y" ]] && INSTALL_AIRPLAY=true

    read -rp "    MPD      — local music player?            [y/N]: " ans
    [[ "${ans,,}" == "y" ]] && INSTALL_MPD=true

    read -rp "    KDE Connect — Android integration?        [y/N]: " ans
    [[ "${ans,,}" == "y" ]] && INSTALL_KDECONNECT=true

    read -rp "    USB audio — fallback if SJ201 fails?      [y/N]: " ans
    [[ "${ans,,}" == "y" ]] && INSTALL_USB_AUDIO=true

    echo ""
}

run_module() {
    local name="$1" desc="$2" enabled="${3:-false}"
    [ "$enabled" != "true" ] && { progress_set "$name" "skipped"; return; }
    progress_is_done "$name" && { log "${name} already done — skipping"; return; }

    section "${desc}"
    if MARK2_MODULE_CONFIRMED=1 bash "${MODULES_DIR}/${name}.sh"; then
        progress_set "$name" "done"
    else
        progress_set "$name" "failed"
        warn "${name} failed — check ${MARK2_LOG}"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

print_banner

# Auto-detect resume: hardware done but satellite not yet
if ! $RESUME && progress_is_done "hardware" && ! progress_is_done "satellite"; then
    RESUME=true
fi

if $RESUME; then
    echo "  Resuming after reboot — hardware done ✓"
    echo ""
    print_progress

    # Offer hardware test
    local ans
    read -rp "  Run hardware test before continuing? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
        bash "${SCRIPT_DIR}/mark2-hardware-test.sh" || true
        echo ""
        read -rp "  Continue with satellite install? [Y/n]: " ans
        [[ "${ans,,}" == "n" ]] && { echo "  Cancelled."; exit 0; }
    fi

    remove_resume_hook
    config_load
else
    print_progress

    local ans
    read -rp "  Start installation? [Y/n]: " ans
    [[ "${ans,,}" == "n" ]] && { echo "Cancelled."; exit 0; }
    echo ""

    # Optional modules (only relevant ones — no HA URL, no MQTT)
    select_optional_modules

    # Snapcast needs server host
    if $INSTALL_SNAPCAST && [ -z "${SNAPCAST_HOST:-}" ]; then
        read -rp "  Snapcast server host/IP: " SNAPCAST_HOST
        config_save "SNAPCAST_HOST" "${SNAPCAST_HOST:-}"
    fi
fi

# =============================================================================
# STEP 1: HARDWARE
# =============================================================================

if progress_is_done "hardware"; then
    log "Hardware already installed — skipping"
else
    section "Step 1/2 — Hardware Drivers"
    if MARK2_MODULE_CONFIRMED=1 bash "${SCRIPT_DIR}/mark2-hardware-setup.sh"; then
        progress_set "hardware" "done"
        install_resume_hook
        echo ""
        echo "  ✓ Hardware setup complete. Reboot required."
        echo ""
        echo "  After reboot, log in and run:  ./mark2-assist/install.sh"
        echo ""
        read -rp "  Reboot now? [Y/n]: " ans
        [[ "${ans,,}" != "n" ]] && { log "Rebooting..."; sudo reboot; }
        exit 0
    else
        progress_set "hardware" "failed"
        warn "Hardware setup failed — check ${MARK2_LOG}"
    fi
fi

# =============================================================================
# STEP 2: SATELLITE + KIOSK
# =============================================================================

if progress_is_done "satellite"; then
    log "Satellite/Kiosk already installed — skipping"
else
    section "Step 2/2 — Linux Voice Assistant + Kiosk"
    if MARK2_MODULE_CONFIRMED=1 bash "${SCRIPT_DIR}/mark2-satellite-setup.sh"; then
        progress_set "satellite" "done"
    else
        progress_set "satellite" "failed"
        warn "Satellite setup failed — check ${MARK2_LOG}"
    fi
fi

# =============================================================================
# OPTIONAL MODULES
# =============================================================================

# Load selections from config if resuming
INSTALL_SNAPCAST="${INSTALL_SNAPCAST:-false}"
INSTALL_AIRPLAY="${INSTALL_AIRPLAY:-false}"
INSTALL_MPD="${INSTALL_MPD:-false}"
INSTALL_KDECONNECT="${INSTALL_KDECONNECT:-false}"
INSTALL_USB_AUDIO="${INSTALL_USB_AUDIO:-false}"

run_module "snapcast"   "Snapcast multiroom audio"  "$INSTALL_SNAPCAST"
run_module "airplay"    "AirPlay speaker"           "$INSTALL_AIRPLAY"
run_module "mpd"        "MPD local music player"    "$INSTALL_MPD"
run_module "kdeconnect" "KDE Connect (Android)"     "$INSTALL_KDECONNECT"
run_module "usb-audio"  "USB audio fallback"        "$INSTALL_USB_AUDIO"

# =============================================================================
# DONE
# =============================================================================

# Write /etc/mark2.conf for root-run scripts (motd, status)
sudo tee /etc/mark2.conf > /dev/null << CONFEOF
MARK2_USER=${CURRENT_USER}
MARK2_HOME=${USER_HOME}
CONFEOF

# Install MOTD and status command
if [ -f "${SCRIPT_DIR}/lib/motd.sh" ]; then
    sudo cp "${SCRIPT_DIR}/lib/motd.sh" /etc/update-motd.d/10-mark2
    sudo chmod +x /etc/update-motd.d/10-mark2
    sudo cp "${SCRIPT_DIR}/lib/status.sh" /usr/local/bin/mark2-status
    sudo chmod +x /usr/local/bin/mark2-status
    sudo rm -f /etc/update-motd.d/10-uname
    sudo truncate -s 0 /etc/motd
fi

MARK2_IP=$(hostname -I | awk '{print $1}')
print_progress

echo "  ✓ Installation complete!"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Reboot:  sudo reboot"
echo "  2. Touchscreen shows Home Assistant (homeassistant.local)"
echo "     If mDNS fails: echo 'HA_URL=http://x.x.x.x:8123' >> ~/.config/mark2/config"
echo "  3. In HA: Settings → Devices & Services → ESPHome → set pipeline"
echo "  4. Say 'okay nabu'"
echo ""
echo "  Docs: https://github.com/andlo/mark2-assist"
echo ""

read -rp "  Reboot now? [Y/n]: " ans
[[ "${ans,,}" != "n" ]] && { log "Rebooting..."; sleep 2; sudo reboot; }
