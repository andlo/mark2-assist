#!/bin/bash
# mark2-reflash.sh — Re-flash XVF3510 after WirePlumber has opened and reset
# the DSP pipeline via ACP pro-audio initialization.
#
# WHY THIS IS NEEDED:
# WirePlumber resets the XVF3510 chip's DSP pipeline when it opens hw:sj201,1
# via the ACP (Audio Card Profile) pro-audio profile. This happens every boot,
# regardless of when xvf3510-flash runs. The only reliable fix is to:
#   1. Wait for WirePlumber to finish its init (so the reset has already happened)
#   2. Stop WirePlumber (releases hw:sj201,1)
#   3. Re-flash XVF3510 (restores DSP pipeline)
#   4. Restart WirePlumber (opens with correct params, DSP pipeline intact)
#
# Run as: systemd user service (mark2-reflash.service)
# After:  wireplumber.service pipewire.service
set -euo pipefail

log() { echo "[mark2-reflash] $*"; }

VENV="$(getent passwd "$(id -un)" | cut -d: -f6)/.venvs/sj201"

log "Waiting for WirePlumber to open hw:sj201,1..."
for i in $(seq 1 30); do
    if wpctl status 2>/dev/null | grep -q "pro-input-1"; then
        log "pro-input-1 visible after ${i}s — WirePlumber has reset XVF3510"
        break
    fi
    sleep 1
done

# Give WirePlumber a moment to fully settle after opening the device
sleep 2

log "Stopping WirePlumber to release hw:sj201,1..."
systemctl --user stop wireplumber.service

# Wait for ALSA device to be released
for i in $(seq 1 10); do
    PARAMS=$(cat /proc/asound/card1/pcm1c/sub0/hw_params 2>/dev/null || echo "closed")
    if [ "$PARAMS" = "closed" ]; then
        log "hw:sj201,1 released after ${i}s"
        break
    fi
    sleep 1
done

log "Flashing XVF3510..."
"${VENV}/bin/python" /opt/sj201/xvf3510-flash --direct /opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin --verbose

log "Init TAS5806..."
"${VENV}/bin/python" /opt/sj201/init_tas5806

log "Starting WirePlumber..."
systemctl --user start wireplumber.service

# Wait for WirePlumber to re-open and XVF3510 to be ready
sleep 3

log "Testing signal via PipeWire..."
timeout 4 pw-record --target='alsa_input.platform-soc_sound.pro-input-1' \
    --format=s16 --rate=16000 --channels=1 /tmp/reflash_test.wav 2>/dev/null || true
RMS=$(sox /tmp/reflash_test.wav -n stat 2>&1 | grep "RMS amplitude" | awk '{print $3}' || echo "unknown")
log "PipeWire RMS after reflash: ${RMS}"

log "Done"
