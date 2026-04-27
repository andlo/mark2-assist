#!/bin/bash
# =============================================================================
# lib/install-plymouth.sh
# Install Mark II boot splash (Plymouth theme)
#
# Called by mark2-satellite-setup.sh and modules/ui.sh.
# Can also be run standalone: sudo bash lib/install-plymouth.sh
#
# What it does:
#   1. Installs plymouth + librsvg2-bin
#   2. Generates PNG assets from inline SVG
#   3. Installs the mark2 Plymouth theme (script renderer + DRM)
#   4. Sets mark2 as the active theme
#   5. Adds 'quiet splash' to /boot/firmware/cmdline.txt
#   6. Regenerates initramfs so Plymouth is included in early boot
#
# The theme uses Plymouth's 'script' renderer (vc4-kms-v3d DRM/KMS compatible).
# Display: 800x480, #050510 background, centered face + title + progress bar.
# =============================================================================

set -euo pipefail

THEME_NAME="mark2"
THEME_DIR="/usr/share/plymouth/themes/${THEME_NAME}"
CMDLINE="/boot/firmware/cmdline.txt"

# ── Require root ──────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

echo "[plymouth] Installing Mark II boot splash..."

# ── Dependencies ──────────────────────────────────────────────────────────────
# plymouth-themes provides label-pango.so (text rendering plugin).
# Without it, update-initramfs warns and Plymouth may fall back to text mode.
apt-get install -y --no-install-recommends plymouth plymouth-themes librsvg2-bin 2>&1 \
    | grep -v "^Hit\|^Get\|^Fetch\|^Reading\|^Building\|^Preconfiguring" || true

# ── Theme directory ───────────────────────────────────────────────────────────
mkdir -p "${THEME_DIR}"

# ── Face PNG (200x200) ────────────────────────────────────────────────────────
rsvg-convert -w 200 -h 200 - -o "${THEME_DIR}/face.png" << 'SVGEOF'
<svg viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">
  <rect width="200" height="200" fill="#050510"/>
  <circle cx="100" cy="100" r="92" fill="none" stroke="rgba(96,128,255,0.15)" stroke-width="1.5"/>
  <circle cx="100" cy="100" r="84" fill="none" stroke="rgba(96,128,255,0.07)" stroke-width="1"/>
  <ellipse cx="68" cy="88" rx="21" ry="21" fill="#e8e8f0"/>
  <ellipse cx="132" cy="88" rx="21" ry="21" fill="#e8e8f0"/>
  <circle cx="68" cy="90" r="10" fill="#050510"/>
  <circle cx="132" cy="90" r="10" fill="#050510"/>
  <circle cx="72" cy="84" r="3.5" fill="rgba(255,255,255,0.7)"/>
  <circle cx="136" cy="84" r="3.5" fill="rgba(255,255,255,0.7)"/>
  <rect x="47" y="67" width="42" height="14" fill="#050510"/>
  <rect x="111" y="67" width="42" height="14" fill="#050510"/>
  <path d="M 76 130 Q 100 142 124 130" fill="none" stroke="#e8e8f0" stroke-width="3.5" stroke-linecap="round"/>
  <circle cx="46" cy="114" r="13" fill="rgba(255,100,140,0.14)"/>
  <circle cx="154" cy="114" r="13" fill="rgba(255,100,140,0.14)"/>
</svg>
SVGEOF
echo "[plymouth]  face.png generated"

# ── Logo PNG (480x64) ─────────────────────────────────────────────────────────
rsvg-convert -w 480 -h 64 - -o "${THEME_DIR}/logo.png" << 'SVGEOF'
<svg viewBox="0 0 480 64" xmlns="http://www.w3.org/2000/svg">
  <text x="240" y="46"
        font-family="'Segoe UI',system-ui,sans-serif"
        font-size="38" font-weight="200"
        fill="#e8e8f0" text-anchor="middle" letter-spacing="3">Mark II <tspan fill="#6080ff" font-weight="400">Assist</tspan></text>
</svg>
SVGEOF
echo "[plymouth]  logo.png generated"

# ── Progress bar PNGs (400x8) ─────────────────────────────────────────────────
rsvg-convert -w 400 -h 8 - -o "${THEME_DIR}/progress_box.png" << 'SVGEOF'
<svg viewBox="0 0 400 8" xmlns="http://www.w3.org/2000/svg">
  <rect width="400" height="8" rx="4" fill="rgba(255,255,255,0.06)"/>
</svg>
SVGEOF

rsvg-convert -w 400 -h 8 - -o "${THEME_DIR}/progress_bar.png" << 'SVGEOF'
<svg viewBox="0 0 400 8" xmlns="http://www.w3.org/2000/svg">
  <rect width="400" height="8" rx="4" fill="#6080ff"/>
</svg>
SVGEOF
echo "[plymouth]  progress bar PNGs generated"

# ── .plymouth config ──────────────────────────────────────────────────────────
cat > "${THEME_DIR}/${THEME_NAME}.plymouth" << EOF
[Plymouth Theme]
Name=Mark II Assist
Description=Mark II Home Assistant Voice Satellite boot splash
ModuleName=script

[script]
ImageDir=${THEME_DIR}
ScriptFile=${THEME_DIR}/${THEME_NAME}.script
EOF

# ── .script animation ─────────────────────────────────────────────────────────
cat > "${THEME_DIR}/${THEME_NAME}.script" << 'SCRIPTEOF'
Screen.SetBackgroundTopColor(0.02, 0.02, 0.06);
Screen.SetBackgroundBottomColor(0.02, 0.02, 0.06);

face_image  = Image("face.png");
logo_image  = Image("logo.png");
pbox_image  = Image("progress_box.png");
pbar_image  = Image("progress_bar.png");

# Hardcode screen dimensions — Screen.GetWidth/Height may return 0 early
# during DSI panel init on Raspberry Pi. Safe values for 800x480 display.
SCREEN_W = 800;
SCREEN_H = 480;

face_x = Math.Int((SCREEN_W - face_image.GetWidth())  / 2);
face_y = Math.Int( SCREEN_H * 0.18);
face_sprite = Sprite(face_image);
face_sprite.SetX(face_x);
face_sprite.SetY(face_y);

logo_x = Math.Int((SCREEN_W - logo_image.GetWidth())  / 2);
logo_y = face_y + face_image.GetHeight() + 20;
logo_sprite = Sprite(logo_image);
logo_sprite.SetX(logo_x);
logo_sprite.SetY(logo_y);

pbox_x = Math.Int((SCREEN_W - pbox_image.GetWidth())  / 2);
pbox_y = logo_y + logo_image.GetHeight() + 32;
pbox_sprite = Sprite(pbox_image);
pbox_sprite.SetX(pbox_x);
pbox_sprite.SetY(pbox_y);

pbar_sprite = Sprite();
pbar_sprite.SetX(pbox_x);
pbar_sprite.SetY(pbox_y);

fun progress_callback(duration, progress) {
    w = Math.Int(pbar_image.GetWidth() * progress);
    if (w < 2) w = 2;
    pbar_sprite.SetImage(pbar_image.Scale(w, pbar_image.GetHeight()));
}
Plymouth.SetBootProgressFunction(progress_callback);

fun quit_callback() {
    face_sprite.SetOpacity(0.0);
    logo_sprite.SetOpacity(0.0);
    pbox_sprite.SetOpacity(0.0);
    pbar_sprite.SetOpacity(0.0);
}
Plymouth.SetQuitFunction(quit_callback);

tick = 0;
fun refresh_callback() {
    tick++;
    face_sprite.SetOpacity(0.925 + 0.075 * Math.Sin(tick * 0.08));
}
Plymouth.SetRefreshFunction(refresh_callback);
SCRIPTEOF
echo "[plymouth]  theme script written"

# ── Set as default theme ──────────────────────────────────────────────────────
update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
    default.plymouth "${THEME_DIR}/${THEME_NAME}.plymouth" 200 2>/dev/null || true
plymouth-set-default-theme "${THEME_NAME}"
echo "[plymouth]  theme activated: ${THEME_NAME}"

# ── plymouthd.conf ───────────────────────────────────────────────────────────
cat > /etc/plymouth/plymouthd.conf << PCONF
[Daemon]
Theme=${THEME_NAME}
ShowDelay=0
DeviceTimeout=8
PCONF
echo "[plymouth]  plymouthd.conf: ShowDelay=0 DeviceTimeout=8"

# ── tty1 blanking service (before getty, after Plymouth) ─────────────────────
# This service runs at the same time as getty@tty1 and clears the terminal
# so no login prompt is visible during the brief Plymouth→Weston handoff.
cat > /etc/systemd/system/mark2-tty1-blank.service << 'SVCEOF'
[Unit]
Description=Blank tty1 before Mark II kiosk starts
DefaultDependencies=no
After=plymouth-quit.service
Before=getty@tty1.service
ConditionPathExists=/usr/bin/printf

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'printf "\033[2J\033[H\033[?25l" > /dev/tty1 2>/dev/null; true'
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload 2>/dev/null
systemctl enable mark2-tty1-blank.service 2>/dev/null
echo "[plymouth]  tty1 blanking service installed"

# ── Update cmdline.txt ────────────────────────────────────────────────────────
if [ -f "$CMDLINE" ]; then
    LINE=$(cat "$CMDLINE")
    LINE=$(echo "$LINE" | sed 's/ quiet//g; s/ splash//g; s/ plymouth\.ignore-serial-consoles//g; s/ vt\.global_cursor_default=[0-9]//g; s/ vt\.handoff=[0-9]//g; s/ loglevel=[0-9]//g; s/ consoleblank=[0-9]*//g; s/ rd\.systemd\.show_status=[^ ]*//g; s/  */ /g; s/ *$//')
    # Remove console=tty1 — sends kernel messages to screen even with quiet
    LINE=$(echo "$LINE" | sed 's/ console=tty1//g')
    # Add splash flags:
    #   quiet splash          — suppress most kernel messages
    #   loglevel=3            — only errors reach the framebuffer console
    #                           (quiet alone doesn't suppress out-of-tree module
    #                            warnings like VocalFusion "taints kernel")
    #   vt.global_cursor_default=0 — hide blinking text cursor
    #   vt.handoff=2          — smooth Plymouth→tty1 handoff
    echo "${LINE} quiet splash loglevel=3 plymouth.ignore-serial-consoles vt.global_cursor_default=0 vt.handoff=2" > "$CMDLINE"
    echo "[plymouth]  cmdline.txt: quiet splash loglevel=3 + cursor hidden + vt.handoff=2, console=tty1 removed"
else
    echo "[plymouth]  WARNING: ${CMDLINE} not found — add 'quiet splash' manually"
fi

# ── Regenerate initramfs ──────────────────────────────────────────────────────
echo "[plymouth]  Regenerating initramfs (~30s)..."
update-initramfs -u 2>&1 | grep -v "^I: " | tail -5

echo "[plymouth] Mark II boot splash installed ✅"
echo "[plymouth] Reboot to see it."
