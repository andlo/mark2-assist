#!/bin/bash
# =============================================================================
# modules/airplay.sh
# AirPlay 1 receiver for the Mark II — makes it appear as a speaker on
# Apple devices and any AirPlay-compatible app (iTunes, iOS, macOS, etc.)
#
# Uses shairport-sync with PipeWire backend. Audio plays through the SJ201
# amplifier via the WirePlumber default sink.
#
# Note: AirPlay 2 is not supported by shairport-sync without a paid license.
# AirPlay 1 works with iOS, macOS, iTunes and most third-party AirPlay apps.
#
# Known issue: shairport-sync may log PipeWire timing warnings on Trixie.
# See KNOWN_ISSUES.md Issue 5 for details.
#
# Can be run standalone: bash modules/airplay.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "AirPlay Receiver" "Mark II as AirPlay speaker (AirPlay 1)"
echo ""

if ! confirm_or_skip "Install AirPlay receiver?"; then
    log "Skipping AirPlay"
    exit 0
fi

AIRPLAY_NAME="${AIRPLAY_NAME:-Mark II}"

sudo apt-get install -y --no-install-recommends \
    shairport-sync \
    avahi-daemon \
    libavahi-client3

SHAIRPORT_CONF="/etc/shairport-sync.conf"
sudo tee "$SHAIRPORT_CONF" > /dev/null << EOF
// shairport-sync configuration for Mark II
general = {
    name = "${AIRPLAY_NAME}";
    output_backend = "pw";
    mdns_backend = "avahi";
    allow_session_interruption = "yes";
    session_timeout = 20;
};

pw = {
    // Use default PipeWire sink (SJ201 via WirePlumber)
};

sessioncontrol = {
    allow_session_interruption = "yes";
    session_timeout = 20;
};
EOF
log "Created shairport-sync config: ${SHAIRPORT_CONF}"

# Fix dbus policy
DBUS_POLICY_DIR="/usr/share/dbus-1/system.d"
if [ ! -f "${DBUS_POLICY_DIR}/shairport-sync-dbus-policy.conf" ]; then
    sudo tee "${DBUS_POLICY_DIR}/shairport-sync-dbus-policy.conf" > /dev/null << EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="${CURRENT_USER}">
    <allow own="org.gnome.ShairportSync"/>
    <allow own="org.mpris.MediaPlayer2.ShairportSync"/>
  </policy>
</busconfig>
EOF
    sudo systemctl reload dbus 2>/dev/null || true
fi

cat > "${SYSTEMD_USER_DIR}/shairport-sync.service" << EOF
[Unit]
Description=AirPlay receiver (shairport-sync)
After=network-online.target pipewire.service wireplumber.service sj201.service
Wants=pipewire.service

[Service]
Type=simple
ExecStart=/usr/bin/shairport-sync
Restart=on-failure
RestartSec=10
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$CURRENT_USER")
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$CURRENT_USER")/bus

[Install]
WantedBy=default.target
EOF

sudo systemctl disable --now shairport-sync.service 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable shairport-sync.service

log "AirPlay receiver installed as user service"
info "Mark II will appear as '${AIRPLAY_NAME}' on your AirPlay devices"
