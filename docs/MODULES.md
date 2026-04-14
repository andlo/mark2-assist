# Optional Modules — Technical Documentation

Each module in `modules/` is a standalone bash script that can be run independently
or as part of the main installation. All modules source `lib/common.sh`.

Modules are selected during `install.sh` via a checklist. Default selections are
marked with ✓.

---

## ui.sh — Mark II Physical User Interface ✓

The primary UI module. Installs everything that gives the Mark II its look, feel
and physical interaction model. Replaces the legacy `face.sh`, `overlay.sh`,
`screensaver.sh` and `leds.sh` modules.

### What it installs

**Display** (built into `combined.html`, served by `mark2-httpd.py`):
- Animated robot face — reacts to LVA voice events in real time
- Passive clock + weather — shown when idle; time updates every 10s,
  weather fetched from HA REST API every 5 minutes
- Volume bar overlay — appears on every hardware button press, auto-hides after 3s
- Screen blanks after 5 minutes of no touch (Weston `--idle-time=300`)
- Tap anywhere on passive screen → opens HA dashboard

**LED ring** (`mark2-leds.service` + `mark2-led-events.service`):
- 12× NeoPixel WS2812 on GPIO12, driven via `led_control.py`
- Follows LVA satellite state: idle / wake / listen / think / speak / error / mute

**Hardware buttons** (`mark2-volume-buttons.service`):
- Vol up / Vol down → TAS5806 amp + ALSA PCM + HUD overlay
- Mute → hardware mute toggle + HUD shows "Muted" + 🔇
- Action button → wake LVA (when idle) or stop speech/music (when busy)

**Boot splash** (`lib/install-plymouth.sh`):
- Plymouth theme covers kernel boot (0–15s): Mark II face + title + progress bar
- Chromium splash (`templates/splash.html`) covers Weston startup (15–25s):
  animated eye-opening, progress stages, logo pills, fades to combined.html
- Boot sequence: Plymouth → tty1 blanked → Weston → Chromium splash → combined.html
- Re-run standalone: `sudo bash lib/install-plymouth.sh`

### Architecture

```
Boot sequence:
  0-15s  Plymouth (kernel boot) → mark2 theme: face + progress bar
  15-25s Weston starts → Chromium opens splash.html (eye animation)
  25s+   Chromium navigates to combined.html (clock+weather)

SJ201 /dev/input/event0
  └─ mark2-volume-buttons.service (lib/volume-buttons.py)
       ├─ TAS5806 I2C + amixer          — hardware volume
       ├─ /tmp/mark2-volume.json        — shared state
       ├─ /tmp/mark2-overlay-event.json — HUD volume bar
       └─ HA assist_satellite API       — action button wake

LVA → HA API
  └─ mark2-face-events.service (lib/face-event-bridge.py)
       └─ /tmp/mark2-face-event.json
            ├─ combined.html face layer — animated face on screen
            └─ mark2-led-events.service (lib/led_event_handler.py)
                 └─ /tmp/mark2-leds.sock
                      └─ mark2-leds.service (lib/led_control.py) → GPIO12
```

### LED states

| State | Animation | Colour |
|-------|-----------|--------|
| `idle` | Off / dim pulse | — |
| `wake` | Flash | Blue |
| `listen` | Solid | Blue |
| `think` | Spin | Cyan |
| `speak` | Solid | Green |
| `error` | Flash | Red |
| `mute` | Solid dim | Amber |

### Testing
```bash
# LED ring
echo 'listen' | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
echo 'idle'   | socat - UNIX-CONNECT:/tmp/mark2-leds.sock

# Volume overlay (check HUD bar appears)
echo '{"type":"volume","value":75,"muted":false}' > /tmp/mark2-overlay-event.json

# Action button wake (manual trigger)
curl -X POST http://192.168.x.x:8123/api/services/assist_satellite/start_conversation \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"entity_id":"assist_satellite.<hostname>_lva_assist_satellite","start_media_id":"http://<mark2-ip>:8088/sounds/wake_word_triggered.flac","preannounce":false}'

# Boot splash — re-install/update Plymouth theme
sudo bash lib/install-plymouth.sh
```

---

## homeassistant.sh — HA Kiosk Dashboard ✓

Configures the Mark II touchscreen to show your Home Assistant dashboard. Without
this module the kiosk only shows the face animation and clock.

Sets up:
- Marker file `~/.config/mark2/ha-kiosk-enabled` read by `kiosk.sh`
- Prints the required HA `configuration.yaml` snippets:
  - `use_x_frame_options: false` (allows HA to load in an iframe)
  - `trusted_networks` auto-login for the mark2 user

See `docs/HA_SETUP.md` for the full HA setup guide including kiosk mode,
trusted networks and the mark2-dashboard.yaml template.

---

## mqtt-sensors.sh — MQTT Sensor Publisher ✓

Publishes Mark II system state to Home Assistant via MQTT with automatic discovery.
Sensors appear in HA automatically under the device name without manual configuration.

### Published sensors

| Sensor | Update rate |
|--------|-------------|
| LVA satellite state (`idle`/`listen`/`think`/`speak`) | On change |
| MPD playback state, track, artist, volume | On change |
| CPU temperature | Every 30 s |
| CPU usage | Every 30 s |
| Memory usage | Every 30 s |
| Disk usage | Every 30 s |

### Architecture

```
mark2-mqtt-bridge.service (lib/mqtt-bridge.py)
  ├─ reads /tmp/mark2-face-event.json  (LVA state)
  ├─ reads /tmp/mark2-mpd-state.json   (MPD state, written by mark2-mpd-watcher)
  ├─ reads /proc/stat, /sys/thermal    (system metrics)
  └─ publishes to MQTT broker with HA auto-discovery
```

---

## mpd.sh — Local Music Player

Installs MPD (Music Player Daemon) for local music playback from files on the
device. Works with the Music Assistant integration in HA.

**When you need this:** If you have a local music collection or want multiroom
audio via Snapcast. Most users can stream music to Mark II directly via LVA's
built-in media player (no MPD required).

Also installs `mark2-mpd-watcher.service` which monitors MPD state for the MQTT
sensors and face music animation.

---

## snapcast.sh — Multiroom Audio

Installs `snapclient` to receive synchronised audio streams from a Snapcast server.
Keeps all speakers in perfect sync across multiple rooms.

Prompts for the Snapcast server IP and creates a systemd user service.

---

## airplay.sh — AirPlay Speaker

Installs `shairport-sync` (PipeWire backend) so Mark II appears as an AirPlay 1
receiver. Any Apple device or AirPlay-compatible app can stream audio to it.

---

## kdeconnect.sh — Android Phone Integration

Installs `kdeconnectd` for pairing with Android phones. Enables:
- Phone notifications on the Mark II display
- Media playback control from phone
- Clipboard sharing

---

## usb-audio.sh — USB Audio Fallback

Installs a boot-time service that detects if the SJ201 audio fails to initialise
and switches to a USB audio device as fallback. Useful for development/testing.

---

## Deprecated modules

The following modules are **superseded by `ui.sh`** and kept only for reference.
Do not install them alongside `ui.sh`.

| Module | Superseded by |
|--------|---------------|
| `leds.sh` | `ui.sh` LED ring section |
| `face.sh` | `ui.sh` display / combined.html |
| `overlay.sh` | `ui.sh` display / volume-buttons.py |
| `screensaver.sh` | `ui.sh` display / passive clock+weather |
