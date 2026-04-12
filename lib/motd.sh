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
echo -e "${BLUE}  Mycroft Mark II — Home Assistant Voice Satellite${NC}"
echo -e "${BLUE}  github.com/andlo/mark2-assist${NC}"
echo ""

# System info
echo -e "${CYAN}  System:${NC}"
printf "  %-12s %s\n" "Hostname:" "$(hostname)"
printf "  %-12s %s\n" "Kernel:"   "$(uname -r)"
printf "  %-12s %s\n" "Uptime:"   "$(uptime -p | sed 's/up //')"
printf "  %-12s %s\n" "IP:"       "$(hostname -I | awk '{print $1}')"
echo ""

# Service status — motd runs as root via run-parts, query pi user services via su
echo -e "${CYAN}  Services:${NC}"
for svc in lva sj201 mark2-volume-buttons; do
    STATUS=$(systemctl --machine pi@.host --user is-active "$svc" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "active" ]; then
        printf "  ${GREEN}✓${NC} %-30s %s\n" "$svc" "running"
    else
        printf "  ${YELLOW}·${NC} %-30s %s\n" "$svc" "$STATUS"
    fi
done
echo ""

# Install summary reference
if [ -f "${HOME}/.config/mark2/install-summary.txt" ]; then
    echo -e "${CYAN}  Install summary:${NC}"
    echo -e "  cat ~/.config/mark2/install-summary.txt"
    echo ""
fi
