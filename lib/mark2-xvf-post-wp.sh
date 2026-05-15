#!/bin/bash
# mark2-xvf-post-wp.sh — XVF3510 full init sequence
#
# ROOT CAUSE (Session 4-5, maj 2026):
#   XVF3510-INT requires MCLK=12.288MHz. sj201.dtbo sets 24.576MHz → silence.
#   WirePlumber opens hw:sj201,1 during init which resets the XVF3510 DSP.
#
# Required sequence (from Mycroft's original run.sh):
#   1. Stop all audio (WP holds device otherwise)
#   2. arecord -d 1   (activates I2S hardware block — CRITICAL)
#   3. setup_mclk     (GPIO4/GPCLK0 = 12.288MHz)
#   4. setup_bclk     (PCM divider = 3.072MHz BCLK)
#   5. xvf3510-flash  (SPI slave boot)
#   6. init_tas5806   (amplifier)
#   7. restart PipeWire + WirePlumber
#   8. start LVA
#
# Works whether invoked as the mark2 user OR via sudo (uses /etc/mark2.conf).
#
set -euo pipefail

log() { echo "[mark2-xvf-flash] $*"; }

# --- Resolve the actual Mark II user (works as user OR via sudo) ---
if [ -f /etc/mark2.conf ]; then
    # shellcheck source=/etc/mark2.conf
    source /etc/mark2.conf
    MARK2_USER="${MARK2_USER:-pi}"
else
    MARK2_USER="${SUDO_USER:-${USER:-pi}}"
fi
MARK2_HOME="$(getent passwd "${MARK2_USER}" | cut -d: -f6)"
MARK2_UID="$(id -u "${MARK2_USER}")"

VENV="${MARK2_HOME}/.venvs/sj201"
export XDG_RUNTIME_DIR="/run/user/${MARK2_UID}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${MARK2_UID}/bus"
export PULSE_RUNTIME_PATH="/run/user/${MARK2_UID}/pulse"

SETUP_MCLK="${SETUP_MCLK:-/usr/local/bin/setup_mclk}"
SETUP_BCLK="${SETUP_BCLK:-/usr/local/bin/setup_bclk}"
FW="${FW:-/opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin}"

log "Stopping audio services (user=${MARK2_USER})..."
sudo -u "${MARK2_USER}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    systemctl --user stop lva wireplumber pipewire-pulse pipewire 2>/dev/null || true
sleep 2

log "Activating I2S hardware via arecord (CRITICAL: initialises I2S clocks)..."
arecord -d 1 > /dev/null 2>&1 || true

log "Setting MCLK=12.288MHz (GPIO4/GPCLK0)..."
sudo "${SETUP_MCLK}"

log "Setting BCLK=3.072MHz (PCM divider)..."
sudo "${SETUP_BCLK}"

log "Flashing XVF3510 via SPI slave boot..."
"${VENV}/bin/python" /opt/sj201/xvf3510-flash --direct "${FW}"

log "Initializing TAS5806 amplifier..."
"${VENV}/bin/python" /opt/sj201/init_tas5806 2>/dev/null || true

log "Waiting 1s for chip startup..."
sleep 1

log "Starting PipeWire stack..."
sudo -u "${MARK2_USER}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    systemctl --user start pipewire pipewire-pulse wireplumber || true
sleep 4

log "Starting LVA..."
sudo -u "${MARK2_USER}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    systemctl --user start lva || true

log "Done"
