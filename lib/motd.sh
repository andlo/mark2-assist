#!/bin/bash
# =============================================================================
# Mark II Assist — login banner (installed as /etc/update-motd.d/10-mark2)
# Shows banner, system info and service status on SSH login
# =============================================================================

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
echo -e "${BLUE}  Mycroft Mark II — Home Assistant Voice Satellite${NC}"
echo -e "${BLUE}  github.com/andlo/mark2-assist${NC}"
echo ""

# System info
echo -e "${CYAN}  System:${NC}"
printf "  %-12s %s\n" "Hostname:" "$(hostname)"
printf "  %-12s %s\n" "Uptime:"   "$(uptime -p | sed 's/up //')"
printf "  %-12s %s\n" "IP:"       "$(hostname -I | awk '{print $1}')"
echo ""

# Detect mark2 user dynamically
MARK2_USER=""
[ -f /etc/mark2.conf ] && MARK2_USER=$(grep '^MARK2_USER=' /etc/mark2.conf | cut -d= -f2)
[ -z "$MARK2_USER" ] && MARK2_USER=$(stat -c %U /home/*/\.config/mark2 2>/dev/null | head -1)
[ -z "$MARK2_USER" ] && MARK2_USER=$(getent passwd | awk -F: '$3 >= 1000 && $6 ~ /^\/home\// {print $1; exit}')
MACHINE_FLAG=""
[ -n "$MARK2_USER" ] && MACHINE_FLAG="--machine ${MARK2_USER}@.host"

echo -e "${CYAN}  Services:${NC}"

declare -A CORE
CORE[lva]="Voice assistant (LVA)"
CORE[mark2-audio-init]="XVF3510 audio init"
CORE[mark2-volume-buttons]="Volume buttons"
CORE[mark2-face-events]="Face animation"
CORE[wireplumber]="PipeWire/WirePlumber"

for svc in lva mark2-audio-init mark2-volume-buttons mark2-face-events wireplumber; do
    LABEL="${CORE[$svc]}"
    STATUS=$(systemctl $MACHINE_FLAG --user is-active "$svc" 2>/dev/null | tr -d "[:space:]")
    [ -z "$STATUS" ] && STATUS="inactive"
    if [ "$STATUS" = "active" ]; then
        printf "  ${GREEN}✓${NC} %-28s %s\n" "$LABEL" "running"
    elif [ "$STATUS" = "exited" ]; then
        printf "  ${GREEN}✓${NC} %-28s %s\n" "$LABEL" "done (oneshot)"
    else
        printf "  ${YELLOW}✗${NC} %-28s %s\n" "$LABEL" "$STATUS"
    fi
done

echo ""
echo -e "  ${CYAN}Logs:${NC} journalctl --user -u lva -f"
echo ""
