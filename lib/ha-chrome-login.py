#!/usr/bin/env python3
"""
Inject HA long-lived token into Chromium's localStorage so the
HA frontend logs in automatically without a keyboard.

Run once after install: python3 ha-chrome-login.py <HA_URL> <HA_TOKEN>
"""
import json
import sys
import os
import sqlite3
import base64
import tempfile

def inject_ha_auth(ha_url, ha_token, profile_dir):
    """Write HA auth token into Chromium localStorage via leveldb."""
    # Chromium stores localStorage in LevelDB - we use a JSON file approach instead
    # by writing a startup page that injects the token via javascript

    os.makedirs(profile_dir, exist_ok=True)

    # Write an auto-login HTML page that sets localStorage and redirects to HA
    autologin_html = f"""<!DOCTYPE html>
<html>
<head><meta charset="utf-8">
<script>
// Inject HA auth token into localStorage for the HA frontend
var token = "{ha_token}";
var haUrl = "{ha_url}";
var auth = {{
  "hassUrl": haUrl,
  "clientId": haUrl + "/",
  "expires": Math.floor(Date.now() / 1000) + 3600 * 24 * 365,
  "refresh_token": "",
  "access_token": token,
  "token_type": "Bearer",
  "expires_in": 3600 * 24 * 365
}};

// Store in HA's expected localStorage key
try {{
  localStorage.setItem("hassTokens", JSON.stringify(auth));
  console.log("HA auth token injected");
}} catch(e) {{
  console.error("Failed to inject token:", e);
}}

// Redirect to HA
window.location.href = haUrl;
</script>
</head>
<body>Connecting to Home Assistant...</body>
</html>"""

    autologin_path = os.path.join(profile_dir, "ha-autologin.html")
    with open(autologin_path, "w") as f:
        f.write(autologin_html)

    print(f"Auto-login page written to: {autologin_path}")
    return autologin_path

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: ha-chrome-login.py <HA_URL> <HA_TOKEN> [profile_dir]")
        sys.exit(1)

    ha_url = sys.argv[1].rstrip("/")
    ha_token = sys.argv[2]
    profile_dir = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.config/chromium-kiosk")

    path = inject_ha_auth(ha_url, ha_token, profile_dir)
    print(f"Run kiosk with: {path}")
