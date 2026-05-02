#!/bin/bash
# ExecStartPost on wireplumber.service
# WirePlumber resets XVF3510 on open — we reflash after it settles,
# stopping pipewire-pulse first so module-alsa-source re-opens AFTER flash.
set -euo pipefail

log() { echo "[mark2-xvf-post-wp] $*"; }

VENV="$(getent passwd "$(id -un)" | cut -d: -f6)/.venvs/sj201"
UID_NUM="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus"

# Wait for WirePlumber to open and reset XVF3510
log "Waiting 7s for WirePlumber DSP reset..."
sleep 7

# Stop pipewire-pulse so module-alsa-source releases hw:sj201,1
log "Stopping pipewire-pulse..."
systemctl --user stop pipewire-pulse.service pipewire-pulse.socket 2>/dev/null || true
sleep 1

# Flash XVF3510
log "Flashing XVF3510..."
"${VENV}/bin/python" /opt/sj201/xvf3510-flash --direct /opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin
"${VENV}/bin/python" /opt/sj201/init_tas5806
log "Reflash done"

# Restart pipewire-pulse — module-alsa-source now opens fresh chip
log "Starting pipewire-pulse..."
systemctl --user start pipewire-pulse.socket pipewire-pulse.service
sleep 3

# Start LVA
log "Starting LVA..."
systemctl --user start lva.service
log "Done"
