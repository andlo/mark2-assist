#!/bin/bash
# =============================================================================
# modules/face.sh
# Animated robot face overlay for the Mark II touchscreen
#
# Displays an animated face in the bottom-right corner of the screen that
# reacts to LVA (linux-voice-assistant) voice events:
#   idle   — half-closed sleepy eyes, fades out after 3 seconds
#   wake   — eyes pop open with a "!" flash
#   listen — big open eyes, pupils wander, natural blinking
#   think  — squinting eyes, animated "..." dots
#   speak  — open eyes, animated mouth, blush
#   error  — worried brows, sad mouth
#
# The face reads /tmp/mark2-face-event.json which is written by the
# mark2-face-events.service installed by mark2-satellite-setup.sh.
# That service tails the lva journal and maps events to states.
# No dependency on the LED module is required.
#
# The face window is launched via labwc autostart as a Chromium --app window.
# labwc is installed alongside Weston for this purpose (Weston handles the
# main kiosk display; labwc manages the HUD overlay windows).
#
# Window: 260×260 px, bottom-right of 800×480 display (position 540,220)
#
# Can be run standalone: bash modules/face.sh
# =============================================================================
# =============================================================================
# DEPRECATED — superseded by modules/ui.sh
#
# This module is kept for reference only. The functionality it provided
# is now built into the combined kiosk page (combined.html) and installed
# automatically by modules/ui.sh.
# Do NOT run this module alongside ui.sh.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "Animated Face Display" "Animated robot face reacting to voice events and music"

if ! confirm_or_skip "Install animated face?"; then
    log "Skipping face"
    exit 0
fi

TEMPLATE_DIR="$(dirname "$0")/../templates"
FACE_DIR="${USER_HOME}/.config/mark2-face"
mkdir -p "$FACE_DIR"

cp "${TEMPLATE_DIR}/face.html" "${FACE_DIR}/face.html"
log "Copied face template to ${FACE_DIR}/face.html"

# The face reads /tmp/mark2-face-event.json, written by mark2-face-events.service.
# That service is installed by mark2-satellite-setup.sh, so no bridge is needed here.
# We just need to launch the Chromium window via labwc autostart.

# Add face window to labwc autostart.
# labwc rc.xml (installed by mark2-satellite-setup.sh) keeps hud.html windows
# always-on-top via windowRule matching "hud.html" in the identifier.
# The face.html window is positioned bottom-right, small enough not to
# cover the main HA dashboard content area.
labwc_autostart_add "face.html" \
    "chromium --app=\"file://${FACE_DIR}/face.html\" --window-size=260,260 --window-position=540,220 --ozone-platform=wayland --password-store=basic --no-first-run --disable-infobars --disable-background-timer-throttling --app-auto-launched &"

systemctl --user daemon-reload 2>/dev/null

log "Animated face installed"
info "Face appears bottom-right of screen (540,220), reacts to LVA events"
info "State source: /tmp/mark2-face-event.json (written by mark2-face-events.service)"
info "Preview in browser: file://${FACE_DIR}/face.html"
