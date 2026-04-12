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

# Show trusted_networks instructions
IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${CYAN}  To enable auto-login (no keyboard needed):${NC}"
echo "  Add this to your HA configuration.yaml and restart HA:"
echo ""
echo "  homeassistant:"
echo "    auth_providers:"
echo "      - type: homeassistant"
echo "      - type: trusted_networks"
echo "        trusted_networks:"
echo "          - ${IP}"
echo "        trusted_users:"
echo "          ${IP}:"
echo "            - <YOUR_HA_USER_ID>   # Settings → People → click user → ID in URL"
echo "        allow_bypass_login: true"
echo ""
info "HA dashboard will load at next reboot"
info "URL: ${HA_URL}"
