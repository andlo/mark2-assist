#!/bin/bash
# =============================================================================
# modules/kdeconnect.sh
# KDE Connect - phone integration
#
# Can be run standalone: bash modules/kdeconnect.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

section "KDE Connect"
echo "  Pairs Mark II with your Android phone for:"
echo "  · Phone notifications shown on Mark II screen"
echo "  · Media playback control from phone"
echo "  · Clipboard sync between phone and Pi"
echo "  · Use phone as touchpad/keyboard for Mark II"
echo ""
echo "  Android: KDE Connect (Play Store / F-Droid)"
echo "  iPhone:  Not supported"
echo ""

if ! confirm_or_skip "Install KDE Connect?"; then
    log "Skipping KDE Connect"
    exit 0
fi

sudo apt-get install -y --no-install-recommends \
    kdeconnect \
    python3-requests

# Open firewall ports (if ufw is active)
if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "active"; then
    sudo ufw allow 1714:1764/tcp comment "KDE Connect"
    sudo ufw allow 1714:1764/udp comment "KDE Connect"
    log "Opened KDE Connect ports in ufw"
fi

systemctl --user enable kdeconnect.service 2>/dev/null || {
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
    systemctl --user daemon-reload
    systemctl --user enable kdeconnect.service
}

log "KDE Connect installed"
info "Pair from your Android phone: KDE Connect app > Find devices"
info "Mark II will appear as: $(hostname)"
