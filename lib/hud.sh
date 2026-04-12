#!/bin/bash
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR=/run/user/$(id -u)
sleep 3
exec chromium \
    --app="file://${HOME}/.config/mark2-kiosk/hud.html" \
    --window-size=800,480 --window-position=0,0 \
    --ozone-platform=wayland --password-store=basic \
    --no-first-run --disable-infobars \
    --disable-background-timer-throttling \
    --app-auto-launched --enable-features=UseOzonePlatform
