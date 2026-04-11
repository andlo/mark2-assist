# Satellite & Kiosk Setup — Technical Documentation

`mark2-satellite-setup.sh` installs the Wyoming voice satellite, Weston kiosk display,
and all supporting services. Run this after `mark2-hardware-setup.sh` and a reboot.

---

## What it does (in order)

### 1. HA URL prompt

Loads `~/.config/mark2/config` if it exists (saved from a previous run).
If `HA_URL` is not set, prompts for it. The URL is saved to config for use by
kiosk.sh and modules.

### 2. SJ201 audio device detection

Queries ALSA for sound cards matching `soc_sound`, `xvf3510` or `sj201`:
```bash
arecord -L | grep -i "soc_sound\|xvf3510\|sj201"
```

The detected device name (e.g. `plughw:CARD=sj201,DEV=1`) is used for both the
microphone capture command and speaker playback command in the Wyoming satellite service.

If detection fails, falls back to `plughw:0,0` and warns.

### 3. Dependencies

```
apt install git python3 python3-venv python3-pip python3-dev alsa-utils curl wget unzip
```

### 4. Wyoming satellite

Clones [wyoming-satellite](https://github.com/rhasspy/wyoming-satellite) to `~/wyoming-satellite`
and runs `python3 script/setup` to create a virtualenv and install Python dependencies.

The `script/setup` script handles all Python package installation within a venv at
`~/wyoming-satellite/.venv`. This keeps Wyoming's dependencies isolated from the system.

### 5. Wyoming openWakeWord

Clones [wyoming-openwakeword](https://github.com/rhasspy/wyoming-openwakeword) to
`~/wyoming-openwakeword` and runs `python3 script/setup`, which also downloads the
wake word model files (ok_nabu, hey_mycroft, etc.).

### 6. wyoming-openwakeword.service

```ini
[Service]
ExecStart=~/wyoming-openwakeword/script/run \
    --uri 'tcp://127.0.0.1:10400' \
    --preload-model 'ok_nabu'
```

Listens on `tcp://127.0.0.1:10400` (loopback only, not exposed to network).
The `--preload-model` flag loads the model into memory at startup for fast wake word response.

### 7. wyoming-satellite.service

```ini
[Service]
ExecStartPre=-/bin/sh -c 'fuser -k 10700/tcp 2>/dev/null; sleep 1'
ExecStart=~/wyoming-satellite/script/run \
    --name 'Nabu-1' \
    --uri 'tcp://0.0.0.0:10700' \
    --mic-command 'arecord -D plughw:CARD=sj201,DEV=1 -r 16000 -c 1 -f S16_LE -t raw' \
    --snd-command 'aplay -D plughw:CARD=sj201,DEV=1 -r 22050 -c 1 -f S16_LE -t raw' \
    --mic-auto-gain 5 \
    --mic-noise-suppression 2 \
    --wake-uri 'tcp://127.0.0.1:10400' \
    --wake-word-name 'ok_nabu'
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
```

Key points:
- `--uri tcp://0.0.0.0:10700` — listens on all interfaces, HA discovers via zeroconf mDNS
- `--name` — uses `$(hostname)` so each device has a unique name in HA
- `ExecStartPre` clears port 10700 before starting (handles stale processes after crash)
- `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` are needed for zeroconf/avahi to work
  in systemd user services (they don't inherit the D-Bus session automatically)
- `--mic-auto-gain 5` and `--mic-noise-suppression 2` improve wake word detection accuracy

### 8. mark2-face-events.service

A Python script (`~/.config/mark2/face-event-bridge.py`) monitors the
`wyoming-satellite` systemd journal and writes the current state to
`/tmp/mark2-face-event.json`. The HUD overlay reads this file to animate the face.

States mapped from Wyoming log lines:
```
detecting    → idle
detected     → wake
recording    → listen
processing   → think
synthesizing → think
playing      → speak
done         → idle
error        → error
```

This service runs regardless of whether the optional `face` or `leds` modules are installed,
ensuring the HUD always has state information.

### 9. Kiosk packages

```
apt install labwc wlr-randr seatd dbus-user-session xdg-user-dirs \
    chromium weston mpv \
    pipewire pipewire-pulse wireplumber gstreamer1.0-pipewire
```

- **weston** — Wayland compositor for the kiosk display (labwc is also installed for
  optional face/overlay module window management)
- **chromium** — displays the HA dashboard
- **seatd** — seat management daemon required for Wayland access from the user session
- **mpv** — media player for future HA media integration

`seatd.service` is enabled system-wide. The user is added to `video` and `input` groups.

### 10. Auto-login configuration

Getty is configured to auto-login the pi user on tty1:
```
/etc/systemd/system/getty@tty1.service.d/autologin.conf
```

`~/.bash_profile` is extended to start Weston when logged in on tty1:
```bash
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    export XDG_SESSION_TYPE=wayland
    weston --backend=drm --shell=kiosk --log=/tmp/weston.log -- /home/pi/startup.sh
fi
```

`weston --shell=kiosk` starts a minimal fullscreen compositor with no window decorations,
taskbars or desktop. The `--` flag passes `startup.sh` as the session command — Weston
runs it at startup and exits when it finishes (so startup.sh should keep running, i.e.
Chromium should run in the foreground).

### 11. startup.sh

```bash
#!/bin/bash
/home/pi/kiosk.sh &
sleep 3
/home/pi/hud.sh &
wait
```

Starts kiosk.sh (HA in Chromium) and after 3 seconds starts hud.sh (face/volume HUD).
The `wait` at the end keeps startup.sh running so Weston stays alive.

### 12. kiosk.sh

```bash
#!/bin/bash
CONFIG="${HOME}/.config/mark2/config"
HA_URL=""
[ -f "$CONFIG" ] && source "$CONFIG"

# Wait for Wayland socket
for i in $(seq 1 30); do
    [ -S "/run/user/$(id -u)/wayland-0" ] && break; sleep 1
done

# Remove stale Chromium lock file
rm -f "${HOME}/.config/chromium-kiosk/Singleton"*

# Wait for HA to respond (401 is fine - means HA is running)
until curl -o /dev/null -sf --max-time 3 -w "%{http_code}" "${HA_URL}" \
    | grep -qE '200|401|302'; do sleep 3; done

exec chromium --kiosk --ozone-platform=wayland --no-sandbox \
    --no-first-run --disable-session-crashed-bubble \
    --password-store=basic \
    --user-data-dir="${HOME}/.config/chromium-kiosk" \
    "${HA_URL}"
```

Key points:
- Waits for the Wayland socket before attempting to start Chromium
- Removes stale `Singleton*` lock files that prevent Chromium starting after unclean shutdown
- Waits for HA HTTP response (accepts 401 Unauthorized — that means HA is running)
- `--user-data-dir` stores Chromium session/cookies persistently, so login is remembered

### 13. hud.sh

Starts a second Chromium window in `--app` mode (no browser UI) displaying the
HUD overlay HTML. The HUD is transparent and sits on top of the HA kiosk window.

Labwc window rules (`~/.config/labwc/rc.xml`) are configured to keep `hud.html`
always on top when labwc is used for the face/overlay modules.

---

## Service dependency graph

```
sj201.service
    └── wyoming-openwakeword.service
            └── wyoming-satellite.service
                    └── mark2-face-events.service
```

All are systemd **user** services (`systemctl --user`), not system services.
They start when the user session starts (after auto-login on tty1).

---

## Wayland compositor choice: Weston vs labwc

**Weston** is used for the main kiosk display because Chromium 146 on Debian Trixie
does not correctly render its surfaces in labwc on Pi 4 with vc4-kms-v3d. The root
cause is a compositing issue between Chromium's ANGLE/EGL renderer and labwc's
surface handling. Weston (the reference Wayland compositor) renders correctly.

**labwc** is still installed and used by the optional `face` and `overlay` modules
for their window management (always-on-top HUD windows). These modules use labwc
window rules to position themselves correctly over the Weston kiosk session — but
in practice the current architecture has Weston running the kiosk and the face/overlay
windows managed separately.

> This architecture may be simplified in a future version to use only Weston.

---

## Zeroconf / mDNS discovery

Wyoming satellite advertises itself on the local network via mDNS (zeroconf) using
avahi-daemon. Home Assistant's Wyoming integration discovers satellites automatically.
The satellite name is set to `$(hostname)` so each device has a unique name.

For this to work:
- `DBUS_SESSION_BUS_ADDRESS` must be set in the service environment (for avahi access)
- `XDG_RUNTIME_DIR` must be set (for D-Bus socket location)
- avahi-daemon must be running system-wide (installed by default on Raspberry Pi OS)

---

## Chromium GPU configuration

Debian Trixie's `/usr/bin/chromium` wrapper sets `want_gles=1` by default, which
adds `--use-angle=gles` to Chromium's startup flags. However `gles` is not a valid
ANGLE backend — only `opengl`, `opengles`, `swiftshader` and `vulkan` are. This
causes Chromium's GPU process to crash in a loop, resulting in a white/blank page.

The fix is `/etc/chromium.d/gpu-flags`:
```bash
want_gles=0
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --use-angle=opengles"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ignore-gpu-blocklist"
```

This overrides `want_gles` before the chromium wrapper applies it, and sets the
correct ANGLE backend explicitly.
