#!/bin/bash
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
echo -e "  ${CYAN}——  SSH Login Test  ——${NC}"
echo ""
echo -e "${GREEN}  System:${NC}"
printf "  %-12s %s\n" "Hostname:" "$(hostname)"
printf "  %-12s %s\n" "Uptime:"   "$(uptime -p | sed 's/up //')"
printf "  %-12s %s\n" "IP:"       "$(hostname -I | awk '{print $1}')"
echo ""
echo -e "${GREEN}  Services:${NC}"
for svc in lva mark2-audio-init wireplumber; do
    st=$(systemctl --user is-active "$svc" 2>/dev/null || echo inactive)
    [ "$st" = "active" ] \
        && printf "  ${GREEN}✓${NC} %-28s %s\n" "$svc" "running" \
        || printf "  ${YELLOW}✗${NC} %-28s %s\n" "$svc" "$st"
done
echo ""
