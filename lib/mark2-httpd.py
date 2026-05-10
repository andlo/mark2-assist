#!/usr/bin/env python3
"""
lib/mark2-httpd.py — Mark II backlight control server.

Minimal HTTP server on port 8088 for display power management.
Called by kiosk.sh at boot.

Endpoints:
  GET /screen-off  → turns off DSI display via wlopm
  GET /screen-on   → turns on DSI display via wlopm
  GET /sounds/<f>  → serves LVA sound files (used by HA action button)

The face overlay (face.html) reads /tmp/mark2-face-event.json directly
via file:// — no HTTP proxy needed for that.

Screen blanking is triggered by face.html's inactivity timer
(SCREEN_BLANK_SECONDS, default 300s = 5 min). It calls these endpoints
via fetch('http://localhost:8088/screen-off').
"""
import http.server, os, subprocess

PORT = 8088

WAYLAND_ENV = {
    **os.environ,
    'WAYLAND_DISPLAY': os.environ.get('WAYLAND_DISPLAY', 'wayland-1'),
    'XDG_RUNTIME_DIR': f'/run/user/{os.getuid()}',
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # silence access log

    def do_GET(self):
        path = self.path.split('?')[0]

        if path == '/screen-off':
            subprocess.Popen(['wlopm', '--off', 'HDMI-A-1'], env=WAYLAND_ENV)
            self._ok()
            return

        if path == '/screen-on':
            subprocess.Popen(['wlopm', '--on', 'HDMI-A-1'], env=WAYLAND_ENV)
            self._ok()
            return

        # LVA sound files via /sounds/<filename>
        # Used by the action button wake trigger in HA automations.
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

        self.send_response(404)
        self.end_headers()

    def _ok(self):
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()


if __name__ == '__main__':
    server = http.server.HTTPServer(('127.0.0.1', PORT), Handler)
    print(f'mark2-httpd listening on http://127.0.0.1:{PORT}')
    server.serve_forever()
