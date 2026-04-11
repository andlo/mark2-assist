#!/bin/bash
# =============================================================================
# mark2-extras-setup.sh
# Mycroft Mark II - Extra audio services + screensaver
#
# Run this AFTER mark2-satellite-setup.sh
#
# What this script installs (all optional, prompted):
#   [1] Snapcast client  - multiroom audio, synced playback from Snapcast server
#   [2] AirPlay receiver - shairport-sync (AirPlay 1, works on Trixie with caveats)
#   [3] Screensaver      - clock + weather HTML page via labwc swayidle
#
# Requirements:
#   - mark2-hardware-setup.sh + mark2-satellite-setup.sh run first
#   - Raspberry Pi OS Trixie
#   - sudo access
#
# Usage:
#   chmod +x mark2-extras-setup.sh
#   ./mark2-extras-setup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()     { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    die "Do not run as root directly."
fi

CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Home Assistant URL and token for weather screensaver
HA_URL="${HA_URL:-}"
HA_TOKEN="${HA_TOKEN:-}"           # Long-lived access token from HA profile page
HA_WEATHER_ENTITY="${HA_WEATHER_ENTITY:-weather.home}"  # HA weather entity

# Snapcast server hostname or IP
SNAPCAST_HOST="${SNAPCAST_HOST:-}"

# AirPlay device name shown on Apple devices
AIRPLAY_NAME="${AIRPLAY_NAME:-Mark II}"

# =============================================================================
# HELPERS
# =============================================================================

ask_yes_no() {
    local prompt="$1"
    local answer
    read -rp "${prompt} [y/N]: " answer
    [[ "${answer,,}" == "y" ]]
}

# =============================================================================
# SNAPCAST CLIENT
# =============================================================================

install_snapcast_client() {
    section "Snapcast Client"
    echo "  Snapcast turns Mark II into a synchronized multiroom audio endpoint."
    echo "  Requires a Snapcast server already running on your network (or NAS/HA)."
    echo "  In Home Assistant the 'Snapcast' integration shows Mark II as a media player."
    echo ""

    if ! ask_yes_no "Install Snapcast client?"; then
        log "Skipping Snapcast"
        return
    fi

    if [ -z "$SNAPCAST_HOST" ]; then
        read -rp "Snapcast server IP or hostname: " SNAPCAST_HOST
        [ -z "$SNAPCAST_HOST" ] && die "Snapcast server host required"
    fi

    # Download latest Trixie arm64 .deb with PipeWire support
    section "Downloading Snapcast for Trixie (arm64, PipeWire)"

    # Get latest release version from GitHub API
    SNAPCAST_VERSION=$(curl -s https://api.github.com/repos/badaix/snapcast/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')

    if [ -z "$SNAPCAST_VERSION" ]; then
        warn "Could not fetch latest version - using 0.35.0"
        SNAPCAST_VERSION="0.35.0"
    fi
    log "Snapcast version: ${SNAPCAST_VERSION}"

    DEB_FILE="snapclient_${SNAPCAST_VERSION}-1_arm64_trixie_with-pipewire.deb"
    DEB_URL="https://github.com/badaix/snapcast/releases/download/v${SNAPCAST_VERSION}/${DEB_FILE}"

    TMP_DEB="/tmp/${DEB_FILE}"
    curl -fsSL "$DEB_URL" -o "$TMP_DEB" || die "Failed to download: ${DEB_URL}"

    sudo apt-get install -y --no-install-recommends avahi-daemon
    sudo dpkg -i "$TMP_DEB" || sudo apt-get install -f -y
    rm -f "$TMP_DEB"

    # Disable system snapclient service - run as user instead
    # so PipeWire is already running when snapclient starts
    sudo systemctl disable --now snapclient.service 2>/dev/null || true

    # Create user service
    cat > "${SYSTEMD_USER_DIR}/snapclient.service" << EOF
[Unit]
Description=Snapcast Client
After=network-online.target pipewire.service wireplumber.service sj201.service
Wants=pipewire.service

[Service]
Type=simple
ExecStart=/usr/bin/snapclient \\
    --logsink=system \\
    --player pipewire \\
    --host ${SNAPCAST_HOST}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable snapclient.service
    log "Snapcast client installed and enabled"
    log "Mark II will appear in Home Assistant Snapcast integration"
    log "Server: ${SNAPCAST_HOST}"
}

# =============================================================================
# AIRPLAY (SHAIRPORT-SYNC)
# =============================================================================

install_airplay() {
    section "AirPlay Receiver (shairport-sync)"
    echo "  Makes Mark II visible as an AirPlay speaker on your network."
    echo "  Works with iPhone, iPad, Mac, and any AirPlay-compatible app."
    echo ""
    echo "  NOTE: shairport-sync has known issues on Trixie with PipeWire."
    echo "  It works, but may occasionally lose timing sync."
    echo "  AirPlay 1 only - AirPlay 2 requires additional setup."
    echo ""

    if ! ask_yes_no "Install AirPlay receiver?"; then
        log "Skipping AirPlay"
        return
    fi

    sudo apt-get install -y --no-install-recommends \
        shairport-sync \
        avahi-daemon \
        libavahi-client3

    # Configure shairport-sync for PipeWire + user service
    SHAIRPORT_CONF="/etc/shairport-sync.conf"

    sudo tee "$SHAIRPORT_CONF" > /dev/null << EOF
// shairport-sync configuration for Mark II
general = {
    name = "${AIRPLAY_NAME}";
    output_backend = "pw";      // PipeWire
    mdns_backend = "avahi";
    allow_session_interruption = "yes";
    session_timeout = 20;
};

pw = {
    // Use default PipeWire sink (SJ201 via WirePlumber)
};

sessioncontrol = {
    allow_session_interruption = "yes";
    session_timeout = 20;
};
EOF
    log "Created shairport-sync config: ${SHAIRPORT_CONF}"

    # Fix dbus policy for Trixie path
    DBUS_POLICY_DIR="/usr/share/dbus-1/system.d"
    if [ ! -f "${DBUS_POLICY_DIR}/shairport-sync-dbus-policy.conf" ]; then
        sudo tee "${DBUS_POLICY_DIR}/shairport-sync-dbus-policy.conf" > /dev/null << EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="${CURRENT_USER}">
    <allow own="org.gnome.ShairportSync"/>
    <allow own="org.mpris.MediaPlayer2.ShairportSync"/>
  </policy>
</busconfig>
EOF
        sudo systemctl reload dbus 2>/dev/null || true
    fi

    # Create user systemd service (avoids root/PipeWire conflicts)
    cat > "${SYSTEMD_USER_DIR}/shairport-sync.service" << EOF
[Unit]
Description=AirPlay receiver (shairport-sync)
After=network-online.target pipewire.service wireplumber.service sj201.service
Wants=pipewire.service

[Service]
Type=simple
ExecStart=/usr/bin/shairport-sync
Restart=on-failure
RestartSec=10
# Required for PipeWire access
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$CURRENT_USER")
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$CURRENT_USER")/bus

[Install]
WantedBy=default.target
EOF

    # Disable system service - use user service instead
    sudo systemctl disable --now shairport-sync.service 2>/dev/null || true

    systemctl --user daemon-reload
    systemctl --user enable shairport-sync.service
    log "AirPlay receiver installed as user service"
    log "Mark II will appear as '${AIRPLAY_NAME}' on your AirPlay devices"
}

# =============================================================================
# SCREENSAVER - Clock + Weather
# =============================================================================

install_screensaver() {
    section "Screensaver - Clock + Weather"
    echo "  Displays a fullscreen clock with weather info from Home Assistant."
    echo "  Activates after 2 minutes of inactivity."
    echo "  Touch screen to return to HA dashboard."
    echo ""
    echo "  Requires a Home Assistant long-lived access token."
    echo "  Get one at: HA Profile page > Long-Lived Access Tokens"
    echo ""

    if ! ask_yes_no "Install clock/weather screensaver?"; then
        log "Skipping screensaver"
        return
    fi

    if [ -z "$HA_URL" ]; then
        read -rp "Home Assistant URL (e.g. http://192.168.1.100:8123): " HA_URL
    fi
    if [ -z "$HA_TOKEN" ]; then
        read -rp "HA Long-Lived Access Token: " HA_TOKEN
    fi
    read -rp "Weather entity (default: weather.home): " HA_WEATHER_INPUT
    [ -n "$HA_WEATHER_INPUT" ] && HA_WEATHER_ENTITY="$HA_WEATHER_INPUT"

    # Install swayidle for Wayland idle detection
    sudo apt-get install -y --no-install-recommends \
        swayidle \
        wlr-randr

    # Create screensaver HTML page
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
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #0a0a0f;
      color: #e8e8f0;
      font-family: 'Segoe UI', system-ui, sans-serif;
      height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      overflow: hidden;
      cursor: none;
    }
    #clock {
      font-size: 5rem;
      font-weight: 200;
      letter-spacing: 0.05em;
      color: #ffffff;
      text-shadow: 0 0 40px rgba(100,150,255,0.3);
    }
    #date {
      font-size: 1.3rem;
      font-weight: 300;
      color: #9090b0;
      margin-top: 0.4rem;
      letter-spacing: 0.15em;
      text-transform: uppercase;
    }
    #weather {
      margin-top: 2.5rem;
      display: flex;
      align-items: center;
      gap: 1.2rem;
      background: rgba(255,255,255,0.05);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 1rem;
      padding: 1rem 2rem;
    }
    #weather-icon { font-size: 2.5rem; }
    #weather-info { display: flex; flex-direction: column; gap: 0.2rem; }
    #weather-temp { font-size: 1.8rem; font-weight: 300; }
    #weather-condition { font-size: 0.9rem; color: #9090b0; text-transform: capitalize; }
    #weather-extra { font-size: 0.8rem; color: #6070a0; margin-top: 0.3rem; }
    #status { position: fixed; bottom: 1rem; font-size: 0.7rem; color: #303050; }
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
    const HA_URL = '${HA_URL}';
    const HA_TOKEN = '${HA_TOKEN}';
    const WEATHER_ENTITY = '${HA_WEATHER_ENTITY}';

    // Weather icons map
    const weatherIcons = {
      'clear-night': '🌙', 'cloudy': '☁️', 'exceptional': '⚡',
      'fog': '🌫️', 'hail': '🌨️', 'lightning': '⛈️',
      'lightning-rainy': '⛈️', 'partlycloudy': '⛅',
      'pouring': '🌧️', 'rainy': '🌦️', 'snowy': '❄️',
      'snowy-rainy': '🌨️', 'sunny': '☀️', 'windy': '💨',
      'windy-variant': '🌬️',
    };

    function updateClock() {
      const now = new Date();
      const h = String(now.getHours()).padStart(2,'0');
      const m = String(now.getMinutes()).padStart(2,'0');
      const s = String(now.getSeconds()).padStart(2,'0');
      document.getElementById('clock').textContent = h + ':' + m + ':' + s;

      const days = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
      const months = ['January','February','March','April','May','June',
                      'July','August','September','October','November','December'];
      document.getElementById('date').textContent =
        days[now.getDay()] + ' · ' + now.getDate() + ' ' + months[now.getMonth()] + ' ' + now.getFullYear();
    }

    async function updateWeather() {
      try {
        const resp = await fetch(HA_URL + '/api/states/' + WEATHER_ENTITY, {
          headers: { 'Authorization': 'Bearer ' + HA_TOKEN }
        });
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        const data = await resp.json();
        const attr = data.attributes;
        const state = data.state;

        document.getElementById('weather-icon').textContent =
          weatherIcons[state] || '🌡️';
        document.getElementById('weather-temp').textContent =
          Math.round(attr.temperature) + '°' + (attr.temperature_unit || 'C');
        document.getElementById('weather-condition').textContent =
          state.replace(/-/g,' ');
        document.getElementById('weather-extra').textContent =
          'Humidity: ' + (attr.humidity || '--') + '%' +
          '  ·  Wind: ' + Math.round(attr.wind_speed || 0) + ' ' + (attr.wind_speed_unit || 'km/h');
        document.getElementById('status').textContent =
          'Mark II · Updated ' + new Date().toLocaleTimeString();
      } catch(e) {
        document.getElementById('weather-condition').textContent = 'Weather unavailable';
        document.getElementById('status').textContent = 'Mark II · ' + e.message;
      }
    }

    // Update clock every second
    setInterval(updateClock, 1000);
    updateClock();

    // Update weather every 5 minutes
    updateWeather();
    setInterval(updateWeather, 300000);

    // Return to HA on any touch/click
    document.addEventListener('click', () => { history.back(); });
    document.addEventListener('touchstart', () => { history.back(); });
  </script>
</body>
</html>
HTMLEOF
    log "Created screensaver: ${SCREENSAVER_DIR}/screensaver.html"

    # Create swayidle config - activates after 2 minutes
    SWAYIDLE_CONF="${USER_HOME}/.config/swayidle/config"
    mkdir -p "$(dirname "$SWAYIDLE_CONF")"

    SCREENSAVER_URL="file://${SCREENSAVER_DIR}/screensaver.html"

    cat > "$SWAYIDLE_CONF" << EOF
# Mark II screensaver - activates after 2 minutes idle
timeout 120 'chromium --app="${SCREENSAVER_URL}" --kiosk --ozone-platform=wayland --password-store=basic --no-first-run --disable-infobars 2>/dev/null &'
    resume 'pkill -f "screensaver.html" 2>/dev/null; true'
EOF
    log "Created swayidle config: ${SWAYIDLE_CONF}"

    # Add swayidle to labwc autostart
    LABWC_AUTOSTART="${USER_HOME}/.config/labwc/autostart"
    mkdir -p "$(dirname "$LABWC_AUTOSTART")"
    grep -v "swayidle" "$LABWC_AUTOSTART" 2>/dev/null > /tmp/labwc_tmp || true
    mv /tmp/labwc_tmp "$LABWC_AUTOSTART" 2>/dev/null || true
    echo "swayidle -w &" >> "$LABWC_AUTOSTART"
    log "Added swayidle to labwc autostart"

    # Disable screen power off - keep display on always
    if ! grep -q "dpms_timeout" "${USER_HOME}/.config/labwc/rc.xml" 2>/dev/null; then
        warn "Consider setting dpms_timeout=0 in ~/.config/labwc/rc.xml to prevent display sleep"
    fi

    log "Screensaver configured"
    log "Screensaver activates after 2 minutes idle - touch screen to return to HA"
    log "To change timeout: edit ${SWAYIDLE_CONF}"
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
    section "Setup complete"
    echo ""
    echo "  Installed services:"
    systemctl --user list-unit-files 2>/dev/null | grep -E "snapclient|shairport|wyoming" | \
        awk '{print "  · " $1 " (" $2 ")"}' || true
    echo ""
    echo "  Next steps:"
    echo "  1. Reboot: sudo reboot"
    echo "  2. Home Assistant integrations to add:"
    echo "     · Wyoming Protocol (voice satellite)"
    [ -n "$SNAPCAST_HOST" ] && echo "     · Snapcast (multiroom audio)"
    echo "     · AirPlay appears automatically via mDNS"
    echo ""
    echo "  Screensaver: activates after 2 min idle, touch to dismiss"
    echo "  Weather entity: ${HA_WEATHER_ENTITY}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo "========================================"
echo "  Mark II Extras Setup"
echo "  User: ${CURRENT_USER}"
echo "========================================"
echo ""
echo "  Select which extras to install."
echo "  Each will be prompted individually."
echo ""

install_snapcast_client
install_airplay
install_screensaver
print_summary
