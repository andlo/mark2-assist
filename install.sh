#!/bin/bash
# =============================================================================
# install.sh
# Mark II Assist - Main installer wrapper
#
# Runs all setup scripts in the correct order with guidance between steps.
#
# Usage:
#   chmod +x install.sh
#   ./install.sh
#
# Or run individual scripts directly:
#   ./mark2-hardware-setup.sh
#   ./mark2-satellite-setup.sh
#   ./mark2-extras-setup.sh
#   ./mark2-advanced-setup.sh
# =============================================================================

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

print_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Mark II Assist - Installer         ║${NC}"
    echo -e "${CYAN}║  github.com/andlo/mark2-assist           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

print_step() {
    local num="$1"
    local title="$2"
    local desc="$3"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    echo -e "${CYAN} Step ${num}: ${title}${NC}"
    echo -e " ${desc}"
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    echo ""
}

wait_for_reboot() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║            REBOOT REQUIRED               ║${NC}"
    echo -e "${YELLOW}║                                          ║${NC}"
    echo -e "${YELLOW}║  Hardware drivers need a reboot to       ║${NC}"
    echo -e "${YELLOW}║  take effect before continuing.          ║${NC}"
    echo -e "${YELLOW}║                                          ║${NC}"
    echo -e "${YELLOW}║  After reboot, run this script again:    ║${NC}"
    echo -e "${YELLOW}║    ./install.sh --skip-hardware          ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "Rebooting in 10 seconds... (Ctrl+C to cancel)"
    sleep 10
    sudo reboot
}

# --- Parse arguments ---
SKIP_HARDWARE=false
SKIP_SATELLITE=false
ONLY_HARDWARE=false

for arg in "$@"; do
    case "$arg" in
        --skip-hardware)   SKIP_HARDWARE=true ;;
        --skip-satellite)  SKIP_SATELLITE=true ;;
        --only-hardware)   ONLY_HARDWARE=true ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --skip-hardware    Skip hardware setup (already done)"
            echo "  --skip-satellite   Skip satellite + kiosk setup"
            echo "  --only-hardware    Only run hardware setup then reboot"
            echo "  --help             Show this help"
            exit 0
            ;;
    esac
done

# --- Main ---
check_not_root
setup_paths

print_banner

echo "  This installer will set up your Mycroft Mark II as:"
echo "  · Wyoming voice satellite for Home Assistant"
echo "  · Home Assistant kiosk display"
echo "  · Multiroom audio endpoint"
echo ""
echo "  Scripts will run in order. Each step will explain"
echo "  what it does before proceeding."
echo ""

if ! ask_yes_no "Ready to begin?"; then
    echo "Cancelled."
    exit 0
fi

# =============================================================================
# STEP 1: HARDWARE DRIVERS
# =============================================================================

if [ "$SKIP_HARDWARE" = false ]; then
    print_step "1/4" "Hardware Drivers" \
        "Installs SJ201 audio drivers, VocalFusion kernel module,\n boot overlays and WirePlumber config.\n Requires a reboot when complete."

    if ask_yes_no "Run hardware setup?"; then
        bash "${SCRIPT_DIR}/mark2-hardware-setup.sh"

        if [ "$ONLY_HARDWARE" = true ]; then
            wait_for_reboot
        fi

        echo ""
        echo -e "${YELLOW}Hardware setup complete. A reboot is required.${NC}"
        echo ""
        if ask_yes_no "Reboot now? (You will need to re-run ./install.sh --skip-hardware after reboot)"; then
            wait_for_reboot
        else
            warn "Skipping reboot - note that audio may not work until you reboot"
        fi
    else
        warn "Skipping hardware setup - SJ201 audio may not work"
    fi
else
    log "Skipping hardware setup (--skip-hardware)"
fi

# =============================================================================
# STEP 2: WYOMING SATELLITE + KIOSK
# =============================================================================

if [ "$SKIP_SATELLITE" = false ]; then
    print_step "2/4" "Wyoming Satellite + HA Kiosk" \
        "Installs Wyoming voice satellite and openWakeWord.\n Sets up Chromium kiosk showing Home Assistant.\n Configures PipeWire media playback."

    if ask_yes_no "Run satellite + kiosk setup?"; then
        bash "${SCRIPT_DIR}/mark2-satellite-setup.sh"
    else
        warn "Skipping satellite setup"
    fi
else
    log "Skipping satellite setup (--skip-satellite)"
fi

# =============================================================================
# STEP 3: EXTRAS (OPTIONAL)
# =============================================================================

print_step "3/4" "Extra Audio Services (optional)" \
    "Snapcast multiroom client, AirPlay receiver,\n and clock/weather screensaver.\n Each module is prompted individually."

if ask_yes_no "Run extras setup?"; then
    bash "${SCRIPT_DIR}/mark2-extras-setup.sh"
else
    log "Skipping extras - you can run mark2-extras-setup.sh later"
fi

# =============================================================================
# STEP 4: ADVANCED FEATURES (OPTIONAL)
# =============================================================================

print_step "4/4" "Advanced Features (optional)" \
    "LED ring control, kernel watchdog, KDE Connect,\n MPD music player, USB audio fallback,\n and volume overlay.\n Each module is prompted individually."

if ask_yes_no "Run advanced setup?"; then
    bash "${SCRIPT_DIR}/mark2-advanced-setup.sh"
else
    log "Skipping advanced setup - you can run mark2-advanced-setup.sh later"
fi

# =============================================================================
# DONE
# =============================================================================

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Installation Complete!           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""
log "All selected modules installed."
echo ""
echo "  Next steps:"
echo "  1. Reboot:  sudo reboot"
echo "  2. Add Wyoming integration in Home Assistant:"
echo "       Settings > Devices > Add Integration > Wyoming Protocol"
echo "       Host: $(hostname -I | awk '{print $1}')   Port: 10700"
echo ""
echo "  Full documentation: https://github.com/andlo/mark2-assist"
echo ""
