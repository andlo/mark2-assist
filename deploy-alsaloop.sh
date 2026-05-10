#!/bin/bash
# DEPRECATED — investigation script, not part of normal installation.
# Superseded by mark2-audio-init.service + mark2-xvf-post-wp.sh
# See docs/XVF3510_HARDWARE.md
# deploy-alsaloop.sh
# Installer snd-aloop + alsaloop service så WirePlumber aldrig rører hw:sj201,1 capture
set -euo pipefail

CURRENT_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)

echo "=== Step 1: snd-aloop persistent ==="
grep -qxF 'snd-aloop' /etc/modules || echo 'snd-aloop' >> /etc/modules
# Loopback device index — pin det til card 4 så det ikke ændrer sig ved reboot
cat > /etc/modprobe.d/snd-aloop.conf << 'EOF'
options snd-aloop index=4
EOF
echo "snd-aloop pinned to card 4"

echo "=== Step 2: alsaloop service ==="
# alsaloop kopierer hw:sj201,1 (XVF3510 output) → hw:Loopback,0 (playback side)
# PipeWire/LVA læser fra hw:Loopback,1 (capture side) — rører aldrig sj201 direkte
cat > /etc/systemd/system/mark2-alsaloop.service << 'EOF'
[Unit]
Description=ALSA loopback: XVF3510 mic → snd-aloop
Documentation=https://github.com/andlo/mark2-assist
After=mark2-xvf3510-init.service sound.target
Requires=mark2-xvf3510-init.service

[Service]
Type=simple
ExecStart=/usr/bin/alsaloop -C hw:sj201,1 -P hw:Loopback,0 -f S32_LE -r 48000 -c 2 -t 50000
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mark2-alsaloop.service
systemctl start  mark2-alsaloop.service
echo "mark2-alsaloop.service started"

echo "=== Step 3: WirePlumber — brug Loopback capture i stedet for sj201 ==="
WPDIR="${USER_HOME}/.config/wireplumber/wireplumber.conf.d"
mkdir -p "$WPDIR"

# Deaktiver sj201 capture-siden i WirePlumber (output forbliver aktiv)
cat > "${WPDIR}/91-sj201-disable-capture.conf" << 'EOF'
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
EOF

# Aktiver Loopback capture som den node LVA bruger
cat > "${WPDIR}/92-loopback-capture.conf" << 'EOF'
monitor.alsa.rules = [
  {
    matches = [ { node.name = ~"alsa_input.platform-soc_sound.*" } ]
    actions = {
      update-props = {
        device.disabled = true
      }
    }
  }
]
EOF

echo "WirePlumber conf skrevet til ${WPDIR}"
echo ""
echo "=== Genstart WirePlumber for at aktivere ny config ==="
sudo -u "$CURRENT_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $CURRENT_USER)" \
    systemctl --user restart wireplumber 2>/dev/null || true

echo ""
echo "DONE. Test med:"
echo "  timeout 4 pw-record --target='alsa_input.platform-soc_sound.Loopback-0' /tmp/test.wav"
echo "  sox /tmp/test.wav -n stat"
