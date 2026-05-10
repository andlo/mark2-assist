#!/bin/bash
# mark2-audio-init — XVF3510 initialization
#
# ROOT CAUSE FOUND (Session 4-5):
# XVF3510-INT requires MCLK=12.288MHz (NOT 24.576MHz).
# sj201.dtbo sets MCLK=24.576MHz which prevents the audio pipeline from starting.
# The fix: use setup_mclk (from XMOS vocalfusion-rpi-setup) to set correct MCLK,
# then setup_bclk for PCM clock, then SPI flash. No data_partition needed.
#
# Mycroft's original run.sh sequence:
#   insmod i2s_master_loader.ko  (activates I2S hardware)
#   arecord -d 1                 (forces ALSA to configure I2S)
#   setup_mclk                   (GPIO4/GPCLK0 = 12.288MHz)
#   setup_bclk                   (PCM divider = 3.072MHz BCLK, clk_enable=0)
#   xvf3510-flash --direct ...   (SPI slave boot)
#
set -euo pipefail

log() { echo "[mark2-audio-init] $*"; }

VENV="$(getent passwd "$(id -un)" | cut -d: -f6)/.venvs/sj201"
UID_NUM="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus"
export PULSE_RUNTIME_PATH="/run/user/${UID_NUM}/pulse"

SETUP_MCLK="${SETUP_MCLK:-/usr/local/bin/setup_mclk}"
SETUP_BCLK="${SETUP_BCLK:-/usr/local/bin/setup_bclk}"
I2S_LOADER="${I2S_LOADER:-/usr/local/bin/i2s_master_loader.ko}"
FW="${FW:-/opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin}"

log "Stopping ALL audio services..."
systemctl --user stop lva.service 2>/dev/null || true
systemctl --user stop wireplumber.service 2>/dev/null || true
systemctl --user stop pipewire-pulse.service pipewire-pulse.socket 2>/dev/null || true
systemctl --user stop pipewire.service pipewire.socket 2>/dev/null || true
pkill -f 'aplay\|arecord' 2>/dev/null || true
sleep 2

log "Loading i2s_master_loader kernel module..."
sudo modprobe i2s_master_loader 2>/dev/null || \
sudo insmod "${I2S_LOADER}" 2>/dev/null || \
log "WARNING: i2s_master_loader not loaded (may already be active via sj201.dtbo)"

log "Activating I2S hardware via arecord..."
arecord -d 1 > /dev/null 2>&1 || true

log "Setting MCLK=12.288MHz (GPIO4/GPCLK0) via setup_mclk..."
sudo "${SETUP_MCLK}"

log "Setting BCLK=3.072MHz (PCM divider) via setup_bclk..."
sudo "${SETUP_BCLK}"

log "Flashing XVF3510 via SPI slave boot..."
"${VENV}/bin/python" /opt/sj201/xvf3510-flash --direct "${FW}"

log "Initializing TAS5806 amplifier..."
"${VENV}/bin/python" /opt/sj201/init_tas5806 2>/dev/null || true

log "Flash done — waiting 1s for chip startup..."
sleep 1

log "Starting PipeWire stack..."
systemctl --user start pipewire.socket pipewire.service 2>/dev/null || \
    systemctl --user start pipewire.service 2>/dev/null || true
systemctl --user start pipewire-pulse.socket pipewire-pulse.service 2>/dev/null || \
    systemctl --user start pipewire-pulse.service 2>/dev/null || true
systemctl --user start wireplumber.service || true
sleep 4

log "Starting LVA..."
systemctl --user start lva.service || true
log "Done"
