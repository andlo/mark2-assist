#!/usr/bin/env python3
"""
lib/mark2-httpd.py — local HTTP server for the Mark II kiosk.

Started by kiosk.sh. Listens on 0.0.0.0:8088 so both the local
Chromium kiosk and Home Assistant (on the same LAN) can reach it.

Serves:
  /                     → combined.html (HA iframe + HUD overlay)
  /combined.html        → ~/.config/mark2-kiosk/combined.html
  /hud.html             → ~/.config/mark2-kiosk/hud.html
  /face-event.json      → /tmp/mark2-face-event.json  (LVA state events)
  /overlay-event.json   → /tmp/mark2-overlay-event.json  (volume/status HUD)
  /mpd-state.json       → /tmp/mark2-mpd-state.json  (MPD now-playing)
  /content.json         → /tmp/mark2-content.json  (content panel data)
  /sounds/<file>        → ~/lva/sounds/<file>  (LVA audio files for HA)
  /ha/*                 → reverse-proxy to HA, stripping X-Frame-Options
                          so the HA dashboard can load in an iframe.

The /sounds/ route is used by the action button wake trigger:
  assist_satellite.start_conversation uses wake_word_triggered.flac
  as start_media_id so LVA plays its own chime then starts listening.
"""
import http.server, os, urllib.request, urllib.error, subprocess

KIOSK_DIR = os.path.expanduser("~/.config/mark2-kiosk")
PORT = 8088

# Read HA URL from config
HA_URL = ""
config_path = os.path.expanduser("~/.config/mark2/config")
if os.path.exists(config_path):
    for line in open(config_path):
        if line.startswith("HA_URL="):
            HA_URL = line.strip().split("=", 1)[1].strip('"').strip("'")

EVENT_MAP = {
    '/face-event.json':    '/tmp/mark2-face-event.json',
    '/overlay-event.json': '/tmp/mark2-overlay-event.json',
    '/mpd-state.json':     '/tmp/mark2-mpd-state.json',
    '/content.json':       '/tmp/mark2-content.json',
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # silence access log

    def do_HEAD(self):
        """Respond to HEAD requests — used by splash.html to poll HA readiness."""
        path = self.path.split('?')[0]
        # For HA proxy HEAD requests, forward to HA
        if path.startswith('/ha') and HA_URL:
            ha_path = path[3:] or '/'
            target = HA_URL.rstrip('/') + ha_path
            try:
                req = urllib.request.Request(target, method='HEAD')
                with urllib.request.urlopen(req, timeout=5) as resp:
                    self.send_response(resp.status)
                    self.end_headers()
            except Exception:
                self.send_response(502)
                self.end_headers()
            return
        # For local files, just return 200 if file exists
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        path = self.path.split('?')[0]

        # Screen power control via wlopm
        if path == '/screen-off':
            subprocess.Popen(['wlopm', '--off', 'HDMI-A-1'],
                             env={**os.environ, 'WAYLAND_DISPLAY': 'wayland-1',
                                  'XDG_RUNTIME_DIR': f'/run/user/{os.getuid()}'})
            self.send_response(200); self.end_headers()
            return
        if path == '/screen-on':
            subprocess.Popen(['wlopm', '--on', 'HDMI-A-1'],
                             env={**os.environ, 'WAYLAND_DISPLAY': 'wayland-1',
                                  'XDG_RUNTIME_DIR': f'/run/user/{os.getuid()}'})
            self.send_response(200); self.end_headers()
            return

        # Event JSON files from /tmp
        if path in EVENT_MAP:
            try:
                data = open(EVENT_MAP[path], 'rb').read()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(data)
            except FileNotFoundError:
                self.send_response(404)
                self.end_headers()
            return

        # Reverse-proxy /ha/* → HA, stripping X-Frame-Options
        if path.startswith('/ha') and HA_URL:
            ha_path = path[3:] or '/'  # strip /ha prefix
            target = HA_URL.rstrip('/') + ha_path
            if self.path.find('?') != -1:
                target += '?' + self.path.split('?', 1)[1]
            try:
                headers = {}
                for h in ('Cookie', 'Authorization', 'Accept', 'Accept-Language',
                          'Content-Type', 'Referer'):
                    v = self.headers.get(h)
                    if v:
                        headers[h] = v
                req = urllib.request.Request(target, headers=headers)
                with urllib.request.urlopen(req, timeout=10) as resp:
                    body = resp.read()
                    self.send_response(resp.status)
                    for k, v in resp.headers.items():
                        # Strip frame-blocking headers
                        if k.lower() in ('x-frame-options',
                                         'content-security-policy'):
                            continue
                        if k.lower() in ('transfer-encoding', 'connection'):
                            continue
                        self.send_header(k, v)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
            except Exception as e:
                self.send_response(502)
                self.end_headers()
                self.wfile.write(f'Proxy error: {e}'.encode())
            return

        # LVA sound files via /sounds/<filename>
        if path.startswith('/sounds/'):
            fname = os.path.basename(path)
            fpath = os.path.expanduser(f'~/lva/sounds/{fname}')
            ext = fname.rsplit('.', 1)[-1].lower()
            ctype = {'flac': 'audio/flac', 'wav': 'audio/wav',
                     'mp3': 'audio/mpeg'}.get(ext, 'application/octet-stream')
            try:
                data = open(fpath, 'rb').read()
                self.send_response(200)
                self.send_header('Content-Type', ctype)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(data)
            except FileNotFoundError:
                self.send_response(404)
                self.end_headers()
            return

        # HTML files from KIOSK_DIR
        if path in ('/', '/combined.html'):
            fpath = os.path.join(KIOSK_DIR, 'combined.html')
        elif path == '/hud.html':
            fpath = os.path.join(KIOSK_DIR, 'hud.html')
        elif path == '/splash.html':
            fpath = os.path.join(KIOSK_DIR, 'splash.html')
        else:
            self.send_response(404)
            self.end_headers()
            return

        try:
            data = open(fpath, 'rb').read()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()


if __name__ == '__main__':
    server = http.server.HTTPServer(('0.0.0.0', PORT), Handler)
    print(f'mark2-httpd listening on http://127.0.0.1:{PORT}')
    server.serve_forever()
