#!/usr/bin/env python3
"""
Mark II face event bridge — LVA version.

Polls Home Assistant assist_satellite entity state via REST API
and writes current voice state to /tmp/mark2-face-event.json.

HA satellite states -> face states:
  idle       -> idle
  listening  -> listen
  processing -> think
  responding -> speak
"""
import json, os, time, urllib.request, urllib.error

OUT          = "/tmp/mark2-face-event.json"
CONFIG_FILE  = os.path.expanduser("~/.config/mark2/config")
POLL_INTERVAL = 0.5   # seconds

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
                    cfg[k.strip()] = v.strip().strip('"')
    except Exception:
        pass
    return cfg

def write_state(state):
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"state": state, "ts": time.time()}, f)
    os.replace(tmp, OUT)

def get_satellite_state(ha_url, token, entity_id):
    url = f"{ha_url}/api/states/{entity_id}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            data = json.load(r)
            return data.get("state", "idle")
    except Exception:
        return None

def find_entity(ha_url, token, hostname):
    """Try common entity ID patterns for this host."""
    slug = hostname.lower().replace("-", "_")
    candidates = [
        f"assist_satellite.{slug}_lva_assist_satellite",
        f"assist_satellite.{slug}_assist_satellite",
        f"assist_satellite.{slug}",
    ]
    for entity_id in candidates:
        state = get_satellite_state(ha_url, token, entity_id)
        if state is not None:
            return entity_id
    return None

def main():
    import socket as _socket
    hostname = _socket.gethostname()

    write_state("idle")
    print("[FACE] Mark II face event bridge starting")

    cfg = load_config()
    ha_url = cfg.get("HA_URL", "").rstrip("/")
    token  = cfg.get("HA_TOKEN", "")

    if not ha_url or not token:
        print("[FACE] HA_URL or HA_TOKEN not set in config — polling disabled")
        while True: time.sleep(60)

    entity_id = None
    while entity_id is None:
        entity_id = find_entity(ha_url, token, hostname)
        if entity_id:
            print(f"[FACE] Found satellite entity: {entity_id}")
        else:
            print(f"[FACE] Satellite entity not found for {hostname} — retrying in 10s")
            time.sleep(10)

    last_state = None
    while True:
        ha_state = get_satellite_state(ha_url, token, entity_id)
        if ha_state is not None:
            face_state = HA_STATE_MAP.get(ha_state, "idle")
            if face_state != last_state:
                print(f"[FACE] {ha_state} -> {face_state}")
                write_state(face_state)
                last_state = face_state
        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main()
