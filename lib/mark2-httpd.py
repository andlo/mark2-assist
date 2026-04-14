#!/usr/bin/env python3
"""
mark2-httpd.py — local HTTP server for the Mark II kiosk.

Serves:
  /                     → combined.html
  /combined.html        → ~/.config/mark2-kiosk/combined.html
  /hud.html             → ~/.config/mark2-kiosk/hud.html
  /face-event.json      → /tmp/mark2-face-event.json
  /overlay-event.json   → /tmp/mark2-overlay-event.json
  /mpd-state.json       → /tmp/mark2-mpd-state.json
  /content.json         → /tmp/mark2-content.json
  /ha/*                 → reverse-proxy to HA, stripping X-Frame-Options
                          so the HA dashboard can load in an iframe.
"""
import http.server, os, urllib.request, urllib.error

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

    def do_GET(self):
        path = self.path.split('?')[0]

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
