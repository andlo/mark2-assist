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

RESUME_SERVICE="${SYSTEMD_USER_DIR}/mark2-install-resume.service"
RESUME_MARKER="${MARK2_DIR}/install-resume-pending"

install_resume_hook() {
    cat > "$RESUME_SERVICE" << EOF
[Unit]
Description=Mark II Assist - Resume installation after reboot
After=network-online.target
ConditionPathExists=${RESUME_MARKER}

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 3 && bash ${SCRIPT_DIR}/install.sh --resume'
ExecStartPost=/bin/rm -f ${RESUME_MARKER}
StandardInput=tty
TTYPath=/dev/tty1
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable mark2-install-resume.service
}

remove_resume_hook() {
    systemctl --user disable mark2-install-resume.service 2>/dev/null || true
    rm -f "$RESUME_SERVICE" "$RESUME_MARKER"
    systemctl --user daemon-reload
}

arm_resume() {
    # Called before reboot - marks that install should continue after boot
    install_resume_hook
    touch "$RESUME_MARKER"
    log "Auto-resume armed - installation will continue after reboot"
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
    if bash "$script"; then
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
            echo -e "${YELLOW}  Hardware setup complete. Rebooting to continue...${NC}"
            echo ""
            arm_resume
            sleep 3
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
echo "  1. Reboot:  sudo reboot"
echo "  2. Add Wyoming integration in Home Assistant:"
echo "       Settings > Devices > Add Integration > Wyoming Protocol"
echo "       Host: $(hostname -I | awk '{print $1}')   Port: 10700"
echo ""
echo "  Full documentation: https://github.com/andlo/mark2-assist"
echo ""
