#!/usr/bin/env python3
"""
Mark II sensor bridge - publishes device status to Home Assistant via MQTT.

Uses HA MQTT auto-discovery so sensors appear automatically in HA
without any manual configuration.

Sensors published:
  - LVA state         (idle/listening/speaking/thinking)
  - MPD state           (playing/paused/stopped + track info)
  - MPD volume          (0-100)
  - CPU temperature     (°C)
  - CPU usage           (%)
  - Memory usage        (%)
  - Disk usage          (%)

Topic structure:
  Discovery:  homeassistant/sensor/mark2_<id>/<sensor>/config
  State:      mark2/<hostname>/state

Config: ~/.config/mark2/config (shared with install.sh)
  MQTT_HOST="192.168.1.x"
  MQTT_PORT="1883"
  MQTT_USER=""
  MQTT_PASS=""
"""

import json
import os
import socket
import subprocess
import time
import threading
import paho.mqtt.client as mqtt

# ── Config ──────────────────────────────────────────────────────────────
CONFIG_FILE = os.path.expanduser("~/.config/mark2/config")
STATE_DIR   = "/tmp"

POLL_INTERVAL    = 10     # seconds between system sensor updates
LVA_POLL         = 0.5    # seconds between LVA state checks
MPD_POLL         = 2.0    # seconds between MPD polls

# ── Helpers ─────────────────────────────────────────────────────────────

def load_config():
    cfg = {}
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip().strip('"')
    return cfg


def hostname():
    return socket.gethostname()


def device_id():
    """Stable device ID based on hostname."""
    return hostname().lower().replace("-", "_").replace(" ", "_")


# ── MQTT discovery payloads ──────────────────────────────────────────────

def discovery_payload(sensor_id, name, icon, unit=None, device_class=None,
                       state_class=None, value_template=None):
    dev_id   = device_id()
    dev_name = hostname()
    base = f"mark2/{dev_id}"

    payload = {
        "name":           f"{dev_name} {name}",
        "unique_id":      f"{dev_id}_{sensor_id}",
        "state_topic":    f"{base}/state",
        "value_template": value_template or f"{{{{ value_json.{sensor_id} }}}}",
        "icon":           icon,
        "device": {
            "identifiers":    [f"mark2_{dev_id}"],
            "name":           f"Mark II ({dev_name})",
            "model":          "Mycroft Mark II",
            "manufacturer":   "mark2-assist",
        },
        "availability_topic": f"{base}/availability",
    }
    if unit:          payload["unit_of_measurement"] = unit
    if device_class:  payload["device_class"]        = device_class
    if state_class:   payload["state_class"]         = state_class
    return payload


SENSORS = [
    ("lva_state", "LVA state",   "mdi:microphone",
     None, None, None, "{{ value_json.lva_state }}"),

    ("mpd_state",     "MPD state",       "mdi:music",
     None, None, None, "{{ value_json.mpd_state }}"),

    ("mpd_volume",    "MPD volume",      "mdi:volume-high",
     "%", None, "measurement", "{{ value_json.mpd_volume }}"),

    ("mpd_track",     "MPD track",       "mdi:music-note",
     None, None, None, "{{ value_json.mpd_track }}"),

    ("mpd_artist",    "MPD artist",      "mdi:account-music",
     None, None, None, "{{ value_json.mpd_artist }}"),

    ("cpu_temp",      "CPU temperature", "mdi:thermometer",
     "°C", "temperature", "measurement", "{{ value_json.cpu_temp }}"),

    ("cpu_usage",     "CPU usage",       "mdi:cpu-64-bit",
     "%", None, "measurement", "{{ value_json.cpu_usage }}"),

    ("memory_usage",  "Memory usage",    "mdi:memory",
     "%", None, "measurement", "{{ value_json.memory_usage }}"),

    ("disk_usage",    "Disk usage",      "mdi:harddisk",
     "%", None, "measurement", "{{ value_json.disk_usage }}"),
]


# ── System metrics ───────────────────────────────────────────────────────

def cpu_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read()) / 1000, 1)
    except Exception:
        return None


def cpu_usage():
    try:
        out = subprocess.check_output(
            ["top", "-bn1"], text=True, timeout=5
        )
        for line in out.splitlines():
            if "Cpu(s)" in line or "%Cpu" in line:
                parts = line.split()
                for i, p in enumerate(parts):
                    if "id" in p and i > 0:
                        idle = float(parts[i-1].replace(",", "."))
                        return round(100 - idle, 1)
    except Exception:
        pass
    return None


def memory_usage():
    try:
        with open("/proc/meminfo") as f:
            lines = f.readlines()
        info = {}
        for line in lines:
            parts = line.split()
            if len(parts) >= 2:
                info[parts[0].rstrip(":")] = int(parts[1])
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", 0)
        if total > 0:
            return round((total - avail) / total * 100, 1)
    except Exception:
        pass
    return None


def disk_usage():
    try:
        out = subprocess.check_output(["df", "-h", "/"], text=True)
        line = out.strip().splitlines()[-1]
        pct = line.split()[4].rstrip("%")
        return int(pct)
    except Exception:
        return None


# ── LVA state ────────────────────────────────────────────────────────

def read_lva_state():
    path = os.path.join(STATE_DIR, "mark2-face-event.json")
    try:
        with open(path) as f:
            d = json.load(f)
            return d.get("state", "idle")
    except Exception:
        return "idle"


# ── MPD state ────────────────────────────────────────────────────────────

def read_mpd_state():
    path = os.path.join(STATE_DIR, "mark2-mpd-state.json")
    try:
        with open(path) as f:
            d = json.load(f)
            return {
                "mpd_state":  d.get("state", "stop"),
                "mpd_track":  d.get("title",  ""),
                "mpd_artist": d.get("artist", ""),
                "mpd_volume": d.get("volume", 0),
            }
    except Exception:
        return {
            "mpd_state": "stop", "mpd_track": "",
            "mpd_artist": "", "mpd_volume": 0,
        }


# ── Main bridge ──────────────────────────────────────────────────────────

class Mark2Bridge:
    def __init__(self):
        self.cfg     = load_config()
        self.dev_id  = device_id()
        self.base    = f"mark2/{self.dev_id}"
        self.client  = None
        self.running = True
        self._last_lva = None
        self._last_mpd     = None

    def connect(self):
        host = self.cfg.get("MQTT_HOST", "localhost")
        port = int(self.cfg.get("MQTT_PORT", "1883"))
        user = self.cfg.get("MQTT_USER", "")
        pwd  = self.cfg.get("MQTT_PASS", "")

        self.client = mqtt.Client(
            client_id=f"mark2-{self.dev_id}",
            clean_session=True,
        )
        self.client.will_set(
            f"{self.base}/availability", "offline", retain=True
        )
        if user:
            self.client.username_pw_set(user, pwd)

        self.client.on_connect    = self._on_connect
        self.client.on_disconnect = self._on_disconnect

        print(f"[MQTT] Connecting to {host}:{port}")
        self.client.connect(host, port, keepalive=60)
        self.client.loop_start()

    def _on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            print("[MQTT] Connected")
            self._publish_discovery()
            client.publish(
                f"{self.base}/availability", "online", retain=True
            )
        else:
            print(f"[MQTT] Connect failed: rc={rc}")

    def _on_disconnect(self, client, userdata, rc):
        print(f"[MQTT] Disconnected: rc={rc}")

    def _publish_discovery(self):
        for args in SENSORS:
            sid = args[0]
            payload = discovery_payload(*args)
            topic = f"homeassistant/sensor/{self.dev_id}_{sid}/config"
            self.client.publish(topic, json.dumps(payload), retain=True)
            print(f"[MQTT] Discovery: {sid}")

    def publish_state(self, state: dict):
        if self.client and self.client.is_connected():
            self.client.publish(
                f"{self.base}/state",
                json.dumps(state),
                retain=False,
            )

    def run(self):
        self.connect()

        # Give connection a moment
        time.sleep(2)

        # Initialise system metrics so they are always present in every
        # published payload. HA's value_template raises an error if a key
        # is missing — None serialises as JSON null which HA handles fine.
        sys_metrics = {
            "cpu_temp":     None,
            "cpu_usage":    None,
            "memory_usage": None,
            "disk_usage":   None,
        }
        last_system_update = 0

        while self.running:
            now = time.time()

            # System metrics — update every POLL_INTERVAL seconds
            if now - last_system_update > POLL_INTERVAL:
                sys_metrics["cpu_temp"]     = cpu_temp()
                sys_metrics["cpu_usage"]    = cpu_usage()
                sys_metrics["memory_usage"] = memory_usage()
                sys_metrics["disk_usage"]   = disk_usage()
                last_system_update          = now

            # LVA state
            lva_state = read_lva_state()
            self._last_lva = lva_state

            # MPD state
            mpd = read_mpd_state()

            # Build flat payload — all keys always present
            state = {
                "lva_state": lva_state,
                **mpd,
                **sys_metrics,
            }

            self.publish_state(state)
            time.sleep(LVA_POLL)

    def stop(self):
        self.running = False
        if self.client:
            self.client.publish(
                f"{self.base}/availability", "offline", retain=True
            )
            self.client.loop_stop()
            self.client.disconnect()


def main():
    import signal
    bridge = Mark2Bridge()

    def shutdown(sig, frame):
        print("\n[MQTT] Shutting down...")
        bridge.stop()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT,  shutdown)

    bridge.run()


if __name__ == "__main__":
    main()
