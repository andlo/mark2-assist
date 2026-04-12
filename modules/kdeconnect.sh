#!/bin/bash
# =============================================================================
# modules/kdeconnect.sh
# KDE Connect — Android phone integration
#
# KDE Connect pairs Mark II with your Android phone and enables:
#   - Phone notifications shown on the Mark II display
#   - Media playback control from phone (pause/skip)
#   - Clipboard sharing between phone and Mark II
#   - Remote input (use phone as touchpad/keyboard)
#
# Requires the KDE Connect app on your Android phone:
#   - Play Store: https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp
#   - F-Droid: https://f-droid.org/packages/org.kde.kdeconnect_tp/
#
# iPhone is not supported (KDE Connect is Android only).
#
# After installation, pair from the KDE Connect app: tap "Find devices"
# and accept the pairing request on both devices.
#
# Ports 1714-1764 TCP/UDP are opened in ufw if the firewall is active.
#
# Can be run standalone: bash modules/kdeconnect.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "KDE Connect" "Android phone integration — notifications, media control, clipboard"
echo ""
echo "  Android: KDE Connect (Play Store / F-Droid)"
echo "  iPhone:  Not supported"
echo ""

if ! confirm_or_skip "Install KDE Connect?"; then
    log "Skipping KDE Connect"
    exit 0
fi

apt_install kdeconnect python3-requests

# Open firewall ports (if ufw is active)
if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "active"; then
    sudo ufw allow 1714:1764/tcp comment "KDE Connect"
    sudo ufw allow 1714:1764/udp comment "KDE Connect"
    log "Opened KDE Connect ports in ufw"
fi

systemctl --user enable kdeconnect.service 2>/dev/null || { 2>/dev/null
    cat > "${SYSTEMD_USER_DIR}/kdeconnect.service" << EOF
[Unit]
Description=KDE Connect
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/lib/kdeconnectd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload 2>/dev/null
    systemctl --user enable kdeconnect.service 2>/dev/null
}

log "KDE Connect installed"
info "Pair from your Android phone: KDE Connect app > Find devices"
info "Mark II will appear as: $(hostname)"
