#!/bin/bash
# =============================================================================
# modules/screensaver.sh
# Fullscreen clock + weather screensaver via swayidle
#
# Can be run standalone: bash modules/screensaver.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

section "Screensaver - Clock + Weather"
echo "  Displays a fullscreen clock with weather info from Home Assistant."
echo "  Activates after 2 minutes of inactivity. Touch screen to dismiss."
echo ""
echo "  Requires a Home Assistant long-lived access token."
echo "  Get one at: HA Profile page > Long-Lived Access Tokens"
echo ""

if ! ask_yes_no "Install clock/weather screensaver?"; then
    log "Skipping screensaver"
    exit 0
fi

HA_URL="${HA_URL:-}"
HA_TOKEN="${HA_TOKEN:-}"
HA_WEATHER_ENTITY="${HA_WEATHER_ENTITY:-weather.home}"

[ -z "$HA_URL" ]   && read -rp "Home Assistant URL (e.g. http://192.168.1.100:8123): " HA_URL
[ -z "$HA_TOKEN" ] && read -rp "HA Long-Lived Access Token: " HA_TOKEN
read -rp "Weather entity [weather.home]: " _W
[ -n "$_W" ] && HA_WEATHER_ENTITY="$_W"

sudo apt-get install -y --no-install-recommends \
    swayidle \
    wlr-randr

SCREENSAVER_DIR="${USER_HOME}/.config/mark2-screensaver"
mkdir -p "$SCREENSAVER_DIR"

cat > "${SCREENSAVER_DIR}/screensaver.html" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Mark II Screensaver</title>
  <style>
    * { margin:0; padding:0; box-sizing:border-box; }
    body {
      background:#0a0a0f; color:#e8e8f0;
      font-family:'Segoe UI',system-ui,sans-serif;
      height:100vh; display:flex; flex-direction:column;
      align-items:center; justify-content:center;
      overflow:hidden; cursor:none;
    }
    #clock { font-size:5rem; font-weight:200; letter-spacing:0.05em; color:#fff; text-shadow:0 0 40px rgba(100,150,255,0.3); }
    #date  { font-size:1.3rem; font-weight:300; color:#9090b0; margin-top:0.4rem; letter-spacing:0.15em; text-transform:uppercase; }
    #weather { margin-top:2.5rem; display:flex; align-items:center; gap:1.2rem; background:rgba(255,255,255,0.05); border:1px solid rgba(255,255,255,0.08); border-radius:1rem; padding:1rem 2rem; }
    #weather-icon { font-size:2.5rem; }
    #weather-info { display:flex; flex-direction:column; gap:0.2rem; }
    #weather-temp { font-size:1.8rem; font-weight:300; }
    #weather-condition { font-size:0.9rem; color:#9090b0; text-transform:capitalize; }
    #weather-extra { font-size:0.8rem; color:#6070a0; margin-top:0.3rem; }
    #status { position:fixed; bottom:1rem; font-size:0.7rem; color:#303050; }
  </style>
</head>
<body>
  <div id="clock">00:00:00</div>
  <div id="date">Loading...</div>
  <div id="weather">
    <div id="weather-icon">🌡️</div>
    <div id="weather-info">
      <div id="weather-temp">--°</div>
      <div id="weather-condition">Loading weather...</div>
      <div id="weather-extra"></div>
    </div>
  </div>
  <div id="status">Mark II</div>
  <script>
    const HA_URL='${HA_URL}', HA_TOKEN='${HA_TOKEN}', WEATHER_ENTITY='${HA_WEATHER_ENTITY}';
    const ICONS={'clear-night':'🌙','cloudy':'☁️','fog':'🌫️','hail':'🌨️','lightning':'⛈️',
      'lightning-rainy':'⛈️','partlycloudy':'⛅','pouring':'🌧️','rainy':'🌦️','snowy':'❄️',
      'snowy-rainy':'🌨️','sunny':'☀️','windy':'💨','windy-variant':'🌬️','exceptional':'⚡'};
    const days=['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
    const months=['January','February','March','April','May','June','July','August','September','October','November','December'];

    function updateClock() {
      const n=new Date();
      document.getElementById('clock').textContent=
        String(n.getHours()).padStart(2,'0')+':'+String(n.getMinutes()).padStart(2,'0')+':'+String(n.getSeconds()).padStart(2,'0');
      document.getElementById('date').textContent=
        days[n.getDay()]+' · '+n.getDate()+' '+months[n.getMonth()]+' '+n.getFullYear();
    }

    async function updateWeather() {
      try {
        const r=await fetch(HA_URL+'/api/states/'+WEATHER_ENTITY,{headers:{'Authorization':'Bearer '+HA_TOKEN}});
        if(!r.ok) throw new Error('HTTP '+r.status);
        const d=await r.json(), a=d.attributes;
        document.getElementById('weather-icon').textContent=ICONS[d.state]||'🌡️';
        document.getElementById('weather-temp').textContent=Math.round(a.temperature)+'°'+(a.temperature_unit||'C');
        document.getElementById('weather-condition').textContent=d.state.replace(/-/g,' ');
        document.getElementById('weather-extra').textContent='Humidity: '+(a.humidity||'--')+'%  ·  Wind: '+Math.round(a.wind_speed||0)+' '+(a.wind_speed_unit||'km/h');
        document.getElementById('status').textContent='Mark II · Updated '+new Date().toLocaleTimeString();
      } catch(e) {
        document.getElementById('weather-condition').textContent='Weather unavailable';
      }
    }

    setInterval(updateClock,1000); updateClock();
    updateWeather(); setInterval(updateWeather,300000);
    document.addEventListener('click',()=>history.back());
    document.addEventListener('touchstart',()=>history.back());
  </script>
</body>
</html>
HTMLEOF
log "Created screensaver: ${SCREENSAVER_DIR}/screensaver.html"

SWAYIDLE_CONF="${USER_HOME}/.config/swayidle/config"
mkdir -p "$(dirname "$SWAYIDLE_CONF")"
SCREENSAVER_URL="file://${SCREENSAVER_DIR}/screensaver.html"

cat > "$SWAYIDLE_CONF" << EOF
# Mark II screensaver - activates after 2 minutes idle
timeout 120 'chromium --app="${SCREENSAVER_URL}" --kiosk --ozone-platform=wayland --password-store=basic --no-first-run --disable-infobars 2>/dev/null &'
    resume 'pkill -f "screensaver.html" 2>/dev/null; true'
EOF

# Add swayidle to labwc autostart
labwc_autostart_add "swayidle" "swayidle -w &"

log "Screensaver configured (activates after 2 min idle)"
info "Change timeout: edit ${SWAYIDLE_CONF}"
