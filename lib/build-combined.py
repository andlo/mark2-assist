#!/usr/bin/env python3
"""
build-combined.py — builds combined.html from hud.html template.
Called by kiosk.sh with: python3 build-combined.py <hud.html> <ha_url> <output.html>
"""
import re, sys, os

if len(sys.argv) != 4:
    print(f"Usage: {sys.argv[0]} <hud.html> <ha_url> <output.html>")
    sys.exit(1)

src_path, ha_url, out_path = sys.argv[1:]
src = open(src_path).read()

# 1. Replace %%HA_URL%% placeholder
src = src.replace('%%HA_URL%%', ha_url)

# 2. Inject HA iframe as the very first child of body (z-index:1)
# Use the /ha/ reverse-proxy path so mark2-httpd strips X-Frame-Options.
iframe_layer = (
    '<div id="ha-layer" style="position:absolute;inset:0;z-index:1;">\n'
    '  <iframe src="http://localhost:8088/ha/" style="width:100%;height:100%;border:none;"></iframe>\n'
    '</div>\n'
)
src = re.sub(r'(<body[^>]*>)', r'\1\n' + iframe_layer, src, count=1)

# 3. Patch wyoming layout: full-screen -> corner widget (240x240, bottom-right)
src = src.replace(
    "faceWrap.style.width     = '100%';\n"
    "      faceWrap.style.height    = '100%';\n"
    "      faceWrap.style.bottom    = '0';\n"
    "      faceWrap.style.right     = '0';\n"
    "      faceWrap.style.opacity   = '1';\n"
    "      faceWrap.style.background     = 'rgba(5,5,15,0.92)';\n"
    "      faceWrap.style.borderRadius   = '0';",
    "faceWrap.style.width     = '240px';\n"
    "      faceWrap.style.height    = '240px';\n"
    "      faceWrap.style.bottom    = '20px';\n"
    "      faceWrap.style.right     = '20px';\n"
    "      faceWrap.style.opacity   = '1';\n"
    "      faceWrap.style.background     = 'rgba(5,5,15,0.92)';\n"
    "      faceWrap.style.borderRadius   = '16px';"
)

# 4. Patch fetch URLs: replace file:///tmp/mark2-*.json with http://localhost:8088/*.json
#    so the page (served via http://localhost:8088) can load event files without
#    triggering the file://->http:// mixed-content block.
replacements = {
    "fetch('file:///tmp/mark2-face-event.json":    "fetch('http://localhost:8088/face-event.json",
    "fetch('file:///tmp/mark2-overlay-event.json": "fetch('http://localhost:8088/overlay-event.json",
    "fetch('file:///tmp/mark2-mpd-state.json":     "fetch('http://localhost:8088/mpd-state.json",
    "fetch('file:///tmp/mark2-content.json":       "fetch('http://localhost:8088/content.json",
}
for old, new in replacements.items():
    src = src.replace(old, new)

open(out_path, 'w').write(src)
print(f"Combined page written: {out_path}")
