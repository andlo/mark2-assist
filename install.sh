#!/bin/bash
# =============================================================================
# install.sh
# Mark II Assist - Main installer
#
# Usage:
#   ./install.sh              # Full guided install
#   ./install.sh --resume     # Resume after reboot (called automatically)
#
# Or run individual scripts directly:
#   ./mark2-hardware-setup.sh
#   ./mark2-satellite-setup.sh
#   bash modules/snapcast.sh
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
            echo "  --resume   Resume after reboot (set up automatically)"
            exit 0 ;;
    esac
done

check_not_root
setup_paths
config_load

# =============================================================================
# RESUME SERVICE - set up auto-continue after reboot
# =============================================================================

BASH_PROFILE="${USER_HOME}/.bash_profile"
RESUME_HOOK_MARKER="# mark2-install-resume"

install_resume_hook() {
    # Add a notice to .bash_profile that shows on next SSH login
    remove_resume_hook  # ensure no duplicate
    cat >> "$BASH_PROFILE" << EOF

${RESUME_HOOK_MARKER}
echo ""
echo -e "\033[0;36m╔══════════════════════════════════════════╗\033[0m"
echo -e "\033[0;36m║   Mark II installation paused            ║\033[0m"
echo -e "\033[0;36m║                                          ║\033[0m"
echo -e "\033[0;36m║   Hardware setup complete ✓              ║\033[0m"
echo -e "\033[0;36m║   Reboot done ✓                          ║\033[0m"
echo -e "\033[0;36m║                                          ║\033[0m"
echo -e "\033[0;36m║   Run to continue:                       ║\033[0m"
echo -e "\033[0;36m║     ./mark2-assist/install.sh --resume   ║\033[0m"
echo -e "\033[0;36m╚══════════════════════════════════════════╝\033[0m"
echo ""
EOF
    log "Resume notice added to ~/.bash_profile"
}

remove_resume_hook() {
    if [ -f "$BASH_PROFILE" ]; then
        # Remove everything from our marker to end of file
        sed -i "/${RESUME_HOOK_MARKER}/,\$d" "$BASH_PROFILE"
    fi
}

# =============================================================================
# BANNER
# =============================================================================

print_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Mark II Assist - Installer         ║${NC}"
    echo -e "${CYAN}║  github.com/andlo/mark2-assist           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

# =============================================================================
# PROGRESS SUMMARY
# =============================================================================

print_progress() {
    local modules=("hardware" "satellite" "snapcast" "airplay" "screensaver" "leds" "mpd" "kdeconnect" "usb-audio" "overlay")
    echo ""
    echo -e "${CYAN}  Installation progress:${NC}"
    for m in "${modules[@]}"; do
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
# MODULE RUNNER
# =============================================================================

run_module() {
    local name="$1"
    local desc="$2"
    local script="${MODULES_DIR}/${name}.sh"

    echo ""
    echo -e "${CYAN}  ── ${desc}${NC}"

    if progress_is_done "$name"; then
        echo -e "    ${GREEN}Already installed${NC} — reinstall?"
        if ! ask_yes_no "  Reinstall ${name}?"; then
            log "Skipping ${name} (already done)"
            return
        fi
    else
        if ! ask_yes_no "  Install?"; then
            progress_set "$name" "skipped"
            log "Skipping ${name}"
            return
        fi
    fi

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

if [ "$RESUME" = true ]; then
    echo -e "${CYAN}  Resuming installation after reboot...${NC}"
    remove_resume_hook
else
    echo "  Repurpose your Mycroft Mark II as:"
    echo "  · Wyoming voice satellite for Home Assistant"
    echo "  · Home Assistant kiosk display"
    echo "  · Multiroom audio endpoint"
    echo ""
fi

print_progress

if [ "$RESUME" = false ] && ! ask_yes_no "Ready to begin?"; then
    echo "Cancelled."
    exit 0
fi

# Collect HA URL up front so all modules can reuse it
section "Configuration"
prompt_ha_url

# =============================================================================
# STEP 1: HARDWARE
# =============================================================================

if progress_is_done "hardware"; then
    section "Step 1/3 — Hardware Drivers"
    echo -e "  ${GREEN}Already completed.${NC}"
    if ask_yes_no "  Re-run hardware setup?"; then
        progress_set "hardware" ""
    fi
fi

if ! progress_is_done "hardware"; then
    section "Step 1/3 — Hardware Drivers"
    echo "  Installs SJ201 audio drivers, VocalFusion kernel module,"
    echo "  boot overlays, WirePlumber config and kernel watchdog."
    echo "  A reboot is required after this step."
    echo ""

    if ask_yes_no "Run hardware setup?"; then
        _log_write "----" "=== Starting: hardware ==="
        if bash "${SCRIPT_DIR}/mark2-hardware-setup.sh"; then
            progress_set "hardware" "done"
            echo ""
            echo -e "${YELLOW}  Hardware setup complete. Rebooting in 5 seconds...${NC}"
            echo ""
            install_resume_hook
            sleep 5
            sudo reboot
            exit 0
        else
            progress_set "hardware" "failed"
            warn "Hardware setup failed — check ${MARK2_LOG}"
        fi
    else
        progress_set "hardware" "skipped"
        warn "Skipping hardware setup"
    fi
fi

# =============================================================================
# STEP 2: SATELLITE + KIOSK
# =============================================================================

if progress_is_done "satellite"; then
    section "Step 2/3 — Wyoming Satellite + HA Kiosk"
    echo -e "  ${GREEN}Already completed.${NC}"
    if ask_yes_no "  Re-run satellite setup?"; then
        progress_set "satellite" ""
    fi
fi

if ! progress_is_done "satellite"; then
    section "Step 2/3 — Wyoming Satellite + HA Kiosk"
    echo "  Installs Wyoming voice satellite and openWakeWord."
    echo "  Sets up Chromium kiosk showing Home Assistant."
    echo ""

    if ask_yes_no "Run satellite + kiosk setup?"; then
        _log_write "----" "=== Starting: satellite ==="
        if bash "${SCRIPT_DIR}/mark2-satellite-setup.sh"; then
            progress_set "satellite" "done"
        else
            progress_set "satellite" "failed"
            warn "Satellite setup failed — check ${MARK2_LOG}"
        fi
    else
        progress_set "satellite" "skipped"
        warn "Skipping satellite setup"
    fi
fi

# =============================================================================
# STEP 3: OPTIONAL MODULES
# =============================================================================

section "Step 3/3 — Optional Modules"
echo "  Each module can be installed individually."
echo "  Already completed modules will be skipped unless you choose to reinstall."
echo ""

run_module "snapcast"    "Snapcast client — synchronized multiroom audio"
run_module "airplay"     "AirPlay receiver — Mark II as AirPlay speaker"
run_module "screensaver" "Screensaver — fullscreen clock + weather"
run_module "leds"        "LED ring control — visual Wyoming feedback"
run_module "mpd"         "MPD — local music player (HA / Music Assistant)"
run_module "kdeconnect"  "KDE Connect — Android phone integration"
run_module "usb-audio"   "USB audio fallback — auto-switch if SJ201 fails"
run_module "overlay"     "Volume overlay — on-screen status display"

# =============================================================================
# DONE
# =============================================================================

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Installation Complete!           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""
print_progress

log "All selected modules installed. Log: ${MARK2_LOG}"
echo ""
echo "  Next steps:"
echo "  1. Add Wyoming integration in Home Assistant:"
echo "       Settings > Devices > Add Integration > Wyoming Protocol"
echo "       Host: $(hostname -I | awk '{print $1}')   Port: 10700"
echo ""
echo "  Full documentation: https://github.com/andlo/mark2-assist"
echo ""

if ask_yes_no "Reboot now to activate all installed services?"; then
    log "Rebooting..."
    sleep 2
    sudo reboot
fi
