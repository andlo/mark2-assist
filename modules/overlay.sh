#!/bin/bash
# =============================================================================
# modules/overlay.sh
# Transparent volume/status overlay (Chromium app window)
#
# Can be run standalone: bash modules/overlay.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

section "Volume / Status Overlay"
echo "  Transparent on-screen overlay showing volume and Wyoming status."
echo "  Auto-hides after 3 seconds."
echo ""

if ! ask_yes_no "Install volume/status overlay?"; then
    log "Skipping volume overlay"
    exit 0
fi

OVERLAY_DIR="${USER_HOME}/.config/mark2-overlay"
mkdir -p "$OVERLAY_DIR"

cat > "${OVERLAY_DIR}/overlay.html" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    * { margin:0; padding:0; box-sizing:border-box; }
    body { background:transparent; overflow:hidden; font-family:system-ui,sans-serif; pointer-events:none; }
    #container {
      position:fixed; bottom:1.5rem; left:50%; transform:translateX(-50%);
      display:flex; flex-direction:column; align-items:center; gap:0.6rem;
      transition:opacity 0.4s ease; opacity:0;
    }
    #container.visible { opacity:1; }
    #status-pill {
      background:rgba(20,20,40,0.85); border:1px solid rgba(100,120,255,0.3);
      border-radius:2rem; padding:0.4rem 1.2rem; font-size:0.85rem; color:#c0c8ff;
      backdrop-filter:blur(8px); display:none;
    }
    #status-pill.visible { display:block; }
    #volume-bar-wrap {
      background:rgba(20,20,40,0.85); border:1px solid rgba(255,255,255,0.1);
      border-radius:2rem; padding:0.5rem 1.5rem;
      display:flex; align-items:center; gap:0.8rem;
      backdrop-filter:blur(8px); min-width:200px;
    }
    #vol-icon { font-size:1.1rem; }
    #vol-track { flex:1; height:4px; background:rgba(255,255,255,0.15); border-radius:2px; overflow:hidden; }
    #vol-fill { height:100%; background:linear-gradient(90deg,#4080ff,#80c0ff); border-radius:2px; transition:width 0.2s ease; width:0%; }
    #vol-pct { font-size:0.85rem; color:#9090c0; min-width:2.5rem; text-align:right; }
  </style>
</head>
<body>
  <div id="container">
    <div id="status-pill"></div>
    <div id="volume-bar-wrap">
      <span id="vol-icon">🔊</span>
      <div id="vol-track"><div id="vol-fill"></div></div>
      <span id="vol-pct">--</span>
    </div>
  </div>
  <script>
    const container=document.getElementById('container');
    const statusPill=document.getElementById('status-pill');
    const volFill=document.getElementById('vol-fill');
    const volPct=document.getElementById('vol-pct');
    const volIcon=document.getElementById('vol-icon');
    let hideTimer=null;

    function show(ms=3000) {
      container.classList.add('visible');
      clearTimeout(hideTimer);
      if(ms>0) hideTimer=setTimeout(()=>container.classList.remove('visible'),ms);
    }
    function setVolume(pct) {
      const v=Math.max(0,Math.min(100,pct));
      volFill.style.width=v+'%'; volPct.textContent=v+'%';
      volIcon.textContent=v===0?'🔇':v<40?'🔉':'🔊';
      show(3000);
    }
    function setStatus(text,persistent=false) {
      statusPill.textContent=text; statusPill.classList.add('visible');
      show(persistent?0:4000);
      if(!persistent) setTimeout(()=>statusPill.classList.remove('visible'),4000);
    }

    const bc=new BroadcastChannel('mark2-overlay');
    bc.onmessage=(e)=>{
      const {type,value}=e.data;
      if(type==='volume') setVolume(value);
      else if(type==='status') setStatus(value,false);
      else if(type==='status-persistent') setStatus(value,true);
      else if(type==='clear') { statusPill.classList.remove('visible'); container.classList.remove('visible'); }
    };

    // Poll event file written by mark2-overlay command
    setInterval(async ()=>{
      try {
        const r=await fetch('file:///tmp/mark2-overlay-event.json?'+Date.now());
        const d=await r.json();
        bc.dispatchEvent(new MessageEvent('message',{data:d}));
      } catch(e) {}
    }, 500);
  </script>
</body>
</html>
HTMLEOF

# mark2-overlay command
OVERLAY_TRIGGER="${USER_HOME}/.local/bin/mark2-overlay"
mkdir -p "$(dirname "$OVERLAY_TRIGGER")"
cat > "$OVERLAY_TRIGGER" << 'SHEOF'
#!/bin/bash
# Usage: mark2-overlay volume 75 | status "Listening..." | clear
echo "{\"type\":\"${1:-status}\",\"value\":\"${2:-}\"}" > /tmp/mark2-overlay-event.json
SHEOF
chmod +x "$OVERLAY_TRIGGER"

# Volume monitor service
VOLUME_MONITOR="${MARK2_DIR}/volume-monitor.sh"
cat > "$VOLUME_MONITOR" << 'SHEOF'
#!/bin/bash
LAST_VOL=""
while true; do
    SINK=$(pactl get-default-sink 2>/dev/null)
    VOL=$(pactl get-sink-volume "$SINK" 2>/dev/null | grep -oP '\d+(?=%)' | head -1)
    if [ -n "$VOL" ] && [ "$VOL" != "$LAST_VOL" ]; then
        mark2-overlay volume "$VOL" 2>/dev/null || true
        LAST_VOL="$VOL"
    fi
    sleep 1
done
SHEOF
chmod +x "$VOLUME_MONITOR"

cat > "${SYSTEMD_USER_DIR}/mark2-volume-monitor.service" << EOF
[Unit]
Description=Mark II Volume Monitor
After=pipewire.service
Wants=pipewire.service

[Service]
Type=simple
ExecStart=${VOLUME_MONITOR}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Add overlay window to labwc autostart
labwc_autostart_add "overlay.html" \
    "chromium --app=\"file://${OVERLAY_DIR}/overlay.html\" --window-size=400,120 --window-position=0,360 --ozone-platform=wayland --password-store=basic --no-first-run --disable-infobars --app-auto-launched &"

systemctl --user daemon-reload
systemctl --user enable mark2-volume-monitor.service

log "Volume overlay installed"
info "Trigger: mark2-overlay volume 75 | mark2-overlay status 'Listening...'"
