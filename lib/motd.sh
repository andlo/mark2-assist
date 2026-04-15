#!/bin/bash
# =============================================================================
# Mark II Assist — login banner (installed as /etc/update-motd.d/10-mark2)
# Shows banner, system info and service status on SSH login
# =============================================================================

# Colors
CYAN='\033[0;36m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo -e "${CYAN}    __  ___           __      ________     ___              _      __ ${NC}"
echo -e "${CYAN}   /  |/  /___ ______/ /__   /  _/  _/    /   |  __________(_)____/ /_${NC}"
echo -e "${CYAN}  / /|_/ / __ \`/ ___/ //_/   / / / /     / /| | / ___/ ___/ / ___/ __/${NC}"
echo -e "${CYAN} / /  / / /_/ / /  / ,<    _/ /_/ /     / ___ |(__  |__  ) (__  ) /_  ${NC}"
echo -e "${CYAN}/_/  /_/\__,_/_/  /_/|_|  /___/___/    /_/  |_/____/____/_/____/\__/  ${NC}"
echo ""
echo -e "${BLUE}  Mycroft Mark II — Home Assistant Voice Satellite (LVA)${NC}"
echo -e "${BLUE}  github.com/andlo/mark2-assist${NC}"
echo ""

# System info
echo -e "${CYAN}  System:${NC}"
printf "  %-12s %s\n" "Hostname:" "$(hostname)"
printf "  %-12s %s\n" "Kernel:"   "$(uname -r)"
printf "  %-12s %s\n" "Uptime:"   "$(uptime -p | sed 's/up //')"
printf "  %-12s %s\n" "IP:"       "$(hostname -I | awk '{print $1}')"
echo ""

# Service status — motd runs as root via run-parts, query user services via --machine
# Detect the mark2 install user dynamically (don't hardcode 'pi')
MARK2_USER=""
# 1. Check /etc/mark2.conf (written by install.sh)
[ -f /etc/mark2.conf ] && MARK2_USER=$(grep '^MARK2_USER=' /etc/mark2.conf | cut -d= -f2)
# 2. Fall back to owner of the config directory
if [ -z "$MARK2_USER" ]; then
    MARK2_USER=$(stat -c %U /home/*/\.config/mark2 2>/dev/null | head -1)
fi
# 3. Fall back to the lva process owner
if [ -z "$MARK2_USER" ]; then
    MARK2_USER=$(ps -eo user,comm 2>/dev/null | grep 'lva\|python3' | awk '{print $1}' | head -1)
fi
# 4. Last resort: first non-root/system user with a home dir
if [ -z "$MARK2_USER" ]; then
    MARK2_USER=$(getent passwd | awk -F: '$3 >= 1000 && $6 ~ /^\/home\// {print $1; exit}')
fi
MACHINE_FLAG=""
[ -n "$MARK2_USER" ] && MACHINE_FLAG="--machine ${MARK2_USER}@.host"

echo -e "${CYAN}  Services:${NC}"

# Core services — always shown
declare -A CORE
CORE[lva]="Voice assistant (LVA)"
CORE[sj201]="SJ201 audio hardware"
CORE[mark2-volume-buttons]="Volume buttons"
CORE[mark2-leds]="LED ring"
CORE[mark2-face-events]="Face / HUD events"

for svc in lva sj201 mark2-volume-buttons mark2-face-events; do
    LABEL="${CORE[$svc]}"
    STATUS=$(systemctl $MACHINE_FLAG --user is-active "$svc" 2>/dev/null | head -1 | tr -d "[:space:]")
    [ -z "$STATUS" ] && STATUS="inactive"
    if [ "$STATUS" = "active" ]; then
        printf "  ${GREEN}✓${NC} %-28s %s\n" "$LABEL" "running"
    else
        printf "  ${YELLOW}✗${NC} %-28s %s\n" "$LABEL" "$STATUS"
    fi
done

# mark2-leds is a system service (runs as root for GPIO) — query directly
LED_STATUS=$(systemctl is-active mark2-leds 2>/dev/null | head -1 | tr -d "[:space:]")
[ -z "$LED_STATUS" ] && LED_STATUS="inactive"
if [ "$LED_STATUS" = "active" ]; then
    printf "  ${GREEN}✓${NC} %-28s %s\n" "${CORE[mark2-leds]}" "running"
else
    printf "  ${YELLOW}✗${NC} %-28s %s\n" "${CORE[mark2-leds]}" "$LED_STATUS"
fi

# Optional services — only shown if installed/enabled
declare -A OPT
OPT[mark2-mqtt-bridge]="MQTT sensors"
OPT[mark2-screensaver]="Screensaver"
OPT[snapclient]="Snapcast (multiroom audio)"
OPT[shairport-sync]="AirPlay"
OPT[mpd]="MPD music player"

for svc in mark2-mqtt-bridge mark2-screensaver snapclient shairport-sync mpd; do
    ENABLED=$(systemctl $MACHINE_FLAG --user is-enabled "$svc" 2>/dev/null | head -1 | tr -d "[:space:]")
    [ -z "$ENABLED" ] && ENABLED="not-found"
    case "$ENABLED" in not-found|masked|static|disabled) continue ;; esac
    LABEL="${OPT[$svc]}"
    STATUS=$(systemctl $MACHINE_FLAG --user is-active "$svc" 2>/dev/null | head -1 | tr -d "[:space:]")
    [ -z "$STATUS" ] && STATUS="inactive"
    if [ "$STATUS" = "active" ]; then
        printf "  ${GREEN}✓${NC} %-28s %s\n" "$LABEL" "running"
    else
        printf "  ${YELLOW}✗${NC} %-28s %s\n" "$LABEL" "$STATUS"
    fi
done
echo ""

# Install summary reference
if [ -f "${HOME}/.config/mark2/install-summary.txt" ]; then
    echo -e "${CYAN}  Install summary:${NC}"
    echo -e "  cat ~/.config/mark2/install-summary.txt"
    echo ""
fi
