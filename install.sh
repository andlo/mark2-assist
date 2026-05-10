#!/bin/bash
# =============================================================================
# install.sh — Mark II Assist installer
#
# Two-step install with automatic reboot handling. No prompts.
#
# Usage:
#   ./install.sh
#
# Steps:
#   1. mark2-hardware-setup.sh  → SJ201 drivers, clocks, PipeWire profile
#      (reboot required)
#   2. mark2-satellite-setup.sh → LVA, face overlay, kiosk, audio-init service
#      (reboot to activate)
#
# Optional modules (Snapcast, AirPlay, MPD, KDE Connect) are managed via
# Home Assistant UI — see issue #31 for the planned mark2-manager service.
# In the meantime, install manually: bash modules/<name>.sh
# =============================================================================

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RESUME=false
for arg in "$@"; do
    case "$arg" in
        --resume) RESUME=true ;;
        --help|-h)
            echo "Usage: $0 [--resume]"
            echo "  --resume: continue after reboot (normally auto-detected)"
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
        echo "[WARN] sudoers rule failed — removing"
        sudo rm -f "${SUDOERS_MARK2}"
    fi
fi

# =============================================================================
# RESUME HOOK — reminder on next SSH login after reboot
# =============================================================================
BASH_PROFILE="${USER_HOME}/.bash_profile"

install_resume_hook() {
    remove_resume_hook
    cat >> "$BASH_PROFILE" << 'HOOKEOF'

# mark2-install-resume
CYAN='\033[0;36m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'
echo ""
echo -e "${CYAN}    __  ___           __      ________     ___              _      __ ${NC}"
echo -e "${CYAN}   /  |/  /___ ______/ /__   /  _/  _/    /   |  __________(_)____/ /_${NC}"
echo -e "${CYAN}  / /|_/ / __ \`/ ___/ //_/   / / / /     / /| | / ___/ ___/ / ___/ __/${NC}"
echo -e "${CYAN} / /  / / /_/ / /  / ,<    _/ /_/ /     / ___ |(__  |__  ) (__  ) /_  ${NC}"
echo -e "${CYAN}/_/  /_/\__,_/_/  /_/|_|  /___/___/    /_/  |_/____/____/_/____/\__/  ${NC}"
echo ""
echo -e "${GREEN}  Hardware done ✓  —  Step 1 of 2 complete${NC}"
echo ""
echo -e "  ${BLUE}Continue the install:${NC}"
echo -e "  ${CYAN}  cd ~/mark2-assist && ./install.sh${NC}"
echo ""
HOOKEOF
}

remove_resume_hook() {
    [ -f "$BASH_PROFILE" ] && sed -i "/# mark2-install-resume/,\$d" "$BASH_PROFILE" || true
}

# =============================================================================
# PROGRESS
# =============================================================================
print_progress() {
    echo "  Progress:"
    for step in hardware satellite; do
        s=$(progress_get "$step" 2>/dev/null || echo "pending")
        case "$s" in
            done)   echo "    ✓ ${step}" ;;
            failed) echo "    ✗ ${step} (failed — check ${MARK2_LOG})" ;;
            *)      echo "    · ${step} (pending)" ;;
        esac
    done
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
print_banner "Installer"

# Auto-detect resume: hardware done, satellite not yet
if ! $RESUME && progress_is_done "hardware" && ! progress_is_done "satellite"; then
    RESUME=true
fi

print_progress

if $RESUME; then
    echo "  Resuming after reboot — hardware done ✓"
    echo ""
    read -rp "  Run hardware test before continuing? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
        bash "${SCRIPT_DIR}/mark2-hardware-test.sh" || true
        echo ""
        read -rp "  Continue with satellite install? [Y/n]: " ans
        [[ "${ans,,}" == "n" ]] && { echo "Cancelled."; exit 0; }
    fi
    remove_resume_hook
else
    read -rp "  Start installation? [Y/n]: " ans
    [[ "${ans,,}" == "n" ]] && { echo "Cancelled."; exit 0; }
    echo ""
fi

# =============================================================================
# STEP 1: HARDWARE
# =============================================================================
if progress_is_done "hardware"; then
    log "Hardware already done — skipping"
else
    section "Step 1/2 — Hardware Drivers"
    if MARK2_MODULE_CONFIRMED=1 MARK2_CALLED_FROM_INSTALLER=1 bash "${SCRIPT_DIR}/mark2-hardware-setup.sh"; then
        progress_set "hardware" "done"
        install_resume_hook
        echo ""
        echo "  ✓ Hardware setup complete. Reboot required."
        echo ""
        echo "  After reboot, log in and run:  ./install.sh"
        echo ""
        ans=""
        read -rp "  Reboot now? [Y/n]: " ans
        [[ "${ans,,}" != "n" ]] && { sudo reboot; }
        exit 0
    else
        progress_set "hardware" "failed"
        warn "Hardware setup failed — check ${MARK2_LOG}"
        exit 1
    fi
fi

# =============================================================================
# STEP 2: SATELLITE + KIOSK
# =============================================================================
if progress_is_done "satellite"; then
    log "Satellite/Kiosk already done — skipping"
else
    section "Step 2/2 — Linux Voice Assistant + Kiosk"
    if MARK2_MODULE_CONFIRMED=1 MARK2_CALLED_FROM_INSTALLER=1 bash "${SCRIPT_DIR}/mark2-satellite-setup.sh"; then
        progress_set "satellite" "done"
    else
        progress_set "satellite" "failed"
        warn "Satellite setup failed — check ${MARK2_LOG}"
        exit 1
    fi
fi

# =============================================================================
# FINISH
# =============================================================================

# /etc/mark2.conf — lets root-run scripts find the install user
sudo tee /etc/mark2.conf > /dev/null << CONFEOF
MARK2_USER=${CURRENT_USER}
MARK2_HOME=${USER_HOME}
CONFEOF

# MOTD + status command
if [ -f "${SCRIPT_DIR}/lib/motd.sh" ]; then
    sudo cp "${SCRIPT_DIR}/lib/motd.sh"   /etc/update-motd.d/10-mark2
    sudo cp "${SCRIPT_DIR}/lib/status.sh" /usr/local/bin/mark2-status
    sudo chmod +x /etc/update-motd.d/10-mark2 /usr/local/bin/mark2-status
    sudo rm -f /etc/update-motd.d/10-uname
    sudo truncate -s 0 /etc/motd
fi

MARK2_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${CYAN}    __  ___           __      ________     ___              _      __ ${NC}"
echo -e "${CYAN}   /  |/  /___ ______/ /__   /  _/  _/    /   |  __________(_)____/ /_${NC}"
echo -e "${CYAN}  / /|_/ / __ \`/ ___/ //_/   / / / /     / /| | / ___/ ___/ / ___/ __/${NC}"
echo -e "${CYAN} / /  / / /_/ / /  / ,<    _/ /_/ /     / ___ |(__  |__  ) (__  ) /_  ${NC}"
echo -e "${CYAN}/_/  /_/\__,_/_/  /_/|_|  /___/___/    /_/  |_/____/____/_/____/\__/  ${NC}"
echo ""
echo -e "${GREEN}  ✓  Installation complete!${NC}"
echo ""
echo -e "${CYAN}  Next steps:${NC}"
echo ""
echo -e "  ${BLUE}1. Reboot (required):${NC}"
echo    "       sudo reboot"
echo ""
echo -e "  ${BLUE}2. Touchscreen opens Home Assistant${NC}"
echo    "     If mDNS fails, set your HA URL:"
echo    "       echo 'HA_URL=http://x.x.x.x:8123' >> ~/.config/mark2/config"
echo ""
echo -e "  ${BLUE}3. In Home Assistant:${NC}"
echo    "     Settings → Devices & Services → ESPHome → ${SATELLITE_NAME:-Nabu-1}"
echo    "     Set voice pipeline + wake word"
echo ""
echo -e "  ${BLUE}4. Say 'okay nabu' — done!${NC}"
echo ""
echo -e "  ${YELLOW}  Optional modules (Snapcast, AirPlay, MPD):${NC}"
echo    "     Coming via HA UI — see github.com/andlo/mark2-assist/issues/31"
echo    "     Manual: bash modules/<name>.sh"
echo ""

ans=""
read -rp "  Reboot now? [Y/n]: " ans
[[ "${ans,,}" != "n" ]] && { log "Rebooting..."; sleep 2; sudo reboot; }
