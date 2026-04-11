#!/bin/bash
# =============================================================================
# modules/mpd.sh
# Music Player Daemon - local music + HA/Music Assistant integration
#
# Can be run standalone: bash modules/mpd.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

section "MPD - Music Player Daemon"
echo "  Local music player that integrates with:"
echo "  · Home Assistant media player entity"
echo "  · Music Assistant (streams local files and radio)"
echo "  · Snapcast (if installed - MPD feeds audio to Snapcast)"
echo ""

if ! confirm_or_skip "Install MPD?"; then
    log "Skipping MPD"
    exit 0
fi

sudo apt-get install -y --no-install-recommends \
    mpd \
    mpc \
    ncmpc

MPD_CONF_DIR="${USER_HOME}/.config/mpd"
MPD_DB="${USER_HOME}/.local/share/mpd"
MPD_MUSIC="${USER_HOME}/Music"
MPD_PLAYLISTS="${MPD_CONF_DIR}/playlists"
mkdir -p "$MPD_CONF_DIR" "$MPD_DB" "$MPD_MUSIC" "$MPD_PLAYLISTS"

# Check if Snapcast fifo exists
SNAPCAST_FIFO=""
if [ -p "/tmp/snapfifo" ]; then
    SNAPCAST_FIFO="/tmp/snapfifo"
    info "Found Snapcast FIFO - MPD will feed audio to Snapcast"
fi

cat > "${MPD_CONF_DIR}/mpd.conf" << EOF
# Mark II MPD configuration
music_directory     "${MPD_MUSIC}"
playlist_directory  "${MPD_PLAYLISTS}"
db_file             "${MPD_DB}/database"
log_file            "${MPD_DB}/log"
pid_file            "${MPD_DB}/pid"
state_file          "${MPD_DB}/state"
sticker_file        "${MPD_DB}/sticker.sql"

bind_to_address     "0.0.0.0"
port                "6600"

restore_paused      "yes"
auto_update         "yes"

audio_output {
    type            "pipewire"
    name            "Mark II Speakers"
}
EOF

if [ -n "$SNAPCAST_FIFO" ]; then
    cat >> "${MPD_CONF_DIR}/mpd.conf" << 'EOF'

audio_output {
    type            "fifo"
    name            "Snapcast"
    path            "/tmp/snapfifo"
    format          "48000:16:2"
    mixer_type      "software"
}
EOF
fi

cat >> "${MPD_CONF_DIR}/mpd.conf" << 'EOF'

audio_output {
    type            "httpd"
    name            "Mark II Stream"
    encoder         "lame"
    port            "8000"
    bitrate         "192"
    format          "44100:16:2"
    always_on       "yes"
}
EOF

# Disable system MPD, run as user service
sudo systemctl disable --now mpd.service 2>/dev/null || true
sudo systemctl disable --now mpd.socket 2>/dev/null || true

cat > "${SYSTEMD_USER_DIR}/mpd.service" << EOF
[Unit]
Description=Music Player Daemon
After=pipewire.service wireplumber.service sj201.service
Wants=pipewire.service

[Service]
Type=notify
ExecStart=/usr/bin/mpd --no-daemon ${MPD_CONF_DIR}/mpd.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable mpd.service

log "MPD installed"
info "Music directory: ${MPD_MUSIC}"
info "HTTP stream: http://$(hostname -I | awk '{print $1}'):8000"
info "HA/Music Assistant: connect to $(hostname -I | awk '{print $1}'):6600"
