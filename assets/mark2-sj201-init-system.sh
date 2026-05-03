#!/bin/bash
# Runs as root BEFORE user session / PipeWire starts.
# MARK2_USER read from /etc/mark2.conf.
set -euo pipefail

MARK2_USER=$(grep '^MARK2_USER=' /etc/mark2.conf 2>/dev/null | cut -d= -f2 || echo 'pi')
MARK2_HOME=$(getent passwd "$MARK2_USER" | cut -d: -f6)
VENV="${MARK2_HOME}/.venvs/sj201"

# Start silent I2S playback to provide stable BCLK/MCLK for XVF3510 capture
echo 'Starting silent I2S playback...'
aplay -D hw:sj201,0 -f S32_LE -r 48000 -c 2 /dev/zero 2>/dev/null &
APLAY_PID=$!

# Wait for /dev/snd/pcmC1D0p to open
for i in $(seq 1 20); do
    fuser /dev/snd/pcmC1D0p >/dev/null 2>&1 && break
    sleep 0.2
done
sleep 0.5

echo 'Flashing XVF3510 firmware...'
HOME="$MARK2_HOME" PATH="/usr/local/bin:/usr/bin:/bin"     "${VENV}/bin/python" /opt/sj201/xvf3510-flash         --direct /opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin --verbose

echo 'Waiting 3s for XVF3510 to stabilize...'
sleep 3

echo 'Initialising TAS5806 amplifier...'
HOME="$MARK2_HOME" PATH="/usr/local/bin:/usr/bin:/bin"     "${VENV}/bin/python" /opt/sj201/init_tas5806

# Stop silent playback — PipeWire/LVA will handle audio
echo 'Stopping silent playback...'
kill $APLAY_PID 2>/dev/null || true
wait $APLAY_PID 2>/dev/null || true

echo 'SJ201 init complete'
