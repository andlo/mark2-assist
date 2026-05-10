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
printf "${CYAN}%s${NC}
" $'       /\        '
printf "${CYAN}%s${NC}
" $'      /  \        __  __          _     ___ ___ '
printf "${CYAN}%s${NC}
" $'     /    \      |  \/  |__ _ _ _| |__ |_ _|_ _|'
printf "${CYAN}%s${NC}
" $'    /  /\  \     | |\/| / _` | \'_| / /  | | | | '
printf "${CYAN}%s${NC}
" $'   /__/  \__\    |_|  |_\__,_|_| |_\_\ |___|___|'
printf "${CYAN}%s${NC}
" $'   |  |  |  |       _          _    _   '
printf "${CYAN}%s${NC}
" $'   |  |  |  |      /_\   _____(_)__| |_ '
printf "${CYAN}%s${NC}
" $'   |  |  |  |     / _ \ (_-<_-< (_-<  _|'
printf "${CYAN}%s${NC}
" $'   |__|  |__|    /_/ \_\/__/__/_/__/\__|'
printf "${CYAN}%s${NC}
" $'                 '
echo ""
printf "${BLUE}  Mycroft Mark II — Home Assistant Voice Satellite${NC}
"
printf "${BLUE}  github.com/andlo/mark2-assist${NC}
"
echo ""
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

# Core services
declare -A CORE
CORE[lva]="Voice assistant (LVA)"
CORE[mark2-audio-init]="XVF3510 audio init"
CORE[mark2-volume-buttons]="Volume buttons"
CORE[mark2-face-events]="Face animation"
CORE[wireplumber]="PipeWire/WirePlumber"

for svc in lva mark2-audio-init mark2-volume-buttons mark2-face-events wireplumber; do
    LABEL="${CORE[$svc]}"
    STATUS=$(systemctl $MACHINE_FLAG --user is-active "$svc" 2>/dev/null | tr -d "[:space:]")
    [ -z "$STATUS" ] && STATUS=$(systemctl $MACHINE_FLAG --user show -p ActiveState "$svc" 2>/dev/null | cut -d= -f2)
    [ -z "$STATUS" ] && STATUS="inactive"
    if [ "$STATUS" = "active" ]; then
        printf "  ${GREEN}✓${NC} %-28s %s\n" "$LABEL" "running"
    elif [ "$STATUS" = "exited" ]; then
        printf "  ${GREEN}✓${NC} %-28s %s\n" "$LABEL" "done (oneshot)"
    else
        printf "  ${YELLOW}✗${NC} %-28s %s\n" "$LABEL" "$STATUS"
    fi
done

# Optional services — only shown if enabled
declare -A OPT
OPT[snapclient]="Snapcast (multiroom audio)"
OPT[shairport-sync]="AirPlay"
OPT[mpd]="MPD music player"
OPT[kdeconnect]="KDE Connect"

for svc in snapclient shairport-sync mpd kdeconnect; do
    ENABLED=$(systemctl $MACHINE_FLAG --user is-enabled "$svc" 2>/dev/null | tr -d "[:space:]")
    [ -z "$ENABLED" ] && ENABLED="not-found"
    case "$ENABLED" in not-found|masked|static|disabled) continue ;; esac
    LABEL="${OPT[$svc]}"
    STATUS=$(systemctl $MACHINE_FLAG --user is-active "$svc" 2>/dev/null | tr -d "[:space:]")
    [ -z "$STATUS" ] && STATUS="inactive"
    if [ "$STATUS" = "active" ]; then
        printf "  ${GREEN}✓${NC} %-28s %s\n" "$LABEL" "running"
    else
        printf "  ${YELLOW}✗${NC} %-28s %s\n" "$LABEL" "$STATUS"
    fi
done
echo ""

echo ""
printf "${CYAN}%s${NC}
" $'       /\        '
printf "${CYAN}%s${NC}
" $'      /  \        __  __          _     ___ ___ '
printf "${CYAN}%s${NC}
" $'     /    \      |  \/  |__ _ _ _| |__ |_ _|_ _|'
printf "${CYAN}%s${NC}
" $'    /  /\  \     | |\/| / _` | \'_| / /  | | | | '
printf "${CYAN}%s${NC}
" $'   /__/  \__\    |_|  |_\__,_|_| |_\_\ |___|___|'
printf "${CYAN}%s${NC}
" $'   |  |  |  |       _          _    _   '
printf "${CYAN}%s${NC}
" $'   |  |  |  |      /_\   _____(_)__| |_ '
printf "${CYAN}%s${NC}
" $'   |  |  |  |     / _ \ (_-<_-< (_-<  _|'
printf "${CYAN}%s${NC}
" $'   |__|  |__|    /_/ \_\/__/__/_/__/\__|'
printf "${CYAN}%s${NC}
" $'                 '
echo ""
printf "${BLUE}  Mycroft Mark II — Home Assistant Voice Satellite${NC}
"
printf "${BLUE}  github.com/andlo/mark2-assist${NC}
"
echo ""
echo -e "  ${CYAN}Logs:${NC} journalctl --user -u lva -f"
echo ""
