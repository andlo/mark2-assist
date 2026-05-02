#!/bin/bash
# mark2-reflash.sh — Re-flash XVF3510 after WirePlumber has reset the DSP pipeline.
#
# ROOT CAUSE:
# WirePlumber resets the XVF3510 DSP pipeline on EVERY open of hw:sj201,1
# via ACP pro-audio profile. There is no way to prevent this.
#
# SOLUTION:
# 1. Let WirePlumber do its reset (it will happen regardless)
# 2. Stop WirePlumber + PipeWire stack completely
# 3. Re-flash XVF3510 (hw_params must be closed)
# 4. Start PipeWire + pipewire-pulse WITHOUT WirePlumber
#    → module-alsa-source in pipewire-pulse.conf.d opens hw:sj201,1 directly
#    → WirePlumber never opens capture side again
# 5. Start WirePlumber AFTER pipewire-pulse is running
#    → WirePlumber handles output (pro-output-0) only
#    → capture is already claimed by module-alsa-source, WP cannot reset it
#
# LVA uses: --audio-input-device 'ALSA Source on hw:sj201,1'
#
# Run as: systemd user service (mark2-reflash.service)
# After:  wireplumber.service pipewire.service
set -euo pipefail

log() { echo "[mark2-reflash] $*"; }

VENV="$(getent passwd "$(id -un)" | cut -d: -f6)/.venvs/sj201"
HW_PARAMS=/proc/asound/card1/pcm1c/sub0/hw_params

log "Waiting for WirePlumber to initialize SJ201 (pro-input-1)..."
for i in $(seq 1 30); do
    if wpctl status 2>/dev/null | grep -q "pro-input-1"; then
        log "pro-input-1 visible after ${i}s — WirePlumber reset complete"
        break
    fi
    sleep 1
done

# Wait for WirePlumber's ACP DSP reset to fully complete
log "Waiting 5s for DSP reset to settle..."
sleep 5

log "Stopping LVA and full PipeWire stack..."
systemctl --user stop lva.service 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire-pulse.socket pipewire.service pipewire.socket

# Verify hw:sj201,1 is fully released
log "Waiting for hw:sj201,1 to be released..."
for i in $(seq 1 15); do
    PARAMS=$(cat "$HW_PARAMS" 2>/dev/null || echo "closed")
    if [ "$PARAMS" = "closed" ]; then
        log "hw:sj201,1 released after ${i}s"
        break
    fi
    sleep 1
done
log "hw_params before flash: $(cat "$HW_PARAMS" 2>/dev/null || echo 'closed')"

log "Flashing XVF3510..."
"${VENV}/bin/python" /opt/sj201/xvf3510-flash --direct /opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin --verbose

log "Init TAS5806..."
"${VENV}/bin/python" /opt/sj201/init_tas5806

# Start PipeWire + pipewire-pulse WITHOUT WirePlumber first.
# module-alsa-source will claim hw:sj201,1 before WirePlumber can reset it.
log "Starting PipeWire + pipewire-pulse (without WirePlumber)..."
systemctl --user start pipewire.socket pipewire.service pipewire-pulse.socket pipewire-pulse.service

# Wait for module-alsa-source to claim hw:sj201,1
log "Waiting for module-alsa-source to open hw:sj201,1..."
for i in $(seq 1 10); do
    PARAMS=$(cat "$HW_PARAMS" 2>/dev/null || echo "closed")
    if [ "$PARAMS" != "closed" ]; then
        log "hw:sj201,1 claimed by pipewire-pulse after ${i}s"
        break
    fi
    sleep 1
done

# Now start WirePlumber — capture is already claimed, it can only handle output
log "Starting WirePlumber (output only)..."
systemctl --user start wireplumber.service
sleep 2

log "Testing signal via soundcard/PulseAudio..."
VENV_LVA="$(getent passwd "$(id -un)" | cut -d: -f6)/lva/.venv"
RMS=$("${VENV_LVA}/bin/python3" -c "
import sys, math
sys.argv = ['test', 'dummy']
import soundcard as sc
try:
    mic = sc.get_microphone('ALSA Source on hw:sj201,1')
    with mic.recorder(samplerate=16000, channels=1, blocksize=1600) as r:
        data = r.record(numframes=16000)
    rms = math.sqrt(sum(x**2 for x in data.flatten()) / len(data.flatten()))
    print(f'{rms:.6f}')
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null || echo "unknown")
log "PulseAudio RMS after reflash: ${RMS}"

systemctl --user start lva.service &
log "LVA started"
log "Done"
