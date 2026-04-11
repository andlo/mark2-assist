#!/bin/bash
# =============================================================================
# modules/leds.sh
# SJ201 LED ring control for Wyoming satellite events
#
# Can be run standalone: bash modules/leds.sh
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

check_not_root
setup_paths

module_header "LED Ring Control" "SJ201 LED ring follows Wyoming satellite state"


if ! confirm_or_skip "Install LED ring control?"; then
    log "Skipping LED control"
    exit 0
fi

sudo apt-get install -y --no-install-recommends \
    python3-spidev \
    python3-libgpiod \
    python3-smbus2 \
    i2c-tools

LED_SCRIPT="${MARK2_DIR}/led_control.py"
LED_EVENT_SCRIPT="${MARK2_DIR}/led_event_handler.py"

# --- LED controller ---
cat > "$LED_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
Mark II SJ201 LED ring controller.
Listens on a Unix socket for state changes.
States: idle, wake, listen, think, speak, error, mute, volume
"""
import smbus2, time, threading, socket, os, sys, signal

I2C_BUS = 1
I2C_ADDR = 0x04
NUM_LEDS = 12
SOCKET_PATH = "/tmp/mark2-leds.sock"

class SJ201LEDs:
    def __init__(self):
        try:
            self.bus = smbus2.SMBus(I2C_BUS)
            self.available = True
        except Exception as e:
            print(f"[LED] I2C not available: {e}", file=sys.stderr)
            self.available = False
        self._stop = threading.Event()
        self._thread = None

    def _write(self, data):
        if not self.available: return
        try:
            payload = [v for rgb in data for v in rgb]
            self.bus.write_i2c_block_data(I2C_ADDR, 0x00, payload[:32])
            if len(payload) > 32:
                self.bus.write_i2c_block_data(I2C_ADDR, 0x20, payload[32:])
        except Exception as e:
            print(f"[LED] Write error: {e}", file=sys.stderr)

    def _stop_animation(self):
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
        self._stop.clear()

    def _animate(self, func):
        self._stop_animation()
        self._thread = threading.Thread(target=func, daemon=True)
        self._thread.start()

    def off(self):
        self._stop_animation()
        self._write([(0,0,0)] * NUM_LEDS)

    def solid(self, r, g, b):
        self._stop_animation()
        self._write([(r,g,b)] * NUM_LEDS)

    def pulse(self, r, g, b, speed=0.03):
        def _run():
            while not self._stop.is_set():
                for i in list(range(0,100,3)) + list(range(100,0,-3)):
                    if self._stop.is_set(): return
                    f = i/100.0
                    self._write([(int(r*f),int(g*f),int(b*f))]*NUM_LEDS)
                    time.sleep(speed)
        self._animate(_run)

    def spin(self, r, g, b, speed=0.05):
        def _run():
            pos = 0
            while not self._stop.is_set():
                leds = [(0,0,0)] * NUM_LEDS
                for i in range(4):
                    fade = max(0, 1.0 - i*0.25)
                    leds[(pos-i) % NUM_LEDS] = (int(r*fade),int(g*fade),int(b*fade))
                self._write(leds)
                pos = (pos+1) % NUM_LEDS
                time.sleep(speed)
        self._animate(_run)

    def flash(self, r, g, b, count=3, speed=0.15):
        def _run():
            for _ in range(count):
                if self._stop.is_set(): return
                self._write([(r,g,b)]*NUM_LEDS); time.sleep(speed)
                self._write([(0,0,0)]*NUM_LEDS); time.sleep(speed)
        self._animate(_run)


STATE_MAP = {
    "idle":   lambda l: l.off(),
    "wake":   lambda l: l.pulse(0, 50, 255, speed=0.02),
    "listen": lambda l: l.solid(0, 80, 255),
    "think":  lambda l: l.spin(0, 200, 200, speed=0.04),
    "speak":  lambda l: l.solid(0, 180, 50),
    "error":  lambda l: l.flash(255, 0, 0, count=4),
    "mute":   lambda l: l.solid(40, 20, 0),
    "volume": lambda l: l.pulse(0, 100, 100, speed=0.05),
}

def main():
    leds = SJ201LEDs()
    leds.off()
    if os.path.exists(SOCKET_PATH): os.unlink(SOCKET_PATH)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o666)
    server.listen(5)
    server.settimeout(1.0)
    print(f"[LED] Listening on {SOCKET_PATH}")

    def shutdown(sig, frame):
        leds.off(); server.close()
        if os.path.exists(SOCKET_PATH): os.unlink(SOCKET_PATH)
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    while True:
        try:
            conn, _ = server.accept()
            state = conn.recv(64).decode("utf-8", errors="ignore").strip().lower()
            conn.close()
            if state:
                print(f"[LED] State: {state}")
                if state in STATE_MAP: STATE_MAP[state](leds)
                else: print(f"[LED] Unknown state: {state}", file=sys.stderr)
        except socket.timeout: continue
        except Exception as e: print(f"[LED] Error: {e}", file=sys.stderr)

if __name__ == "__main__": main()
PYEOF
chmod +x "$LED_SCRIPT"

# --- Wyoming event bridge ---
cat > "$LED_EVENT_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""Wyoming satellite event bridge -> LED socket."""
import json, socket, sys

SOCKET_PATH = "/tmp/mark2-leds.sock"
EVENT_MAP = {
    "detect": "wake", "detection": "listen",
    "streaming-start": "listen", "streaming-stop": "think",
    "transcript": "think", "synthesize": "speak",
    "tts-start": "speak", "tts-played": "idle",
    "error": "error", "connected": "idle", "disconnected": "error",
}

def send(state):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(SOCKET_PATH); s.sendall(state.encode()); s.close()
    except Exception as e:
        print(f"[EVENT] {e}", file=sys.stderr)

send("idle")
for line in sys.stdin:
    try:
        event = json.loads(line.strip())
        state = EVENT_MAP.get(event.get("type",""))
        if state: send(state)
    except Exception as e:
        print(f"[EVENT] Parse error: {e}", file=sys.stderr)
PYEOF
chmod +x "$LED_EVENT_SCRIPT"

# --- Systemd services ---
cat > "${SYSTEMD_USER_DIR}/mark2-leds.service" << EOF
[Unit]
Description=Mark II LED Ring Controller
After=sj201.service
Requires=sj201.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${LED_SCRIPT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

cat > "${SYSTEMD_USER_DIR}/mark2-led-events.service" << EOF
[Unit]
Description=Mark II LED Event Bridge
After=wyoming-satellite.service mark2-leds.service
Requires=mark2-leds.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${LED_EVENT_SCRIPT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Patch wyoming-satellite service to emit events
WYOMING_SERVICE="${SYSTEMD_USER_DIR}/wyoming-satellite.service"
if [ -f "$WYOMING_SERVICE" ]; then
    if ! grep -q "event-uri" "$WYOMING_SERVICE"; then
        sed -i "s|--wake-word-name.*|&  \\\\\n    --event-uri 'tcp://127.0.0.1:10500'|" "$WYOMING_SERVICE"
        log "Patched wyoming-satellite.service with --event-uri"
    else
        log "wyoming-satellite.service already has --event-uri"
    fi
else
    warn "wyoming-satellite.service not found - run mark2-satellite-setup.sh first"
    warn "Manually add: --event-uri 'tcp://127.0.0.1:10500' to ExecStart"
fi

systemctl --user daemon-reload
systemctl --user enable mark2-leds.service mark2-led-events.service

log "LED ring control installed"
info "Test: echo 'listen' | socat - UNIX-CONNECT:/tmp/mark2-leds.sock"
info "States: idle, wake, listen, think, speak, error, mute, volume"
