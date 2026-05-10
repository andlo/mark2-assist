#!/bin/bash
# DEPRECATED — investigation script, not part of normal installation.
# Superseded by mark2-audio-init.service + mark2-xvf-post-wp.sh
# See docs/XVF3510_HARDWARE.md
# test-disable-sj201-capture.sh
# Deaktiver WirePlumber's kontrol over sj201 capture, start alsaloop, test signal
set -euo pipefail

CURRENT_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
WPDIR="${USER_HOME}/.config/wireplumber/wireplumber.conf.d"

echo "=== Skriver WirePlumber regel: deaktiver sj201 capture node ==="
cat > "${WPDIR}/91-sj201-disable-capture.conf" << 'WPEOF'
monitor.alsa.rules = [
  {
    matches = [ { node.name = "alsa_input.platform-soc_sound.pro-input-1" } ]
    actions = {
      update-props = {
        device.disabled = true
      }
    }
  }
]
WPEOF

echo "=== Genstart WirePlumber ==="
XDG_RUNTIME_DIR="/run/user/$(id -u $CURRENT_USER)" \
    systemctl --user restart wireplumber
sleep 4

echo "=== Check: er sj201 capture stadig åben? ==="
cat /proc/asound/card1/pcm1c/sub0/hw_params 2>/dev/null || echo "sj201 capture: LUKKET (godt!)"

echo "=== Start alsaloop: hw:sj201,1 → hw:Loopback,0 ==="
alsaloop -C hw:sj201,1 -P hw:Loopback,0 -f S32_LE -r 48000 -c 2 &
ALOOP_PID=$!
sleep 2

echo "=== Test signal via PipeWire Loopback ==="
timeout 4 pw-record \
    --target='alsa_input.platform-snd_aloop.0.analog-stereo' \
    --format=s16 --rate=16000 --channels=1 \
    /tmp/loopback_test.wav 2>&1 || true

kill $ALOOP_PID 2>/dev/null || true

sox /tmp/loopback_test.wav -n stat 2>&1 | grep -E 'Maximum|RMS'
