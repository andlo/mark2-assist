#!/usr/bin/env python3
"""
lib/volume-buttons.py — Mark II hardware button control.

Installed as: /usr/local/bin/mark2-volume-buttons
Service:      mark2-volume-buttons.service

Listens on /dev/input/event0 for hardware button events:
  KEY_VOLUMEUP      — volume up 5% (TAS5806 + ALSA PCM + HUD overlay)
  KEY_VOLUMEDOWN    — volume down 5% (TAS5806 + ALSA PCM + HUD overlay)
  KEY_MICMUTE       — hardware mute toggle (TAS5806 + HUD overlay)
  KEY_VOICECOMMAND  — action button:
                        idle    → wake LVA via HA assist_satellite.start_conversation
                        busy    → stop current speech/music via media_player.stop

Controls TAS5806 amplifier via I2C (smbus2).
Writes /tmp/mark2-volume.json    — shared hardware state (volume %, muted, ts)
Writes /tmp/mark2-overlay-event.json — HUD volume bar events

Reads HA_URL + HA_TOKEN from ~/.config/mark2/config at startup.
Derives satellite entity from hostname:
  assist_satellite.<hostname>_lva_assist_satellite
"""
import os, json, time, subprocess, signal, sys, threading
import evdev, smbus2

DEVICE        = "/dev/input/event0"
VOL_FILE      = "/tmp/mark2-volume.json"
OVERLAY_FILE  = "/tmp/mark2-overlay-event.json"
HA_TOKEN      = None   # loaded from config at startup
HA_URL        = None

TAS_ADDR = 0x2f
TAS_VOL  = 0x4c
TAS_MAX  = 84    # register at 100% = -42dB (max safe for Mark II 5W speaker)
TAS_MIN  = 210   # register at 0% (near silence)
STEP     = 5     # percent per button press
DEFAULT  = 60    # restore level after unmute

# Satellite entity in HA — set during startup from config
SATELLITE_NAME = None
SATELLITE_ENTITY = None

from math import log as _log, exp as _exp

def pct_to_reg(p):
    p = max(0, min(100, p))
    if p == 0: return TAS_MIN
    pval = (p/100.0) * (_log(TAS_MAX) - _log(TAS_MIN)) + _log(TAS_MIN)
    return round(_exp(pval))

def reg_to_pct(r):
    r = max(TAS_MAX, min(TAS_MIN, r))
    return round(100.0 * (_log(TAS_MIN) - _log(r)) / (_log(TAS_MIN) - _log(TAS_MAX)))

def get_vol(bus):
    return reg_to_pct(bus.read_byte_data(TAS_ADDR, TAS_VOL))

def set_vol(bus, pct):
    pct = max(0, min(100, pct))
    bus.write_byte_data(TAS_ADDR, TAS_VOL, pct_to_reg(pct))
    subprocess.run(["amixer", "set", "PCM", f"{pct}%"], capture_output=True)
    _write(pct, False)
    return pct

def _write(pct, muted):
    # Write hardware state
    tmp = VOL_FILE + ".tmp"
    open(tmp, "w").write(json.dumps({"volume": pct, "muted": muted, "ts": time.time()}))
    os.replace(tmp, VOL_FILE)
    # Write overlay event for HUD
    evt = {"type": "volume", "value": pct, "muted": muted, "ts": time.time()}
    tmp2 = OVERLAY_FILE + ".tmp"
    open(tmp2, "w").write(json.dumps(evt))
    os.replace(tmp2, OVERLAY_FILE)

def mute_toggle(bus):
    r = bus.read_byte_data(TAS_ADDR, TAS_VOL)
    if r < TAS_MIN:
        # Currently unmuted → mute
        bus.write_byte_data(TAS_ADDR, TAS_VOL, TAS_MIN)
        subprocess.run(["amixer", "set", "PCM", "0%"], capture_output=True)
        _write(0, True)
        print("Muted", flush=True)
    else:
        # Currently muted → unmute
        vol = set_vol(bus, DEFAULT)
        print(f"Unmuted -> {vol}%", flush=True)

def action_button():
    """Action button handler:
    - If satellite is idle: play wake sound + start listening
    - If satellite is busy (speaking/responding): stop it (via media_player stop)
    """
    if not HA_URL or not HA_TOKEN or not SATELLITE_ENTITY:
        print("Action button: HA not configured, skipping", flush=True)
        return
    def _call():
        try:
            import urllib.request, socket

            headers = {"Authorization": f"Bearer {HA_TOKEN}",
                       "Content-Type": "application/json"}

            # Check current satellite state
            state_url = f"{HA_URL}/api/states/{SATELLITE_ENTITY}"
            req = urllib.request.Request(state_url, headers=headers)
            with urllib.request.urlopen(req, timeout=5) as resp:
                state_data = json.loads(resp.read())
                sat_state = state_data.get("state", "idle")

            print(f"Action button: satellite state={sat_state}", flush=True)

            if sat_state == "idle":
                # Wake: play wake sound + start listening
                own_ip = socket.gethostbyname(socket.gethostname())
                wake_sound = f"http://{own_ip}:8088/sounds/wake_word_triggered.flac"
                url = f"{HA_URL}/api/services/assist_satellite/start_conversation"
                data = json.dumps({
                    "entity_id": SATELLITE_ENTITY,
                    "start_media_id": wake_sound,
                    "preannounce": False,
                }).encode()
                req = urllib.request.Request(url, data=data, headers=headers, method="POST")
                with urllib.request.urlopen(req, timeout=10) as resp:
                    print(f"Action button: wake triggered → {resp.status}", flush=True)
            else:
                # Busy: stop current activity via media_player stop
                mp_entity = SATELLITE_ENTITY.replace("assist_satellite.", "media_player.") + "_media_player"
                url = f"{HA_URL}/api/services/media_player/media_stop"
                data = json.dumps({"entity_id": mp_entity}).encode()
                req = urllib.request.Request(url, data=data, headers=headers, method="POST")
                with urllib.request.urlopen(req, timeout=5) as resp:
                    print(f"Action button: stopped → {resp.status}", flush=True)

        except Exception as e:
            print(f"Action button error: {e}", flush=True)
    threading.Thread(target=_call, daemon=True).start()

def load_config():
    """Load HA_URL, HA_TOKEN and SATELLITE_NAME from mark2-assist config."""
    global HA_URL, HA_TOKEN, SATELLITE_ENTITY, SATELLITE_NAME
    config_path = "/home/pi/.config/mark2/config"
    try:
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("HA_URL="):
                    HA_URL = line.split("=", 1)[1].strip().strip('"')
                elif line.startswith("HA_TOKEN="):
                    HA_TOKEN = line.split("=", 1)[1].strip().strip('"')
    except Exception as e:
        print(f"Warning: could not read {config_path}: {e}", flush=True)
    # Derive satellite entity from hostname
    try:
        import socket
        hostname = socket.gethostname().lower().replace("-", "_")
        SATELLITE_NAME = hostname
        SATELLITE_ENTITY = f"assist_satellite.{hostname}_lva_assist_satellite"
        print(f"Satellite entity: {SATELLITE_ENTITY}", flush=True)
    except Exception as e:
        print(f"Warning: could not determine satellite entity: {e}", flush=True)

def main():
    load_config()
    dev = evdev.InputDevice(DEVICE)
    dev.grab()
    bus = smbus2.SMBus(1)
    # Sync ALSA PCM to match TAS5806 at startup
    current_pct = get_vol(bus)
    subprocess.run(["amixer", "set", "PCM", f"{current_pct}%"], capture_output=True)
    _write(current_pct, False)
    print(f"Started, vol={current_pct}% (TAS5806+PCM synced)", flush=True)
    signal.signal(signal.SIGTERM, lambda *_: (dev.ungrab(), bus.close(), sys.exit(0)))
    for ev in dev.read_loop():
        if ev.type != evdev.ecodes.EV_KEY or ev.value != 1:
            continue
        if ev.code == evdev.ecodes.KEY_VOLUMEUP:
            print(f"Vol up   -> {set_vol(bus, get_vol(bus)+STEP)}%", flush=True)
        elif ev.code == evdev.ecodes.KEY_VOLUMEDOWN:
            print(f"Vol down -> {set_vol(bus, get_vol(bus)-STEP)}%", flush=True)
        elif ev.code == evdev.ecodes.KEY_MICMUTE:
            mute_toggle(bus)
        elif ev.code == evdev.ecodes.KEY_VOICECOMMAND:
            print("Action button", flush=True)
            action_button()

if __name__ == "__main__":
    main()
