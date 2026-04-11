#!/usr/bin/env python3
"""
Inject HA long-lived token into Chromium's localStorage (LevelDB).
Run once after install to enable auto-login in kiosk mode.

Usage: python3 ha-inject-token.py <HA_URL> <HA_TOKEN> <PROFILE_DIR>
"""
import sys
import os
import json
import subprocess
import time

def install_leveldb():
    try:
        import leveldb
        return True
    except ImportError:
        pass
    try:
        subprocess.run([sys.executable, "-m", "pip", "install",
                       "leveldb", "--break-system-packages", "-q"],
                      check=True)
        return True
    except Exception as e:
        print(f"Could not install leveldb: {e}")
        return False

def inject_token(ha_url, ha_token, profile_dir):
    ha_url = ha_url.rstrip("/")
    origin = ha_url

    # hassTokens format expected by HA frontend
    tokens = {
        "hassUrl": ha_url,
        "clientId": ha_url + "/",
        "expires": int(time.time()) + 86400 * 365 * 10,
        "refresh_token": ha_token,
        "access_token": ha_token,
        "token_type": "Bearer",
        "expires_in": 86400 * 365 * 10
    }

    # LevelDB key format for localStorage: origin + "\x00" + key
    # Chromium uses: "META:chrome-extension..." or "_chrome-default_..."
    # For http origins: key = origin + "\x01" + "hassTokens"
    leveldb_path = os.path.join(profile_dir, "Default", "Local Storage", "leveldb")

    if not os.path.isdir(leveldb_path):
        os.makedirs(leveldb_path, exist_ok=True)
        print(f"Created LevelDB dir: {leveldb_path}")

    try:
        import leveldb
        db = leveldb.LevelDB(leveldb_path)

        # Chromium localStorage key format
        key = f"_{origin}_\x00hassTokens".encode("utf-8")
        value = json.dumps(tokens).encode("utf-8")

        # Chromium prepends a version byte (0x01) to values
        db.Put(key, b"\x01" + value)
        print(f"[OK] Injected hassTokens into {leveldb_path}")
        return True
    except Exception as e:
        print(f"[ERROR] LevelDB injection failed: {e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: ha-inject-token.py <HA_URL> <HA_TOKEN> <PROFILE_DIR>")
        sys.exit(1)

    ha_url = sys.argv[1]
    ha_token = sys.argv[2]
    profile_dir = sys.argv[3]

    if not install_leveldb():
        print("[WARN] leveldb not available, skipping token injection")
        sys.exit(0)

    success = inject_token(ha_url, ha_token, profile_dir)
    sys.exit(0 if success else 1)
