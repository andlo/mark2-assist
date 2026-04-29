#!/bin/bash
# =============================================================================
# modules/homeassistant.sh
# Home Assistant kiosk dashboard for the Mark II touchscreen
#
# Configures the Mark II kiosk to show your Home Assistant dashboard in
# Chromium. Without this module, the kiosk only shows the face animation,
# clock (screensaver) and HUD overlays — useful if you want to use Mark II
# as a pure voice satellite without an HA dashboard.
#
# What this module does:
#   - Saves the HA URL to ~/.config/mark2/config
#   - Writes a marker file (~/.config/mark2/ha-kiosk-enabled) that kiosk.sh
#     checks at startup — if present, Chromium opens the HA dashboard;
#     if absent, Chromium opens the local HUD page instead
#   - Optionally sets up trusted_networks auto-login (see README)
#
# For auto-login on the touchscreen without a keyboard, configure
# trusted_networks in HA configuration.yaml — see README for instructions.
#
# Can be run standalone: bash modules/homeassistant.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "Home Assistant Kiosk" "Show HA dashboard on the Mark II touchscreen"

if ! confirm_or_skip "Install Home Assistant kiosk dashboard?"; then
    log "Skipping Home Assistant kiosk"
    exit 0
fi

# HA URL is always saved upfront by install.sh — just load it here
config_load
if [ -z "${HA_URL:-}" ]; then
    prompt_ha_url
fi

# Write marker file — kiosk.sh checks for this at startup
touch "${MARK2_DIR}/ha-kiosk-enabled"
log "HA kiosk enabled"

# Kiosk idle timeout — default 30s, configurable later in ~/.config/mark2/config
# or via the companion HA integration (not yet built).
if [ -z "${HA_KIOSK_TIMEOUT:-}" ]; then
    HA_KIOSK_TIMEOUT="30"
    config_save "HA_KIOSK_TIMEOUT" "$HA_KIOSK_TIMEOUT"
fi
log "Kiosk idle timeout: ${HA_KIOSK_TIMEOUT}s (change HA_KIOSK_TIMEOUT in ~/.config/mark2/config)"

# Show post-install instructions
IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Required: edit HA configuration.yaml and restart HA${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  1. Allow HA to be shown in the Mark II kiosk (required):${NC}"
echo ""
echo "     http:"
echo "       use_x_frame_options: false"
echo ""
echo -e "${YELLOW}  2. Enable auto-login from this device (recommended):${NC}"
echo ""
echo "     homeassistant:"
echo "       auth_providers:"
echo "         - type: trusted_networks"
echo "           trusted_networks:"
echo "             - ${IP}"
echo "           trusted_users:"
echo "             ${IP}:"
echo "               - <YOUR_HA_USER_ID>  # Settings → People → user → ID in URL"
echo "           allow_bypass_login: true"
echo "         - type: homeassistant"
echo ""
echo "  After editing: restart HA (Settings → System → Restart)"
echo ""
echo -e "${CYAN}  See docs/HA_SETUP.md for full instructions.${NC}"
echo ""
info "HA dashboard will load at next reboot"
info "URL: ${HA_URL}"
