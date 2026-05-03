#!/bin/bash
# mark2-audio-init
# KEY INSIGHT: XVF3510 requires active I2S playback stream for stable BCLK/MCLK.
# Without playback, XVF3510 capture stops after ~250ms.
# PipeWire/WirePlumber must NOT be running when we start aplay directly.
set -euo pipefail

log() { echo "[mark2-audio-init] $*"; }

VENV="$(getent passwd "$(id -un)" | cut -d: -f6)/.venvs/sj201"
UID_NUM="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus"
export PULSE_RUNTIME_PATH="/run/user/${UID_NUM}/pulse"

log "Stopping ALL audio (including auto-started PipeWire)..."
systemctl --user stop lva.service 2>/dev/null || true
systemctl --user stop wireplumber.service 2>/dev/null || true
systemctl --user stop pipewire-pulse.service pipewire-pulse.socket 2>/dev/null || true
systemctl --user stop pipewire.service pipewire.socket 2>/dev/null || true
pkill -f 'aplay.*sj201\|aplay.*zero' 2>/dev/null || true
sleep 2

# Verify hw:sj201,0 is free
if fuser /dev/snd/pcmC1D0p >/dev/null 2>&1; then
    log "WARNING: hw:sj201,0 still busy after stop"
fi

# Start silent I2S playback DIRECTLY via ALSA (no PipeWire)
log "Starting silent ALSA playback on hw:sj201,0..."
aplay -D hw:sj201,0 -f S32_LE -r 48000 -c 2 /dev/zero 2>/dev/null &
APLAY_PID=$!
sleep 1

log "Flashing XVF3510 with I2S clock active..."
"${VENV}/bin/python" /opt/sj201/xvf3510-flash --direct /opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin
"${VENV}/bin/python" /opt/sj201/init_tas5806
log "Flash done — waiting 3s..."
sleep 3

# Test ALSA capture stability
timeout 3 arecord -D hw:sj201,1 -f S32_LE -r 48000 -c 2 /tmp/init_test.wav 2>/dev/null || true
RMS=$(sox /tmp/init_test.wav -n stat 2>&1 | grep 'RMS amplitude' | awk '{print $3}' 2>/dev/null || echo "0")
log "ALSA direct RMS: ${RMS}"

# Stop ALSA playback — PipeWire will take over
log "Stopping ALSA playback..."
kill $APLAY_PID 2>/dev/null || true
wait $APLAY_PID 2>/dev/null || true
sleep 1

# Start PipeWire stack — module-alsa-source will open hw:sj201,1
log "Starting PipeWire stack..."
systemctl --user start pipewire.socket pipewire.service
systemctl --user start pipewire-pulse.socket pipewire-pulse.service
systemctl --user start wireplumber.service
sleep 4

log "Starting LVA..."
systemctl --user start lva.service
log "Done"
