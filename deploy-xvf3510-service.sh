#!/bin/bash
# DEPRECATED — investigation script, not part of normal installation.
# Superseded by mark2-audio-init.service + mark2-xvf-post-wp.sh
# See docs/XVF3510_HARDWARE.md
set -euo pipefail

CURRENT_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
USER_UID=$(id -u "$CURRENT_USER")

echo "Installing mark2-xvf3510-init.service for user=$CURRENT_USER uid=$USER_UID home=$USER_HOME"

cat > /etc/systemd/system/mark2-xvf3510-init.service << EOF
[Unit]
Description=XVF3510 firmware flash and TAS5806 init
Documentation=https://github.com/andlo/mark2-assist
Before=user@${USER_UID}.service
After=sound.target local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
User=${CURRENT_USER}
Group=${CURRENT_USER}
SupplementaryGroups=spi gpio audio
WorkingDirectory=/opt/sj201
Environment=PATH=/usr/local/bin:/usr/sbin:/usr/bin:/bin
ExecStart=${USER_HOME}/.venvs/sj201/bin/python /opt/sj201/xvf3510-flash --direct /opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin --verbose
ExecStartPost=${USER_HOME}/.venvs/sj201/bin/python /opt/sj201/init_tas5806
Restart=on-failure
RestartSec=3s
StartLimitBurst=3
StartLimitIntervalSec=30s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mark2-xvf3510-init.service
echo "Done: mark2-xvf3510-init.service installed and enabled"
