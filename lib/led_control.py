#!/usr/bin/env python3
"""
Mark II SJ201 LED ring controller.
Controls 12x WS2812 NeoPixel LEDs on GPIO12 via adafruit-blinka.
Listens on Unix socket for state changes.
Must run as root (GPIO access).
"""
import time, threading, socket, os, sys, signal

NUM_LEDS = 12
SOCKET_PATH = "/tmp/mark2-leds.sock"

class SJ201LEDs:
    def __init__(self):
        try:
            import neopixel
            from adafruit_blinka.microcontroller.bcm283x.pin import D12
            self.pixels = neopixel.NeoPixel(
                D12, NUM_LEDS, brightness=0.3,
                auto_write=False, pixel_order=neopixel.GRB
            )
            self.available = True
            print("[LED] NeoPixel GPIO12 initialised")
        except Exception as e:
            print(f"[LED] NeoPixel not available: {e}", file=sys.stderr)
            self.pixels = None
            self.available = False
        self._stop = threading.Event()
        self._thread = None
        self._lock = threading.Lock()

    def _write(self, data):
        if not self.available or self.pixels is None: return
        with self._lock:
            try:
                for i, (r, g, b) in enumerate(data[:NUM_LEDS]):
                    self.pixels[i] = (r, g, b)
                self.pixels.show()
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
        # Extra write to ensure pixels are off after any pending animation
        if self.available and self.pixels is not None:
            with self._lock:
                try:
                    self.pixels.fill((0,0,0))
                    self.pixels.show()
                except Exception:
                    pass

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
                else: print(f"[LED] Unknown: {state}", file=sys.stderr)
        except socket.timeout: continue
        except Exception as e: print(f"[LED] Error: {e}", file=sys.stderr)

if __name__ == "__main__": main()
