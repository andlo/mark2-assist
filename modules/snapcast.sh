#!/bin/bash
# =============================================================================
# modules/snapcast.sh
# Snapcast multiroom audio client
#
# Can be run standalone: bash modules/snapcast.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

section "Snapcast Client"
echo "  Snapcast turns Mark II into a synchronized multiroom audio endpoint."
echo "  Requires a Snapcast server already running on your network (or NAS/HA)."
echo "  In Home Assistant the 'Snapcast' integration shows Mark II as a media player."
echo ""

if ! ask_yes_no "Install Snapcast client?"; then
    log "Skipping Snapcast"
    exit 0
fi

SNAPCAST_HOST="${SNAPCAST_HOST:-}"
if [ -z "$SNAPCAST_HOST" ]; then
    read -rp "Snapcast server IP or hostname: " SNAPCAST_HOST
    [ -z "$SNAPCAST_HOST" ] && die "Snapcast server host required"
fi

section "Downloading Snapcast for Trixie (arm64, PipeWire)"

SNAPCAST_VERSION=$(curl -s https://api.github.com/repos/badaix/snapcast/releases/latest \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
[ -z "$SNAPCAST_VERSION" ] && { warn "Could not fetch latest version - using 0.35.0"; SNAPCAST_VERSION="0.35.0"; }
log "Snapcast version: ${SNAPCAST_VERSION}"

DEB_FILE="snapclient_${SNAPCAST_VERSION}-1_arm64_trixie_with-pipewire.deb"
DEB_URL="https://github.com/badaix/snapcast/releases/download/v${SNAPCAST_VERSION}/${DEB_FILE}"
TMP_DEB="/tmp/${DEB_FILE}"

curl -fsSL "$DEB_URL" -o "$TMP_DEB" || die "Failed to download: ${DEB_URL}"
sudo apt-get install -y --no-install-recommends avahi-daemon
sudo dpkg -i "$TMP_DEB" || sudo apt-get install -f -y
rm -f "$TMP_DEB"

# Disable system snapclient service - run as user instead
sudo systemctl disable --now snapclient.service 2>/dev/null || true

cat > "${SYSTEMD_USER_DIR}/snapclient.service" << EOF
[Unit]
Description=Snapcast Client
After=network-online.target pipewire.service wireplumber.service sj201.service
Wants=pipewire.service

[Service]
Type=simple
ExecStart=/usr/bin/snapclient \\
    --logsink=system \\
    --player pipewire \\
    --host ${SNAPCAST_HOST}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable snapclient.service
log "Snapcast client installed and enabled"
info "Mark II will appear in Home Assistant Snapcast integration"
info "Server: ${SNAPCAST_HOST}"
