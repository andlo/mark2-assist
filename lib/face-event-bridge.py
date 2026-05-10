#!/usr/bin/env python3
"""
lib/face-event-bridge.py — Mark II face and kiosk config bridge.

Polls the Home Assistant assist_satellite entity state and writes:
  /tmp/mark2-face-event.json    — current voice state for face.html
  /tmp/mark2-kiosk-config.json  — kiosk settings (screensaver timeout)

The kiosk config is read from LVA preferences or HA entity state so that
the screensaver timeout can be configured from the HA UI without SSH.

HA satellite states → face states:
  idle       → idle
  listening  → listen
  processing → think
  responding → speak

Config (~/.config/mark2/config):
  HA_URL=http://homeassistant.local
  HA_TOKEN=<long-lived access token>
  SATELLITE_NAME=<hostname>     (optional, auto-detected)
  SCREEN_BLANK_SECONDS=300      (optional, also readable from HA entity)
"""
import json, os, time, urllib.request, urllib.error

FACE_OUT   = "/tmp/mark2-face-event.json"
CONFIG_OUT = "/tmp/mark2-kiosk-config.json"
CONFIG_FILE = os.path.expanduser("~/.config/mark2/config")
POLL_INTERVAL = 0.5  # seconds
CONFIG_POLL_INTERVAL = 30  # re-read HA config every 30s

HA_STATE_MAP = {
    "idle":       "idle",
    "listening":  "listen",
    "processing": "think",
    "responding": "speak",
}


def load_config():
    cfg = {}
    try:
        with open(CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    cfg[k.strip()] = v.strip().strip('"').strip("'")
    except Exception:
        pass
    return cfg


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def get_ha(ha_url, token, path):
    url = f"{ha_url.rstrip('/')}{path}"
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.load(r)
    except Exception:
        return None


def get_satellite_state(ha_url, token, entity_id):
    data = get_ha(ha_url, token, f"/api/states/{entity_id}")
    if data:
        return data.get("state", "idle")
    return None


def find_entity(ha_url, token, hostname):
    """Try common entity ID patterns for this satellite."""
    slug = hostname.lower().replace("-", "_").replace(" ", "_")
    candidates = [
        f"assist_satellite.{slug}_lva_assist_satellite",
        f"assist_satellite.{slug}",
        f"assist_satellite.{slug}_assist_satellite",
    ]
    for eid in candidates:
        state = get_satellite_state(ha_url, token, eid)
        if state is not None:
            return eid
    # Fall back to listing all entities
    data = get_ha(ha_url, token, "/api/states")
    if data:
        for item in data:
            eid = item.get("entity_id", "")
            if eid.startswith("assist_satellite.") and slug in eid:
                return eid
    return None


def get_screensaver_timeout(ha_url, token, cfg):
    """
    Read screensaver timeout from HA number entity if available,
    otherwise fall back to config file value.

    The HA entity (if it exists) is named:
      number.<satellite_slug>_screensaver_timeout
    or read from the SCREEN_BLANK_SECONDS config key.
    """
    # Config file takes priority if explicitly set
    if "SCREEN_BLANK_SECONDS" in cfg:
        try:
            return int(cfg["SCREEN_BLANK_SECONDS"])
        except ValueError:
            pass

    # Try HA entity
    hostname = cfg.get("SATELLITE_NAME", os.uname().nodename)
    slug = hostname.lower().replace("-", "_").replace(" ", "_")
    entity_id = f"number.{slug}_screensaver_timeout"
    data = get_ha(ha_url, token, f"/api/states/{entity_id}")
    if data:
        try:
            return int(float(data.get("state", "300")))
        except (ValueError, TypeError):
            pass

    return 300  # default 5 minutes


def write_state(state):
    write_json(FACE_OUT, {"state": state, "ts": time.time()})


def write_kiosk_config(screen_blank_seconds):
    write_json(CONFIG_OUT, {
        "screen_blank_seconds": screen_blank_seconds,
        "ts": time.time(),
    })


def main():
    cfg = load_config()
    ha_url = cfg.get("HA_URL", "http://homeassistant.local")
    token = cfg.get("HA_TOKEN", "")
    hostname = cfg.get("SATELLITE_NAME", os.uname().nodename)

    entity_id = None
    last_state = None
    last_config_poll = 0

    # Write initial defaults so face.html has something to read
    write_state("idle")
    write_kiosk_config(300)

    while True:
        now = time.time()

        # Re-poll config periodically
        if now - last_config_poll > CONFIG_POLL_INTERVAL:
            cfg = load_config()
            ha_url = cfg.get("HA_URL", "http://homeassistant.local")
            token = cfg.get("HA_TOKEN", "")
            hostname = cfg.get("SATELLITE_NAME", os.uname().nodename)

            if token:
                timeout = get_screensaver_timeout(ha_url, token, cfg)
                write_kiosk_config(timeout)
            last_config_poll = now

        # Find satellite entity on first run or if lost
        if entity_id is None and token:
            entity_id = find_entity(ha_url, token, hostname)

        # Poll satellite state
        if entity_id and token:
            ha_state = get_satellite_state(ha_url, token, entity_id)
            if ha_state is not None:
                face_state = HA_STATE_MAP.get(ha_state, "idle")
                if face_state != last_state:
                    write_state(face_state)
                    last_state = face_state

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
