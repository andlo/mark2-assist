#!/bin/bash
# =============================================================================
# modules/usb-audio.sh
# USB audio fallback — auto-switches to USB DAC if SJ201 fails at boot
#
# The SJ201 audio board occasionally fails to initialize properly at boot,
# leaving the system with no audio output. This module installs a oneshot
# service that checks for the SJ201 at boot and switches to a USB audio
# device if the SJ201 is not found.
#
# At boot (after PipeWire and SJ201 service):
#   1. Check if SJ201 appears as a PipeWire sink
#   2. If yes: set SJ201 as default sink and exit
#   3. If no: find first USB audio sink, set as default, flash LEDs red
#
# Also installs the mark2-audio-switch command for manual switching:
#   mark2-audio-switch list          — list available sinks
#   mark2-audio-switch sj201         — switch to SJ201
#   mark2-audio-switch usb           — switch to USB audio
#   mark2-audio-switch <sink-name>   — switch to named sink
#
# Fallback log: ~/.config/mark2/audio-fallback.log
#
# Can be run standalone: bash modules/usb-audio.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "USB Audio Fallback" "Auto-switch to USB DAC if SJ201 fails at boot"
echo ""

if ! confirm_or_skip "Install USB audio fallback?"; then
    log "Skipping USB audio fallback"
    exit 0
fi

FALLBACK_SCRIPT="${MARK2_DIR}/audio-fallback.sh"
SWITCH_SCRIPT="/usr/local/bin/mark2-audio-switch"

cat > "$FALLBACK_SCRIPT" << 'SHEOF'
#!/bin/bash
set -euo pipefail
LOG="${HOME}/.config/mark2/audio-fallback.log"
SJ201_CARD_NAME="soc_sound\|XVF3510\|sj201"

echo "[$(date)] Checking audio devices..." >> "$LOG"

if aplay -l 2>/dev/null | grep -qi "$SJ201_CARD_NAME"; then
    SJ201_SINK=$(pactl list short sinks 2>/dev/null | grep -i "soc_sound\|sj201" | awk '{print $2}' | head -1)
    if [ -n "$SJ201_SINK" ]; then
        pactl set-default-sink "$SJ201_SINK"
        echo "[$(date)] SJ201 active, sink: ${SJ201_SINK}" >> "$LOG"
    fi
    exit 0
fi

echo "[$(date)] SJ201 not found - checking USB audio..." >> "$LOG"
USB_SINK=$(pactl list short sinks 2>/dev/null | grep -i "usb\|USB" | awk '{print $2}' | head -1)
if [ -n "$USB_SINK" ]; then
    pactl set-default-sink "$USB_SINK"
    echo "[$(date)] USB fallback: ${USB_SINK}" >> "$LOG"
    echo "error" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock 2>/dev/null || true
    sleep 2
    echo "idle"  | socat - UNIX-CONNECT:/tmp/mark2-leds.sock 2>/dev/null || true
    exit 0
fi

echo "[$(date)] No audio output found - using default" >> "$LOG"
SHEOF
chmod +x "$FALLBACK_SCRIPT"

sudo tee "$SWITCH_SCRIPT" > /dev/null << 'SHEOF'
#!/bin/bash
# Usage: mark2-audio-switch [sj201|usb|list|<sink-name>]
case "${1:-list}" in
    list)
        echo "Available audio sinks:"
        pactl list short sinks | awk '{print NR". "$2}'
        echo ""
        echo "Current default: $(pactl get-default-sink)"
        ;;
    sj201)
        SINK=$(pactl list short sinks | grep -i "soc_sound\|sj201" | awk '{print $2}' | head -1)
        [ -n "$SINK" ] && pactl set-default-sink "$SINK" && echo "Switched to SJ201: $SINK" || { echo "SJ201 not found"; exit 1; }
        ;;
    usb)
        SINK=$(pactl list short sinks | grep -i "usb\|USB" | awk '{print $2}' | head -1)
        [ -n "$SINK" ] && pactl set-default-sink "$SINK" && echo "Switched to USB: $SINK" || { echo "No USB audio found"; exit 1; }
        ;;
    *)
        pactl set-default-sink "$1" && echo "Switched to: $1"
        ;;
esac
SHEOF
sudo chmod +x "$SWITCH_SCRIPT"

cat > "${SYSTEMD_USER_DIR}/mark2-audio-fallback.service" << EOF
[Unit]
Description=Mark II USB audio fallback check
After=pipewire.service wireplumber.service sj201.service
Wants=pipewire.service

[Service]
Type=oneshot
ExecStart=${FALLBACK_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload 2>/dev/null
systemctl --user enable mark2-audio-fallback.service 2>/dev/null

log "USB audio fallback installed"
info "Manual switch: mark2-audio-switch [sj201|usb|list]"
info "Fallback log: ${MARK2_DIR}/audio-fallback.log"
