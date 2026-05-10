#!/bin/bash
# =============================================================================
# uninstall.sh — Mark II Assist uninstaller
#
# Removes all mark2-assist services, files and config so the device
# can be reinstalled cleanly without reflashing.
#
# Does NOT remove:
#   - apt packages (weston, chromium, pipewire etc.) — harmless to keep
#   - /boot/firmware/config.txt SJ201 overlays — requires reboot to undo
#   - VocalFusion kernel module build
#
# Usage:
#   ./uninstall.sh                  — full uninstall
#   ./uninstall.sh --keep-hardware  — keep SJ201/hardware config, remove rest
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

print_banner "Uninstaller"
echo "  This will remove all mark2-assist services and files."
[ "$KEEP_HARDWARE" = true ] && echo "  Hardware/SJ201 config will be kept (--keep-hardware)."
echo ""

if ! ask_yes_no "Are you sure you want to uninstall?"; then
    echo "Cancelled."
    exit 0
fi

# =============================================================================
# STOP AND DISABLE SERVICES
# =============================================================================

section "Stopping services"

USER_SERVICES=(
    lva
    mark2-audio-init
    mark2-face-events
    mark2-led-events
    mark2-volume-buttons
    snapclient
    shairport-sync
    mpd
    kdeconnect
    mark2-audio-fallback
)
[ "$KEEP_HARDWARE" = false ] && USER_SERVICES+=(sj201)

for svc in "${USER_SERVICES[@]}"; do
    systemctl --user stop    "$svc" 2>/dev/null || true
    systemctl --user disable "$svc" 2>/dev/null || true
    rm -f "${SYSTEMD_USER_DIR}/${svc}.service"
done

# System-level services
for svc in mark2-xvf3510-init; do
    sudo systemctl stop    "$svc" 2>/dev/null || true
    sudo systemctl disable "$svc" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${svc}.service"
done

systemctl --user daemon-reload 2>/dev/null || true
sudo systemctl daemon-reload
log "Services removed"

# =============================================================================
# KIOSK FILES
# =============================================================================

section "Removing kiosk files"

rm -f "${USER_HOME}/kiosk.sh"
rm -f "${USER_HOME}/startup.sh"
rm -f "${USER_HOME}/mark2-httpd.py"
rm -f "${USER_HOME}/mark2-assist/lib/mark2-xvf-post-wp.sh" 2>/dev/null || true
rm -rf "${USER_HOME}/.config/chromium-kiosk"
rm -rf "${USER_HOME}/.config/chromium-face"
rm -f /tmp/mark2-face-event.json
rm -f /tmp/mark2-kiosk-config.json

log "Kiosk files removed"

# =============================================================================
# LABWC CONFIG
# =============================================================================

section "Resetting labwc config"

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

BASH_PROFILE="${USER_HOME}/.bash_profile"
if [ -f "$BASH_PROFILE" ]; then
    # Remove Weston compositor block
    sed -i '/# Start W.*compositor\|# Start Weston/,/^fi$/d' "$BASH_PROFILE" 2>/dev/null || true
    # Remove install resume hook
    sed -i "/# mark2-install-resume/,\$d" "$BASH_PROFILE" 2>/dev/null || true
    log "Cleaned .bash_profile"
fi

# =============================================================================
# SYSTEM SCRIPTS + MOTD
# =============================================================================

section "Removing system scripts"

sudo rm -f /usr/local/bin/mark2-status
sudo rm -f /usr/local/bin/mark2-wait-pipewire
sudo rm -f /usr/local/bin/mark2-xvf-post-wp.sh
sudo rm -f /usr/local/bin/setup_mclk
sudo rm -f /usr/local/bin/setup_bclk
sudo rm -f /etc/update-motd.d/10-mark2
sudo rm -f /etc/mark2.conf
sudo rm -f /etc/sudoers.d/mark2-user

# Restore default uname MOTD
if [ ! -f /etc/update-motd.d/10-uname ]; then
    sudo tee /etc/update-motd.d/10-uname > /dev/null << 'EOF'
#!/bin/sh
uname -snrvm
EOF
    sudo chmod +x /etc/update-motd.d/10-uname
fi
sudo tee /etc/motd > /dev/null << 'EOF'

The programs included with the Debian GNU/Linux system are free software;
the exact distribution terms for each program are described in the
individual files in /usr/share/doc/*/copyright.

Debian GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent
permitted by applicable law.
EOF
log "System scripts removed, MOTD restored"

# =============================================================================
# WIREPLUMBER + PIPEWIRE CONFIG
# =============================================================================

if [ "$KEEP_HARDWARE" = false ]; then
    section "Removing audio config"
    rm -f "${USER_HOME}/.config/wireplumber/wireplumber.conf.d/90-sj201-profile.conf"
    rm -f "${USER_HOME}/.config/pipewire/pipewire.conf.d/sj201-output.conf"
    log "Audio config removed"
fi

# =============================================================================
# LVA
# =============================================================================

LVA_DIR="${USER_HOME}/lva"
if [ -d "$LVA_DIR" ]; then
    if ask_yes_no "Remove Linux Voice Assistant clone (~/lva)?"; then
        rm -rf "$LVA_DIR"
        log "LVA removed"
    else
        log "Keeping ~/lva"
    fi
fi

# =============================================================================
# MPD
# =============================================================================

if [ -f "${USER_HOME}/.config/mpd/mpd.conf" ]; then
    if ask_yes_no "Remove MPD configuration and playlists?"; then
        rm -rf "${USER_HOME}/.config/mpd"
        log "MPD config removed"
    fi
fi

# =============================================================================
# CONFIG + PROGRESS
# =============================================================================

if ask_yes_no "Remove saved config and install progress? (~/.config/mark2/)"; then
    if [ "$KEEP_HARDWARE" = true ]; then
        # Keep hardware=done so next install skips hardware step
        local hw
        hw=$(grep "^hardware=" "${MARK2_PROGRESS}" 2>/dev/null || true)
        rm -f "${MARK2_CONFIG}" "${MARK2_PROGRESS}"
        [ -n "$hw" ] && echo "$hw" > "${MARK2_PROGRESS}"
        log "Config removed — hardware progress kept"
    else
        rm -f "${MARK2_CONFIG}" "${MARK2_PROGRESS}"
        log "Config and progress removed"
    fi
else
    # Always reset install progress (except hardware if --keep-hardware)
    if [ "$KEEP_HARDWARE" = true ]; then
        local hw
        hw=$(grep "^hardware=" "${MARK2_PROGRESS}" 2>/dev/null || true)
        rm -f "${MARK2_PROGRESS}"
        [ -n "$hw" ] && echo "$hw" > "${MARK2_PROGRESS}"
    else
        rm -f "${MARK2_PROGRESS}"
    fi
    log "Install progress reset — keeping config"
fi

# =============================================================================
# DONE
# =============================================================================

echo ""
echo "  ✓ Uninstall complete."
echo ""
echo "  Note: apt packages and /boot/firmware/config.txt were not changed."
echo "  Reboot to restore original boot behaviour."
echo ""
echo "  To reinstall:  ./install.sh"
echo ""

if ask_yes_no "Reboot now?"; then
    sudo reboot
fi
