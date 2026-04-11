#!/bin/bash
# =============================================================================
# install.sh
# Mark II Assist - Main installer
#
# Usage:
#   ./install.sh
#   ./install.sh --skip-hardware     (hardware already done, skip to satellite)
#
# Or run individual scripts directly:
#   ./mark2-hardware-setup.sh
#   ./mark2-satellite-setup.sh
#   bash modules/snapcast.sh
#   bash modules/airplay.sh
#   ... etc
# =============================================================================

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"

# --- Parse arguments ---
SKIP_HARDWARE=false
for arg in "$@"; do
    case "$arg" in
        --skip-hardware) SKIP_HARDWARE=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-hardware]"
            echo "  --skip-hardware   Skip hardware setup (already done + rebooted)"
            exit 0 ;;
    esac
done

check_not_root
setup_paths

# =============================================================================
# BANNER
# =============================================================================

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       Mark II Assist - Installer         ║${NC}"
echo -e "${CYAN}║  github.com/andlo/mark2-assist           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  Repurpose your Mycroft Mark II as:"
echo "  · Wyoming voice satellite for Home Assistant"
echo "  · Home Assistant kiosk display"
echo "  · Multiroom audio endpoint"
echo ""

if ! ask_yes_no "Ready to begin?"; then
    echo "Cancelled."
    exit 0
fi

# =============================================================================
# STEP 1: HARDWARE DRIVERS
# =============================================================================

if [ "$SKIP_HARDWARE" = false ]; then
    section "Step 1/3 — Hardware Drivers"
    echo "  Installs SJ201 audio drivers, VocalFusion kernel module,"
    echo "  boot overlays, WirePlumber config and kernel watchdog."
    echo "  A reboot is required after this step."
    echo ""

    if ask_yes_no "Run hardware setup?"; then
        bash "${SCRIPT_DIR}/mark2-hardware-setup.sh"
        echo ""
        echo -e "${YELLOW}  Hardware setup complete. A reboot is required before continuing.${NC}"
        echo ""
        if ask_yes_no "Reboot now? (re-run './install.sh --skip-hardware' after reboot)"; then
            echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
            sleep 5
            sudo reboot
        else
            warn "Skipping reboot - audio may not work until you reboot"
        fi
    else
        warn "Skipping hardware setup"
    fi
else
    log "Skipping hardware setup (--skip-hardware)"
fi

# =============================================================================
# STEP 2: WYOMING SATELLITE + KIOSK
# =============================================================================

section "Step 2/3 — Wyoming Satellite + HA Kiosk"
echo "  Installs Wyoming voice satellite and openWakeWord."
echo "  Sets up Chromium kiosk showing Home Assistant."
echo ""

if ask_yes_no "Run satellite + kiosk setup?"; then
    bash "${SCRIPT_DIR}/mark2-satellite-setup.sh"
else
    warn "Skipping satellite setup"
fi

# =============================================================================
# STEP 3: OPTIONAL MODULES
# =============================================================================

section "Step 3/3 — Optional Modules"
echo "  Each module can be installed individually."
echo "  All can also be run later: bash modules/<name>.sh"
echo ""

run_module() {
    local name="$1"
    local desc="$2"
    local script="${MODULES_DIR}/${name}.sh"
    echo ""
    echo -e "${CYAN}  ── ${desc}${NC}"
    if ask_yes_no "  Install?"; then
        bash "$script"
    else
        log "Skipping ${name}"
    fi
}

run_module "snapcast"   "Snapcast client — synchronized multiroom audio"
run_module "airplay"    "AirPlay receiver — Mark II as AirPlay speaker"
run_module "screensaver" "Screensaver — fullscreen clock + weather"
run_module "leds"       "LED ring control — visual Wyoming feedback"
run_module "mpd"        "MPD — local music player (HA / Music Assistant)"
run_module "kdeconnect" "KDE Connect — Android phone integration"
run_module "usb-audio"  "USB audio fallback — auto-switch if SJ201 fails"
run_module "overlay"    "Volume overlay — on-screen status display"

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
