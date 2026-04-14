#!/bin/bash
# =============================================================================
# install.sh
# Mark II Assist - Main installer
#
# All questions are asked upfront before any installation begins.
# Installation then runs automatically without further interaction.
#
# Usage:
#   ./install.sh
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
            echo "Usage: $0"
            echo "  Run without arguments for guided install."
            exit 0 ;;
    esac
done

check_not_root
setup_paths
config_load

# =============================================================================
# RESUME HOOK
# =============================================================================

BASH_PROFILE="${USER_HOME}/.bash_profile"
RESUME_HOOK_MARKER="# mark2-install-resume"

install_resume_hook() {
    remove_resume_hook  # ensure no duplicate
    cat >> "$BASH_PROFILE" << 'HOOKEOF'

# mark2-install-resume
echo ""
echo -e "\033[0;36m╔══════════════════════════════════════════╗\033[0m"
echo -e "\033[0;36m║   Mark II installation paused            ║\033[0m"
echo -e "\033[0;36m║   Hardware setup complete ✓              ║\033[0m"
echo -e "\033[0;36m║   Reboot done ✓                          ║\033[0m"
echo -e "\033[0;36m║   Run to continue:                       ║\033[0m"
echo -e "\033[0;36m║     ./mark2-assist/install.sh            ║\033[0m"
echo -e "\033[0;36m╚══════════════════════════════════════════╝\033[0m"
echo ""
HOOKEOF
}

remove_resume_hook() {
    if [ -f "$BASH_PROFILE" ]; then
        sed -i "/# mark2-install-resume/,\$d" "$BASH_PROFILE"
        # Also clean up any stray fi/echo lines left from old hooks
        sed -i '/^fi$/d' "$BASH_PROFILE"
        sed -i '/^echo -e.*mark2\|╔\|╚\|║/d' "$BASH_PROFILE"
    fi
}

# =============================================================================
# BANNER
# =============================================================================

print_banner() {
    clear
    echo -e "${CYAN}"
    echo '    __  ___           __      ________     ___              _      __ '
    echo '   /  |/  /___ ______/ /__   /  _/  _/    /   |  __________(_)____/ /_'
    echo '  / /|_/ / __ `/ ___/ //_/   / / / /     / /| | / ___/ ___/ / ___/ __/'
    echo ' / /  / / /_/ / /  / ,<    _/ /_/ /     / ___ |(__  |__  ) (__  ) /_  '
    echo '/_/  /_/\__,_/_/  /_/|_|  /___/___/    /_/  |_/____/____/_/____/\__/  '
    echo -e "${NC}"
    echo -e "${BLUE}  Welcome to the Mark II Assist installer${NC}"
    echo -e "${BLUE}  github.com/andlo/mark2-assist${NC}"
    echo ""
    echo -e "  Repurpose your Mycroft Mark II as:"
    echo -e "  · Linux Voice Assistant (ESPHome) for Home Assistant"
    echo -e "  · Home Assistant kiosk display (animated face + HUD)"
    echo -e "  · Multiroom audio endpoint (Snapcast + AirPlay)"
    echo -e "  · MQTT sensor device"
    echo ""
}

# =============================================================================
# PROGRESS SUMMARY
# =============================================================================

print_progress() {
    local all=("hardware" "satellite"
               "homeassistant"
               "ui"
               "mqtt-sensors"
               "snapcast" "airplay" "mpd"
               "kdeconnect" "usb-audio")
    echo ""
    echo -e "${CYAN}  Installation progress:${NC}"
    for m in "${all[@]}"; do
        local status
        status=$(progress_get "$m")
        case "$status" in
            done)    echo -e "    ${GREEN}✓${NC} ${m}" ;;
            skipped) echo -e "    ${BLUE}-${NC} ${m} (skipped)" ;;
            failed)  echo -e "    ${RED}✗${NC} ${m} (failed)" ;;
            *)       echo -e "    ${YELLOW}·${NC} ${m} (pending)" ;;
        esac
    done
    echo ""
}

# =============================================================================
# UPFRONT CONFIGURATION — all questions asked before installation starts
# =============================================================================

configure_upfront() {
    # ── Step 1: Module selection ──
    local defaults="ui mqtt-sensors homeassistant"
    local mod_list=("homeassistant"
                    "ui"
                    "mqtt-sensors"
                    "snapcast" "airplay" "mpd"
                    "kdeconnect" "usb-audio")
    local mod_desc=(
        "Home Assistant dashboard on touchscreen"
        "UI — face, clock+weather, LEDs, volume buttons"
        "MQTT sensors — LVA/CPU/MPD state to HA"
        "Snapcast — synchronized multiroom audio"
        "AirPlay — Mark II as AirPlay speaker"
        "MPD — local music player (Music Assistant)"
        "KDE Connect — Android phone integration"
        "USB audio — fallback if SJ201 fails"
    )

    local items=()
    for i in "${!mod_list[@]}"; do
        local m="${mod_list[$i]}"
        local state="OFF"
        if progress_is_done "$m"; then
            state="ON"
        elif echo "$defaults" | grep -qw "$m"; then
            state="ON"
        fi
        items+=("$m" "${mod_desc[$i]}" "$state")
    done

    # Calculate dialog dimensions from terminal size
    local term_lines term_cols
    term_lines=$(tput lines 2>/dev/null || echo 24)
    term_cols=$(tput cols 2>/dev/null || echo 80)
    local dlg_h=$(( term_lines - 4 ))
    local dlg_w=$(( term_cols - 6 ))
    local list_h=$(( dlg_h - 8 ))
    [ "$dlg_h" -lt 20 ] && dlg_h=20
    [ "$dlg_w" -lt 60 ] && dlg_w=60
    [ "$list_h" -lt 8 ]  && list_h=8

    SELECTED_MODULES=$(whiptail --title "Mark II Assist — Select modules" \
        --checklist "Choose what to install:\n(Space to toggle, Enter to confirm)" \
        "$dlg_h" "$dlg_w" "$list_h" \
        "${items[@]}" \
        3>&1 1>&2 2>&3) || { warn "Cancelled"; exit 0; }
    SELECTED_MODULES=$(echo "$SELECTED_MODULES" | tr -d '"')
    export SELECTED_MODULES
    # Save module selection so it survives reboot
    config_save "SELECTED_MODULES" "$SELECTED_MODULES"

    # ── Step 2: Home Assistant URL ──
    # Always asked upfront — used by kiosk, screensaver, MQTT sensors etc.
    prompt_ha_url

    # ── Step 3: HA token (only if screensaver selected) ──
    if echo "$SELECTED_MODULES" | grep -qw "screensaver" || echo "$SELECTED_MODULES" | grep -qw "ui"; then
        prompt_ha_token
        prompt_ha_weather
    fi

    # ── Step 4: MQTT credentials (only if mqtt-sensors selected) ──
    if echo "$SELECTED_MODULES" | grep -qw "mqtt-sensors"; then
        config_load
        MQTT_HOST="${MQTT_HOST:-}"
        if [ -z "$MQTT_HOST" ]; then
            MQTT_HOST=$(ask_input "MQTT broker host/IP" "192.168.1.100") \
                || die "MQTT host required"
            config_save "MQTT_HOST" "$MQTT_HOST"
        else
            log "Using saved MQTT host: ${MQTT_HOST}"
        fi
        MQTT_PORT="${MQTT_PORT:-1883}"
        _p=$(ask_input "MQTT port" "$MQTT_PORT") && MQTT_PORT="${_p:-1883}"
        config_save "MQTT_PORT" "$MQTT_PORT"
        MQTT_USER="${MQTT_USER:-}"
        if ask_yes_no "Does your MQTT broker require authentication?"; then
            MQTT_USER=$(ask_input "MQTT username" "$MQTT_USER") || true
            MQTT_PASS=$(ask_password "MQTT password") || true
            config_save "MQTT_USER" "$MQTT_USER"
            config_save "MQTT_PASS" "${MQTT_PASS:-}"
        fi
        export MQTT_HOST MQTT_PORT MQTT_USER
    fi

    # ── Step 5: Snapcast host (only if snapcast selected) ──
    if echo "$SELECTED_MODULES" | grep -qw "snapcast"; then
        config_load
        SNAPCAST_HOST="${SNAPCAST_HOST:-}"
        if [ -z "$SNAPCAST_HOST" ]; then
            SNAPCAST_HOST=$(ask_input "Snapcast server host/IP" "192.168.1.100") \
                || die "Snapcast host required"
            config_save "SNAPCAST_HOST" "$SNAPCAST_HOST"
        else
            log "Using saved Snapcast host: ${SNAPCAST_HOST}"
        fi
        export SNAPCAST_HOST
    fi

    # ── Step 6: Confirmation summary ──
    local summary="Ready to install:\n\n"
    summary+="  Home Assistant: ${HA_URL}\n"
    if progress_is_done "hardware"; then
        summary+="  Hardware:       already done ✓\n"
    else
        summary+="  Hardware:       will install + reboot\n"
    fi
    if progress_is_done "satellite"; then
        summary+="  Satellite/Kiosk: already done ✓\n"
    else
        summary+="  Satellite/Kiosk: will install\n"
    fi
    summary+="\n  Modules to install:\n"
    for mod in $SELECTED_MODULES; do
        summary+="    · ${mod}\n"
    done
    summary+="\nInstallation will run without further prompts."

    if ! whiptail --title "Mark II Assist — Confirm" \
        --yesno "$summary" $(( term_lines - 2 )) $(( term_cols - 6 )); then
        echo "Cancelled."
        exit 0
    fi
}

# =============================================================================
# MODULE RUNNER
# =============================================================================

run_module() {
    local name="$1"
    local desc="$2"
    local script="${MODULES_DIR}/${name}.sh"

    if [ -n "$SELECTED_MODULES" ] && \
       ! echo "$SELECTED_MODULES" | grep -qw "$name"; then
        progress_set "$name" "skipped"
        return
    fi

    if progress_is_done "$name"; then
        log "${name} already installed — skipping"
        return
    fi

    section "${desc}"
    _log_write "----" "=== Starting module: ${name} ==="
    if MARK2_MODULE_CONFIRMED=1 bash "$script"; then
        progress_set "$name" "done"
    else
        progress_set "$name" "failed"
        warn "${name} finished with errors — check ${MARK2_LOG}"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

print_banner

# Auto-detect resume after reboot
if [ "$RESUME" = false ] && \
   progress_is_done "hardware" && ! progress_is_done "satellite"; then
    RESUME=true
fi

if [ "$RESUME" = true ]; then
    print_progress
    echo -e "${CYAN}  Resuming installation after reboot.${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} Hardware drivers installed"
    echo -e "  ${GREEN}✓${NC} Reboot complete"
    echo ""

    # Offer hardware test before continuing
    echo -e "  ${YELLOW}Recommended:${NC} Run hardware test to verify all components"
    echo "  before proceeding with satellite/kiosk installation."
    echo ""
    read -rp "  Run hardware test now? (recommended) [Y/n]: " _hw_test_ans
    if [[ "${_hw_test_ans,,}" != "n" ]]; then
        bash "${SCRIPT_DIR}/mark2-hardware-test.sh" || true
        echo ""
        read -rp "  Continue with installation? [Y/n]: " _hw_cont_ans
        if [[ "${_hw_cont_ans,,}" == "n" ]]; then
            echo "  Cancelled. Fix hardware issues and re-run ./install.sh"
            exit 0
        fi
    fi

    echo ""
    remove_resume_hook
    config_load
    SELECTED_MODULES="${SELECTED_MODULES:-screensaver leds overlay face mqtt-sensors}"
else
    print_progress
    _ans=""
    read -rp "  Continue installation? [Y/n]: " _ans
    [[ "${_ans,,}" == "n" ]] && { echo "Cancelled."; exit 0; }
    echo ""

    # Ask everything upfront
    configure_upfront
fi

# =============================================================================
# STEP 1: HARDWARE
# =============================================================================

if progress_is_done "hardware"; then
    log "Hardware already installed — skipping"
else
    section "Step 1/3 — Hardware Drivers"
    show_info "Starting hardware setup...\n\nThis will install SJ201 drivers and reboot." 8 60
    _log_write "----" "=== Starting: hardware ==="
    if MARK2_MODULE_CONFIRMED=1 bash "${SCRIPT_DIR}/mark2-hardware-setup.sh"; then
        progress_set "hardware" "done"
        install_resume_hook
        echo ""
        echo -e "${GREEN}  ✓ Hardware setup complete!${NC}"
        echo ""
        echo "  The device needs to reboot to activate the drivers."
        echo "  After reboot, log in again and run:"
        echo ""
        echo -e "    ${CYAN}./mark2-assist/install.sh${NC}"
        echo ""
        read -rp "  Reboot now? [Y/n]: " _hw_reboot
        if [[ "${_hw_reboot,,}" != "n" ]]; then
            log "Rebooting after hardware setup..."
            sudo reboot
        fi
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
    section "Step 2/3 — Linux Voice Assistant + HA Kiosk"
    _log_write "----" "=== Starting: satellite ==="
    if MARK2_MODULE_CONFIRMED=1 bash "${SCRIPT_DIR}/mark2-satellite-setup.sh"; then
        progress_set "satellite" "done"
    else
        progress_set "satellite" "failed"
        warn "Satellite setup failed — check ${MARK2_LOG}"
    fi
fi

# =============================================================================
# STEP 3: OPTIONAL MODULES
# =============================================================================

section "Step 3/3 — Optional Modules"

configure_ha_trusted_network() {
    section "Configuring HA auto-login (trusted_networks)"
    setup_paths
    config_load

    local HA_URL="${HA_URL:-}"
    local HA_TOKEN="${HA_TOKEN:-}"
    local MARK2_IP
    MARK2_IP=$(hostname -I | awk '{print $1}')

    if [ -z "$HA_URL" ] || [ -z "$HA_TOKEN" ]; then
        warn "HA_URL or HA_TOKEN not set — skipping auto-login setup"
        return 0
    fi

    # Check if trusted_networks is already configured via API
    local HA_USER_ID
    HA_USER_ID=$(curl -sf \
        -H "Authorization: Bearer ${HA_TOKEN}" \
        -H "Content-Type: application/json" \
        "${HA_URL}/api/config" 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('external_url','?'))" 2>/dev/null || true)

    info "To enable auto-login on the touchscreen, add this to your"
    info "Home Assistant configuration.yaml and restart HA:"
    echo ""
    echo "  homeassistant:"
    echo "    auth_providers:"
    echo "      - type: homeassistant"
    echo "      - type: trusted_networks"
    echo "        trusted_networks:"
    echo "          - ${MARK2_IP}"
    echo "        allow_bypass_login: true"
    echo ""
    info "See: https://www.home-assistant.io/docs/authentication/providers/#trusted-networks"
    config_save "MARK2_IP" "$MARK2_IP"
}
run_module "homeassistant"  "Home Assistant dashboard — show HA on touchscreen"
run_module "ui"           "Mark II UI — display, LEDs, buttons, boot splash"
run_module "mqtt-sensors" "MQTT sensors — publish LVA/MPD/system state to HA"
run_module "snapcast"     "Snapcast — synchronized multiroom audio endpoint"
run_module "airplay"      "AirPlay — Mark II as AirPlay 1 speaker"
run_module "mpd"          "MPD — local music player (Music Assistant / HA)"
run_module "kdeconnect"   "KDE Connect — Android phone notifications + media"
run_module "usb-audio"    "USB audio — auto-fallback if SJ201 fails at boot"

# =============================================================================
# DONE
# =============================================================================

clear
print_banner
print_progress

log "Installation complete. Log: ${MARK2_LOG}"
echo ""
MARK2_IP=$(hostname -I | awk '{print $1}')
SUMMARY_FILE="${MARK2_DIR}/install-summary.txt"

# Build summary — shown on screen AND saved to file for later reference
print_summary() {
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  LVA auto-discovers in HA as an ESPHome device:${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Settings → Devices and Services → ESPHome → select pipeline"
echo "  Host: ${MARK2_IP}   Port: 10700"
echo ""

if echo "${SELECTED_MODULES:-}" | grep -qw "homeassistant"; then
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Auto-login — add to configuration.yaml in HA:${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  homeassistant:"
    echo "    auth_providers:"
    echo "      - type: homeassistant"
    echo "      - type: trusted_networks"
    echo "        trusted_networks:"
    echo "          - ${MARK2_IP}"
    echo "        trusted_users:"
    echo "          ${MARK2_IP}:"
    echo "            - <YOUR_HA_USER_ID>   # Settings → People → click user → ID in URL"
    echo "        allow_bypass_login: true"
    echo ""
    echo "  Then restart Home Assistant."
    echo ""
fi
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo "  Full documentation: https://github.com/andlo/mark2-assist"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  To show this summary again:"
echo "    cat ${SUMMARY_FILE}"
echo ""
}

# Print to screen
print_summary

# Save plain-text version (without color codes) for later reference
{
echo "Mark II Assist — Installation Summary"
echo "Installed: $(date)"
echo ""
echo "LVA auto-discovers in HA as an ESPHome device."
echo "  Settings → Devices & Services → ESPHome → select pipeline"
echo "  Host: ${MARK2_IP}   Port: 10700"
echo ""
if echo "${SELECTED_MODULES:-}" | grep -qw "homeassistant"; then
    echo "Auto-login — add to configuration.yaml in HA:"
    echo ""
    echo "  homeassistant:"
    echo "    auth_providers:"
    echo "      - type: homeassistant"
    echo "      - type: trusted_networks"
    echo "        trusted_networks:"
    echo "          - ${MARK2_IP}"
    echo "        trusted_users:"
    echo "          ${MARK2_IP}:"
    echo "            - <YOUR_HA_USER_ID>   # Settings → People → click user → ID in URL"
    echo "        allow_bypass_login: true"
    echo ""
    echo "  Then restart Home Assistant."
    echo ""
fi
echo "Full documentation: https://github.com/andlo/mark2-assist"
} > "$SUMMARY_FILE"

# Install MOTD banner (shows on every SSH login)
if [ -f "${SCRIPT_DIR}/lib/motd.sh" ]; then
    sudo cp "${SCRIPT_DIR}/lib/motd.sh" /etc/update-motd.d/10-mark2
    sudo chmod +x /etc/update-motd.d/10-mark2
    sudo cp "${SCRIPT_DIR}/lib/status.sh" /usr/local/bin/mark2-status
    sudo chmod +x /usr/local/bin/mark2-status
    sudo cp "${SCRIPT_DIR}/lib/wait-pipewire.sh" /usr/local/bin/mark2-wait-pipewire
    sudo chmod +x /usr/local/bin/mark2-wait-pipewire
    # Remove old default uname motd if it exists
    sudo rm -f /etc/update-motd.d/10-uname
    # Clear static /etc/motd — dynamic scripts handle it
    sudo truncate -s 0 /etc/motd
    log "Installed MOTD banner"
fi

# Remove any old bash_profile install summary snippet
BASH_PROFILE="${USER_HOME}/.bash_profile"
sed -i '/# mark2-install-summary/,/# mark2-install-summary-end/d' \
    "$BASH_PROFILE" 2>/dev/null || true

# Ask reboot in plain terminal (not whiptail) so summary stays visible
echo ""
read -rp "  Reboot now to activate all installed services? [Y/n]: " _reboot_ans
if [[ "${_reboot_ans,,}" != "n" ]]; then
    log "Rebooting..."
    sleep 2
    sudo reboot
fi
