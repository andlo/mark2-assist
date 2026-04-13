#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)

# Use Wayland socket from parent (Weston session) or detect it
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for sock in wayland-0 wayland-1 wayland-2; do
        if [ -S "/run/user/$(id -u)/${sock}" ]; then
            export WAYLAND_DISPLAY="$sock"
            break
        fi
    done
fi

sleep 3
exec chromium \
    --app="file://${HOME}/.config/mark2-kiosk/hud.html" \
    --window-size=800,480 --window-position=0,0 \
    --ozone-platform=wayland \
    --enable-transparent-visuals \
    --user-data-dir="${HOME}/.config/chromium-hud" \
    --allow-file-access-from-files \
    --password-store=basic \
    --no-first-run --disable-infobars \
    --disable-background-timer-throttling \
    --app-auto-launched --enable-features=UseOzonePlatform
