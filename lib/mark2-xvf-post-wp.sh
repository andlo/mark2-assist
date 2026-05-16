#!/bin/bash
# mark2-xvf-post-wp.sh — XVF3510 SPI flash after PipeWire/WirePlumber starts
#
# Called by mark2-audio-init.service (After=wireplumber.service + ExecStartPre sleep 3).
#
# The vocalfusion-soundcard kernel module (loaded via sj201.dtbo) sets MCLK to
# 24.576MHz via the kernel clock framework at boot. We do NOT override this with
# setup_mclk/setup_bclk — the kernel driver does it correctly.
#
# After WirePlumber has initialised and the echo-cancel module is running,
# we SPI-flash the XVF3510 firmware. WirePlumber's ACP + echo-cancel then
# filter the DSP noise and expose a clean 'echo-cancel-source' for LVA.
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

VENV="${MARK2_HOME}/.venvs/sj201"
FW="${FW:-/opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin}"

log "Flashing XVF3510 via SPI slave boot (user=${MARK2_USER})..."
"${VENV}/bin/python" /opt/sj201/xvf3510-flash --direct "${FW}"

log "Initializing TAS5806 amplifier..."
"${VENV}/bin/python" /opt/sj201/init_tas5806 2>/dev/null || true

log "Done — XVF3510 flash complete"
