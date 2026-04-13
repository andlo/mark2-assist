#!/usr/bin/env python3
"""
build-combined.py — builds combined.html from kiosk.html template.
Called by kiosk.sh: python3 build-combined.py <kiosk.html> <ha_url> <output.html>

The kiosk.html template already contains the HA iframe, touch-to-open logic,
and all face/HUD layers. This script only needs to:
  1. Replace %%HA_URL%% with the real HA URL
  2. Patch fetch() URLs from file:///tmp/ to http://localhost:8088/
     so events load correctly when served via the local HTTP server.
"""
import sys, re

if len(sys.argv) != 4:
    print(f"Usage: {sys.argv[0]} <kiosk.html> <ha_url> <output.html>")
    sys.exit(1)

src_path, ha_url, out_path = sys.argv[1:]
src = open(src_path).read()

# 1. Replace HA URL placeholder
src = src.replace('%%HA_URL%%', ha_url)

# 2. Patch fetch() event URLs for localhost HTTP server
# (kiosk.html already uses http://localhost:8088/ — nothing to patch
#  unless we're upgrading an old template that used file:///tmp/)
src = src.replace(
    "fetch('file:///tmp/mark2-face-event.json",
    "fetch('http://localhost:8088/face-event.json"
)
src = src.replace(
    "fetch('file:///tmp/mark2-overlay-event.json",
    "fetch('http://localhost:8088/overlay-event.json"
)
src = src.replace(
    "fetch('file:///tmp/mark2-mpd-state.json",
    "fetch('http://localhost:8088/mpd-state.json"
)
src = src.replace(
    "fetch('file:///tmp/mark2-content.json",
    "fetch('http://localhost:8088/content.json"
)

open(out_path, 'w').write(src)
print(f"Combined page written: {out_path}")
