#!/usr/bin/env python3
"""
Mark II LED event bridge for LVA.
Polls /tmp/mark2-face-event.json and maps HA satellite states to LED states.
"""
import json, socket, sys, time, os

FACE_EVENT_FILE = "/tmp/mark2-face-event.json"
UNIX_SOCKET     = "/tmp/mark2-leds.sock"
POLL_INTERVAL   = 0.3

# face-event.json already contains face states (idle/listen/think/speak)
# written by face-event-bridge.py — pass them directly to LED socket
VALID_STATES = {"idle", "wake", "listen", "think", "speak", "error", "mute", "volume"}

def send_led(state):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(UNIX_SOCKET)
        s.sendall(state.encode())
        s.close()
    except Exception as e:
        print(f"[EVENT] LED socket error: {e}", file=sys.stderr)

def read_state():
    try:
        with open(FACE_EVENT_FILE) as f:
            data = json.load(f)
        return data.get("state", "idle")
    except Exception:
        return None

def main():
    print(f"[EVENT] Polling {FACE_EVENT_FILE} every {POLL_INTERVAL}s")
    for _ in range(30):
        if os.path.exists(UNIX_SOCKET): break
        time.sleep(1)
    send_led("idle")
    last_state = None
    while True:
        face_state = read_state()
        if face_state is not None:
            # face state is already in LED format — send directly
            led_state = face_state if face_state in VALID_STATES else "idle"
            if led_state != last_state:
                print(f"[EVENT] {face_state} -> LED:{led_state}", flush=True)
                send_led(led_state)
                last_state = led_state
        time.sleep(POLL_INTERVAL)

if __name__ == "__main__": main()
