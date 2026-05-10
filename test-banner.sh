#!/bin/bash
CYAN='\033[0;36m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
echo ""
echo -e "${CYAN}     ▄██▄           ___  ___           _      _____ _____ ${NC}"
echo -e "${CYAN}   ▄██████▄         |  \/  |          | |    |_   _|_   _|${NC}"
echo -e "${CYAN}  ▄████▀▀████▄      | .  . | __ _ _ __| | __   | |   | |  ${NC}"
echo -e "${CYAN} ▄█████    █████▄   | |\/| |/ _\` | '__| |/ /   | |   | |  ${NC}"
echo -e "${CYAN}▄██████▄  ▄██████▄  | |  | | (_| | |  |   <   _| |_ _| |_ ${NC}"
echo -e "${CYAN}████████  ██▀  ▀██  \_|  |_/\__,_|_|  |_|\_\  \___/ \___/ ${NC}"
echo -e "${CYAN}███▀▀███  ██   ▄██    ___          _     _   ${NC}"
echo -e "${CYAN}██    ██  ▀ ▄█████   / _ \        (_)   | |  ${NC}"
echo -e "${CYAN}███▄▄ ▀█  ▄███████  / /_\ \___ ___ _ ___| |_ ${NC}"
echo -e "${CYAN}▀█████▄   ███████▀  |  _  / __/ __| / __| __|${NC}"
echo -e "${CYAN}                    | | | \__ \__ \ \__ \ |_ ${NC}"
echo -e "${CYAN}                    \_| |_/___/___/_|___/\__|${NC}"
echo ""
echo -e "${BLUE}  Mycroft Mark II — Home Assistant Voice Satellite${NC}"
echo -e "${BLUE}  github.com/andlo/mark2-assist${NC}"
echo ""
echo -e "  ${CYAN}——  Installer  ——${NC}"
echo ""
echo -e "${GREEN}  System:${NC}"
printf "  %-12s %s\n" "Hostname:" "$(hostname)"
printf "  %-12s %s\n" "Uptime:"   "$(uptime -p | sed 's/up //')"
printf "  %-12s %s\n" "IP:"       "$(hostname -I | awk '{print $1}')"
echo ""
