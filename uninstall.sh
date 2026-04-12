#!/bin/bash
# =============================================================================
# uninstall.sh
# Mark II Assist — Uninstaller
#
# Removes all mark2-assist installed files and services so the device
# can be re-installed cleanly without reflashing.
#
# Does NOT remove:
#   - apt packages (weston, labwc, chromium, pipewire, etc.) — harmless to keep
#   - VocalFusion kernel module / SJ201 hardware config — requires reboot
#     to undo and is safe to keep
#   - Wyoming satellite/openwakeword git clones (optional, asked)
#   - /boot/firmware/config.txt overlays
#
# Usage:
#   ./uninstall.sh                  — full uninstall
#   ./uninstall.sh --keep-hardware  — keep sj201/hardware, remove rest
# =============================================================================

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

check_not_root
setup_paths

KEEP_HARDWARE=false
for arg in "$@"; do
    [[ "$arg" == "--keep-hardware" ]] && KEEP_HARDWARE=true
done

# =============================================================================
# BANNER
# =============================================================================

clear
echo -e "${RED}"
echo '    __  ___           __      ________     ___              _      __ '
echo '   /  |/  /___ ______/ /__   /  _/  _/    /   |  __________(_)____/ /_'
echo '  / /|_/ / __ `/ ___/ //_/   / / / /     / /| | / ___/ ___/ / ___/ __/'
echo ' / /  / / /_/ / /  / ,<    _/ /_/ /     / ___ |(__  |__  ) (__  ) /_  '
echo '/_/  /_/\__,_/_/  /_/|_|  /___/___/    /_/  |_/____/____/_/____/\__/  '
echo -e "${NC}"
echo -e "${RED}  Uninstaller — this will remove all mark2-assist components${NC}"
echo ""

if ! ask_yes_no "Are you sure you want to uninstall Mark II Assist?"; then
    echo "Cancelled."
    exit 0
fi

# =============================================================================
# STOP AND DISABLE SERVICES
# =============================================================================

section "Stopping and disabling services"

USER_SERVICES=(
    wyoming-satellite
    wyoming-openwakeword
    ha-kiosk
    mark2-leds
    mark2-led-events
    mark2-face-bridge
    mark2-face-events
    mark2-volume-monitor
    mark2-mqtt-bridge
    mark2-mpd-watcher
    snapclient
    shairport-sync
    mpd
    kdeconnect
    mark2-audio-fallback
)

# Only remove hardware services if not keeping hardware setup
if [ "$KEEP_HARDWARE" = false ]; then
    USER_SERVICES+=(sj201)
fi

SYSTEM_SERVICES=(
    mark2-vocalfusion-watchdog
)

for svc in "${USER_SERVICES[@]}"; do
    if systemctl --user is-active "$svc" 2>/dev/null | grep -q "active"; then
        systemctl --user stop "$svc" 2>/dev/null && info "Stopped: $svc" || true
    fi
    if systemctl --user is-enabled "$svc" 2>/dev/null | grep -q "enabled"; then
        systemctl --user disable "$svc" 2>/dev/null && info "Disabled: $svc" || true
    fi
    rm -f "${SYSTEMD_USER_DIR}/${svc}.service"
done

for svc in "${SYSTEM_SERVICES[@]}"; do
    if sudo systemctl is-active "$svc" 2>/dev/null | grep -q "active"; then
        sudo systemctl stop "$svc" 2>/dev/null || true
    fi
    sudo systemctl disable "$svc" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${svc}.service"
done

systemctl --user daemon-reload
sudo systemctl daemon-reload
log "Services removed"

# =============================================================================
# KIOSK + HUD
# =============================================================================

section "Removing kiosk and HUD files"

rm -f "${USER_HOME}/kiosk.sh"
rm -f "${USER_HOME}/hud.sh"
rm -f "${USER_HOME}/startup.sh"
rm -rf "${USER_HOME}/.config/mark2-kiosk"
rm -rf "${USER_HOME}/.config/mark2-overlay"
rm -rf "${USER_HOME}/.config/mark2-screensaver"
rm -rf "${USER_HOME}/.config/mark2-face"
rm -f /tmp/mark2-*.json
rm -f /tmp/mark2-*.sock

log "Kiosk files removed"

# =============================================================================
# LABWC CONFIG
# =============================================================================

section "Cleaning labwc configuration"

LABWC_AUTOSTART="${USER_HOME}/.config/labwc/autostart"
if [ -f "$LABWC_AUTOSTART" ]; then
    # Remove all mark2-related entries
    grep -v "kiosk.sh\|hud.sh\|swayidle\|overlay.html\|face.html\|screensaver" \
        "$LABWC_AUTOSTART" > /tmp/labwc_clean || true
    mv /tmp/labwc_clean "$LABWC_AUTOSTART"
    log "Cleaned labwc autostart"
fi

# Remove labwc rc.xml (we created it, restore to minimal)
LABWC_RC="${USER_HOME}/.config/labwc/rc.xml"
if [ -f "$LABWC_RC" ]; then
    cat > "$LABWC_RC" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<labwc_config>
  <core>
    <decoration>client</decoration>
  </core>
</labwc_config>
EOF
    log "Reset labwc rc.xml"
fi

# =============================================================================
# AUTO-LOGIN
# =============================================================================

section "Removing auto-login"

GETTY_CONF="/etc/systemd/system/getty@tty1.service.d/autologin.conf"
if [ -f "$GETTY_CONF" ]; then
    sudo rm -f "$GETTY_CONF"
    sudo rmdir "/etc/systemd/system/getty@tty1.service.d" 2>/dev/null || true
    sudo systemctl daemon-reload
    log "Removed getty auto-login"
fi

section "Removing Weston autostart from .bash_profile"

BASH_PROFILE="${USER_HOME}/.bash_profile"
if grep -q "weston\|labwc" "$BASH_PROFILE" 2>/dev/null; then
    # Remove the Weston/labwc compositor block (everything from the comment to closing 'fi')
    sed -i '/# Start W.*compositor\|# Start labwc\|# Start Weston/,/^fi$/d' "$BASH_PROFILE" || true
    log "Removed compositor autostart from .bash_profile"
fi

# Remove install resume hook if present
if grep -q "mark2-install-resume" "$BASH_PROFILE" 2>/dev/null; then
    sed -i "/# mark2-install-resume/,\$d" "$BASH_PROFILE"
    log "Removed install resume hook from .bash_profile"
fi

# =============================================================================
# SYSTEM SCRIPTS
# =============================================================================

section "Removing system scripts"

sudo rm -f /usr/local/bin/mark2-audio-switch
sudo rm -f /usr/local/bin/mark2-overlay
sudo rm -f /usr/local/bin/mark2-mqtt-bridge
sudo rm -f /usr/local/bin/mark2-mpd-watcher
sudo rm -f /etc/cron.d/mark2-updates

log "System scripts removed"

# =============================================================================
# WIREPLUMBER CONFIG
# =============================================================================

section "Removing WirePlumber SJ201 config"
if [ "$KEEP_HARDWARE" = false ]; then
    rm -f "${USER_HOME}/.config/wireplumber/wireplumber.conf.d/90-sj201-profile.conf"
    log "WirePlumber config removed"
else
    log "Keeping WirePlumber SJ201 config (--keep-hardware)"
fi

# =============================================================================
# MPD CONFIG
# =============================================================================

if [ -f "${USER_HOME}/.config/mpd/mpd.conf" ]; then
    if ask_yes_no "Remove MPD configuration and playlists?"; then
        rm -rf "${USER_HOME}/.config/mpd"
        log "MPD config removed"
    fi
fi

# =============================================================================
# WYOMING CLONES
# =============================================================================

WYOMING_SAT_DIR="${USER_HOME}/wyoming-satellite"
WYOMING_OWW_DIR="${USER_HOME}/wyoming-openwakeword"

if [ -d "$WYOMING_SAT_DIR" ] || [ -d "$WYOMING_OWW_DIR" ]; then
    if ask_yes_no "Remove Wyoming satellite and openWakeWord clones?"; then
        rm -rf "$WYOMING_SAT_DIR" "$WYOMING_OWW_DIR"
        log "Wyoming clones removed"
    else
        log "Keeping Wyoming clones"
    fi
fi

# =============================================================================
# MARK2 CONFIG AND PROGRESS
# =============================================================================

if ask_yes_no "Remove saved config (HA URL, token, MQTT credentials) and install progress?"; then
    rm -f "${MARK2_CONFIG}"
    if [ "$KEEP_HARDWARE" = true ]; then
        # Keep hardware=done so next install skips hardware setup
        grep "^hardware=" "${MARK2_PROGRESS}" > /tmp/mark2_hw_tmp 2>/dev/null || true
        rm -f "${MARK2_PROGRESS}"
        mv /tmp/mark2_hw_tmp "${MARK2_PROGRESS}" 2>/dev/null || true
        log "Config removed — hardware progress kept"
    else
        rm -f "${MARK2_PROGRESS}"
        log "Config and progress removed"
    fi
    info "Next install will ask for HA URL, token etc. again"
else
    log "Keeping config — next install will reuse saved values"
    if [ "$KEEP_HARDWARE" = true ]; then
        # Reset all except hardware
        grep "^hardware=" "${MARK2_PROGRESS}" > /tmp/mark2_hw_tmp 2>/dev/null || true
        rm -f "${MARK2_PROGRESS}"
        mv /tmp/mark2_hw_tmp "${MARK2_PROGRESS}" 2>/dev/null || true
    else
        rm -f "${MARK2_PROGRESS}"
    fi
    log "Install progress reset — all steps will run on next install"
fi

# Keep MARK2_DIR itself but clean out scripts
rm -f "${MARK2_DIR}/led_control.py"
rm -f "${MARK2_DIR}/led_event_handler.py"
rm -f "${MARK2_DIR}/face-event-bridge.py"
rm -f "${MARK2_DIR}/audio-fallback.sh"
rm -f "${MARK2_DIR}/face-bridge.sh"
rm -f "${MARK2_DIR}/volume-monitor.sh"
rm -f "${MARK2_DIR}/rebuild-vocalfusion.sh"
rm -f "${MARK2_DIR}/safe-update.sh"

# =============================================================================
# SWAYIDLE CONFIG
# =============================================================================

rm -f "${USER_HOME}/.config/swayidle/config"

# =============================================================================
# DONE
# =============================================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Uninstall complete!                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
log "Mark II Assist has been removed."
echo ""
echo "  To reinstall from scratch:"
echo "    ./install.sh"
echo ""
echo "  Note: apt packages (weston, labwc, chromium, pipewire etc.) were kept."
echo "  Note: SJ201 hardware config in /boot/firmware/config.txt was kept."
echo "        A reboot will restore the original boot behaviour."
echo ""

if ask_yes_no "Reboot now?"; then
    sudo reboot
fi
