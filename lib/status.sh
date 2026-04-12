#!/bin/bash
# =============================================================================
# Mark II Assist — service status overview
# Run manually: mark2-status
# Installed as: /usr/local/bin/mark2-status
# Same info as SSH login banner (motd) but with more detail.
# =============================================================================

CYAN='\033[0;36m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Works both as pi user and as root (via run-parts/sudo)
if [ "$(id -u)" = "0" ]; then
    MACHINE_FLAG="--machine pi@.host"
else
    MACHINE_FLAG=""
fi

run_sc() {
    systemctl $MACHINE_FLAG --user "$@" 2>/dev/null
}

run_sc_system() {
    # For system services (not user services) — needs sudo when run as pi
    if [ "$(id -u)" = "0" ]; then
        systemctl "$@" 2>/dev/null
    else
        sudo systemctl "$@" 2>/dev/null
    fi
}

print_svc() {
    local svc="$1" label="$2"
    _print_svc_inner "$svc" "$label" "run_sc"
}

print_system_svc() {
    local svc="$1" label="$2"
    _print_svc_inner "$svc" "$label" "run_sc_system"
}

_print_svc_inner() {
    local svc="$1" label="$2" runner="$3"
    local active sub since err

    active=$($runner is-active "$svc" | head -1 | tr -d '[:space:]')
    [ -z "$active" ] && active="inactive"
    sub=$($runner show "$svc" -p SubState --value | head -1 | tr -d '[:space:]')
    since=$($runner show "$svc" -p ActiveEnterTimestamp --value | head -1 | sed 's/ CEST//;s/ CET//')

    case "$active" in
        active)
            printf "  ${GREEN}✓${NC} %-28s ${GREEN}running${NC}" "$label"
            [ -n "$since" ] && printf "  (since %s)" "$since"
            printf "\n"
            ;;
        activating)
            printf "  ${YELLOW}·${NC} %-28s ${YELLOW}starting${NC} (%s)\n" "$label" "$sub"
            ;;
        failed)
            printf "  ${RED}✗${NC} %-28s ${RED}failed${NC}\n" "$label"
            err=$($runner status "$svc" --no-pager -n 5 2>/dev/null \
                | grep -i 'error\|fail\|Error' | tail -1 \
                | sed 's/^[^:]*: //' | cut -c1-70)
            [ -n "$err" ] && printf "    ${RED}→${NC} %s\n" "$err"
            ;;
        inactive)
            printf "  ${YELLOW}·${NC} %-28s stopped\n" "$label"
            ;;
        *)
            printf "  ${YELLOW}·${NC} %-28s %s\n" "$label" "$active"
            ;;
    esac
}

# =============================================================================
echo ""
echo -e "${CYAN}  Mark II Assist — Service Status${NC}"
echo -e "  $(date '+%a %d %b %Y %H:%M:%S')"
echo ""

# =============================================================================
echo -e "${BLUE}  System${NC}"
printf "  %-14s %s\n" "Hostname:"   "$(hostname)"
printf "  %-14s %s\n" "Uptime:"     "$(uptime -p | sed 's/up //')"
printf "  %-14s %s\n" "IP:"         "$(hostname -I | awk '{print $1}')"
printf "  %-14s %s\n" "CPU temp:"   "$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2 || echo 'n/a')"
printf "  %-14s %s\n" "Disk free:"  "$(df -h / | awk 'NR==2{print $4 " free of " $2}')"
echo ""

# =============================================================================
echo -e "${BLUE}  Core services${NC}"
print_svc lva                  "Voice assistant (LVA)"
print_svc sj201                "SJ201 audio hardware"
print_svc mark2-volume-buttons "Volume buttons"
print_system_svc mark2-leds    "LED ring"
print_svc mark2-face-events    "Face / HUD events"
echo ""

# =============================================================================
declare -A OPT_LABELS
OPT_LABELS[mark2-mqtt-bridge]="MQTT sensors"
OPT_LABELS[mark2-screensaver]="Screensaver"
OPT_LABELS[mark2-mpd-watcher]="MPD watcher"
OPT_LABELS[snapclient]="Snapcast"
OPT_LABELS[shairport-sync]="AirPlay"
OPT_LABELS[mpd]="MPD music player"
OPT_LABELS[kdeconnect]="KDE Connect"

OPT_SHOWN=false
for svc in mark2-mqtt-bridge mark2-screensaver mark2-mpd-watcher snapclient shairport-sync mpd kdeconnect; do
    ENABLED=$(run_sc is-enabled "$svc" | head -1 | tr -d '[:space:]')
    [ -z "$ENABLED" ] && ENABLED="not-found"
    case "$ENABLED" in not-found|masked|static|disabled) continue ;; esac
    if [ "$OPT_SHOWN" = false ]; then
        echo -e "${BLUE}  Optional modules${NC}"
        OPT_SHOWN=true
    fi
    print_svc "$svc" "${OPT_LABELS[$svc]}"
done
[ "$OPT_SHOWN" = true ] && echo ""

# =============================================================================
echo -e "${BLUE}  Audio${NC}"
VOL=$(python3 -c "
import smbus2, math
bus = smbus2.SMBus(1)
reg = bus.read_byte_data(0x2f, 0x4c)
pct = round(100.0 * (math.log(210) - math.log(max(84,min(210,reg)))) / (math.log(210) - math.log(84)))
print(f'{pct}%  (-{reg*0.5:.1f} dB)')
bus.close()
" 2>/dev/null || echo "n/a")
printf "  %-14s %s\n" "Volume:" "$VOL"
ASR=$(wpctl status 2>/dev/null | grep 'SJ201 ASR' | head -1)
SPK=$(wpctl status 2>/dev/null | grep 'SJ201 Speaker' | head -1)
if [ -n "$ASR" ]; then
    echo -e "  ${GREEN}✓${NC} ASR source:      present"
else
    echo -e "  ${RED}✗${NC} ASR source:      missing"
    echo    "    → run: systemctl --user restart pipewire wireplumber"
fi
if [ -n "$SPK" ]; then
    echo -e "  ${GREEN}✓${NC} Speaker sink:    present"
else
    echo -e "  ${RED}✗${NC} Speaker sink:    missing"
    echo    "    → run: systemctl --user restart pipewire wireplumber"
fi
echo ""

# =============================================================================
echo -e "${BLUE}  Home Assistant${NC}"
HA_URL=""
HA_TOKEN=""
[ -f "$HOME/.config/mark2/config" ] && source "$HOME/.config/mark2/config" 2>/dev/null

if [ -n "$HA_URL" ]; then
    HTTP=$(curl -o /dev/null -sf --max-time 3 -w "%{http_code}" "$HA_URL" 2>/dev/null)
    case "$HTTP" in
        200|401|302)
            printf "  %-14s ${GREEN}reachable${NC}  %s\n" "HA:" "$HA_URL" ;;
        "")
            printf "  %-14s ${RED}unreachable${NC}  %s\n" "HA:" "$HA_URL" ;;
        *)
            printf "  %-14s ${YELLOW}HTTP %s${NC}  %s\n" "HA:" "$HTTP" "$HA_URL" ;;
    esac

    if [ -n "$HA_TOKEN" ]; then
        SAT_ENTITY="assist_satellite.$(hostname | tr '[:upper:]' '[:lower:]' | tr '-' '_')_lva_assist_satellite"
        SAT_STATE=$(curl -sf --max-time 3 \
            -H "Authorization: Bearer $HA_TOKEN" \
            "${HA_URL}/api/states/${SAT_ENTITY}" \
            2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['state'])" 2>/dev/null)
        [ -n "$SAT_STATE" ] && printf "  %-14s %s\n" "Satellite:" "$SAT_STATE"
    fi
else
    printf "  %-14s not configured\n" "HA:"
fi
echo ""
