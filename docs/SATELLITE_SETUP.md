# Satellite & Kiosk Setup — Technical Documentation

`mark2-satellite-setup.sh` installs the Linux Voice Assistant (LVA), Weston kiosk display,
and all supporting services. Run this after `mark2-hardware-setup.sh` and a reboot.

> **Note:** This project previously used Wyoming Satellite. Replaced by LVA in April 2026
> when Nabu Casa deprecated wyoming-satellite. See [HISTORY.md](HISTORY.md) for background.

---

## What it does (in order)

### 1. HA URL prompt

Loads `~/.config/mark2/config` if it exists. If `HA_URL` is not set, prompts for it.

### 2. SJ201 audio device detection

Verifies SJ201 is present via ALSA. Audio routing uses PipeWire virtual devices — see below.

### 3. Dependencies

```
apt install git python3 python3-venv python3-dev alsa-utils libmpv2
```

`libmpv2` is required by LVA's python-mpv dependency for audio playback.

### 4. PipeWire virtual audio devices

Two PipeWire virtual devices are created:

**Microphone source** (`~/.config/pipewire/pipewire.conf.d/sj201-asr.conf`):
```
SJ201 ASR (VF_ASR_L)  ←  ALSA VF_ASR_(L)
```
`VF_ASR_(L)` is the XMOS XVF-3510's dedicated ASR channel — 16kHz mono at RMS~500+.
Without this, PipeWire only sees raw 48kHz stereo at RMS~17, too low for OWW.

**Speaker sink** (`~/.config/pipewire/pipewire.conf.d/sj201-output.conf`):
```
SJ201 Speaker  →  plughw:CARD=sj201,DEV=0
```
Pi's I2S bus is half-duplex at the ALSA driver level. If LVA holds the mic open and
any process does direct ALSA playback, the kernel panics (system reboot). This PipeWire
virtual sink owns the ALSA device and multiplexes capture + playback safely.

### 5. Linux Voice Assistant

Clones [OHF-Voice/linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant)
to `~/lva` and runs `python3 script/setup`.

LVA uses the ESPHome protocol and includes OWW/MWW wake word detection, timers,
announcements, continue-conversation, and auto-discovery in HA.

### 6. lva.service

```ini
ExecStart=/home/pi/lva/.venv/bin/python3 -m linux_voice_assistant \
    --name Nabu-1 \
    --wake-model okay_nabu \
    --audio-input-device "SJ201 ASR (VF_ASR_L)" \
    --audio-output-device "pipewire/sj201-output"
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
Environment=PIPEWIRE_RUNTIME_DIR=/run/user/1000
Environment=PULSE_RUNTIME_PATH=/run/user/1000/pulse
Environment=WAYLAND_DISPLAY=wayland-1
```

Key points:
- `WAYLAND_DISPLAY=wayland-1` — Weston uses `wayland-1`, required for PipeWire socket access
- `PIPEWIRE_RUNTIME_DIR` + `PULSE_RUNTIME_PATH` — required from systemd user service context
- `After=pipewire.service wireplumber.service` — PipeWire must be ready before LVA starts
- `pipewire/sj201-output` — named PipeWire sink; generic 'pipewire' device freezes MPV on aarch64/Python 3.13

### 7. mark2-wait-pipewire

Installed as `/usr/local/bin/mark2-wait-pipewire`. Used as `ExecStartPre` in `lva.service`.

`wireplumber` is `Type=simple` and does not signal readiness to systemd. Without this,
`After=wireplumber.service` only waits for the process to start — not for the virtual
devices to appear in the PipeWire graph.

Polls `wpctl status` for both `SJ201 ASR` and `SJ201 Speaker` with up to 30s timeout.

### 8. mark2-face-events.service

Polls the HA assist_satellite REST API every 0.5s and writes voice state to
`/tmp/mark2-face-event.json`. Used by the LED ring and HUD overlay.

```
HA state      → face state
idle          → idle
listening     → listen
processing    → think
responding    → speak
```

Entity auto-discovered by hostname slug: `assist_satellite.<hostname>_lva_assist_satellite`

---

## LED ring

The SJ201 LED ring is 12x WS2812 NeoPixel LEDs on GPIO12 — **not I2C**.

### Architecture

```
HA satellite state
  → mark2-face-events (polls HA API, 0.5s)
  → /tmp/mark2-face-event.json
  → mark2-led-events (polls JSON, 0.3s)
  → /tmp/mark2-leds.sock (Unix socket)
  → mark2-leds (NeoPixel controller, root)
  → GPIO12 → LED ring hardware
```

### Services

**`mark2-leds.service`** — system service (root, NeoPixel needs GPIO access):
```ini
User=root
Environment=BLINKA_FORCEBOARD=RASPBERRY_PI_4B
TimeoutStopSec=15
KillMode=process
```
`BLINKA_FORCEBOARD` is required — without it, `pixels.show()` hangs under systemd
due to a DMA interaction issue on RPi4.

**`mark2-led-events.service`** — user service (pi), polls JSON, sends to socket.

### LED states

| Voice state | LED pattern | Color |
|-------------|-------------|-------|
| idle | off | — |
| listen | solid | blue |
| think | spinning comet | cyan |
| speak | solid | green |
| error | flash | red |
| mute | solid dim | amber |

### Manual test
```bash
echo "listen" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
echo "think"  | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
echo "speak"  | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
echo "idle"   | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
```

---

## Service dependency graph

```
sj201.service
pipewire.service + wireplumber.service
    └── [mark2-wait-pipewire polls for SJ201 devices]
    └── lva.service
            └── mark2-face-events.service  (/tmp/mark2-face-event.json)
                    └── mark2-led-events.service → /tmp/mark2-leds.sock
mark2-leds.service             (system service, root — NeoPixel GPIO12)
mark2-volume-buttons.service   (independent — TAS5806 + HUD + action wake)

Weston (kiosk compositor)
    └── startup.sh
            └── kiosk.sh
                    ├── build-combined.py  (builds combined.html)
                    ├── mark2-httpd.py     (serves :8088)
                    └── Chromium kiosk     (http://localhost:8088/combined.html)
                            ├── HA iframe           (tap to open)
                            ├── Animated face       (reads /tmp/mark2-face-event.json)
                            ├── Passive clock+weather (idle mode, fetches HA REST API)
                            └── Volume bar overlay  (reads /tmp/mark2-overlay-event.json)
```

---

## Kiosk display architecture

The touchscreen runs Chromium in full-screen kiosk mode under Weston (DRM/KMS backend).

### Combined page

`kiosk.sh` calls `build-combined.py` at startup to generate `combined.html` — a single
page that contains all UI layers:

| Layer | z-index | Content |
|-------|---------|---------|
| HA iframe | 1 | Home Assistant dashboard (tap-to-open) |
| Passive clock | 1 | Clock + weather, shown when idle |
| Music artwork | 2 | Album art when MPD/Music Assistant plays |
| Animated face | 3 | Voice state animation |
| HUD overlays | 4 | Volume bar, status pill |
| Content panel | 5 | Announcements, notifications |

### Display states

| State | What is shown |
|-------|--------------|
| Idle (passive) | Clock + weather, HA pill button bottom-left |
| Voice active | Face fullscreen, clock+HA hidden |
| Music playing | Album art + small face |
| HA open | HA dashboard, face/clock hidden |

### Screen blank

Weston blanks the display after **5 minutes** of no touch input (`--idle-time=300`).
Touch or a voice interaction wakes the screen immediately.

### HTTP server

`mark2-httpd.py` runs on port **8088** and serves:
- `combined.html` — the kiosk page
- `/face-event.json` → `/tmp/mark2-face-event.json`
- `/overlay-event.json` → `/tmp/mark2-overlay-event.json`
- `/sounds/<file>` → `~/lva/sounds/<file>` (used for action button wake)
- `/ha/*` → reverse-proxy to HA, stripping `X-Frame-Options`

---

## Boot splash

Two-phase boot splash covers the full boot from power-on to dashboard:

**Phase 1 — Plymouth** (0–15s, kernel boot):
- Installed by `lib/install-plymouth.sh` (called from `modules/ui.sh`)
- Custom `mark2` Plymouth script theme: dark background, Mark II face, title, progress bar
- Face pulses gently via `SetRefreshFunction`
- `cmdline.txt` flags: `quiet splash plymouth.ignore-serial-consoles vt.global_cursor_default=0 vt.handoff=2`
- `mark2-tty1-blank.service` clears tty1 to black before getty starts

**Phase 2 — Chromium splash** (15–25s, Weston/Chromium startup):
- `templates/splash.html` — animated face opens eyes, progress bar, logo pills
- Served by `mark2-httpd` on `:8088/splash.html`
- Polls HA proxy until reachable, then fades to `combined.html`
- Built with hostname substitution by `kiosk.sh` on every boot

Re-install or update Plymouth theme:
```bash
sudo bash lib/install-plymouth.sh
```

---

## Audio architecture

```
XMOS XVF-3510
  Capture:  ALSA VF_ASR_(L) → PipeWire "SJ201 ASR (VF_ASR_L)" → LVA → OWW
  Playback: PipeWire "SJ201 Speaker" → plughw:sj201,DEV=0 → XMOS → TAS5806 → Speaker
```

### python-mpv / PipeWire note

On aarch64/Python 3.13, `python-mpv`'s `end-file` callback never fires with the generic
`pipewire` device — MPV freezes at position 0.021s. The named sink `pipewire/sj201-output`
gives reliable callbacks. This is a known aarch64 MPV/PipeWire interaction issue.

---

## Volume control

TAS5806 I2C register `0x4c`, logarithmic scale (matches Mycroft sj201-interface):

| % | Reg | dB |
|---|-----|----|
| 100% | `0x54` | -42.0 dB (max safe) |
| 75% | `0x6a` | -53.0 dB |
| **60%** | **`0x79`** | **-60.5 dB (default)** |
| 50% | `0x85` | -66.5 dB |
| 25% | `0xa7` | -83.5 dB |
| 0% | `0xd2` | -105.0 dB |

Hardware buttons adjust in 5% steps via `mark2-volume-buttons.service`.

---

## Wake words

| Model | Phrase |
|-------|--------|
| `okay_nabu` | "Ok Nabu" **(default)** |
| `hey_home_assistant` | "Hey Home Assistant" |
| `hey_mycroft` | "Hey Mycroft" |
| `hey_jarvis` | "Hey Jarvis" |
| `alexa` | "Alexa" |
| `okay_computer` | "Okay Computer" |

Change wake word:
```bash
nano ~/.config/systemd/user/lva.service  # edit --wake-model
systemctl --user daemon-reload && systemctl --user restart lva
```

---

## HA integration

LVA auto-discovers as an ESPHome device, exposing:
- `assist_satellite.<n>` — voice state (idle/listening/processing/responding)
- `select.<n>_assistant` — choose Assist pipeline
- `media_player.<n>` — for announcements
- `switch.<n>_mute` — mic mute
- `number.<n>_mic_volume` — gain
- `select.<n>_finished_speaking_detection` — VAD sensitivity

### ⚠️ Set the voice pipeline after first discovery

When LVA is first discovered, the Assist pipeline defaults to `preferred`
(HA's default pipeline). **You must set it manually** to your desired pipeline.

In HA: **Settings → Voice Assistants → your Mark II device → select pipeline**

Or via service call:
```bash
curl -X POST http://<HA_IP>:8123/api/services/select/select_option \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "select.<device>_assistant", "option": "Claude"}'
```

Without this step the satellite uses HA's default pipeline, which may not
be what you want. The setup script reminds you of this step in its summary.

---

## Troubleshooting

**LVA not connecting:**
```bash
systemctl --user status lva
journalctl --user -u lva -n 50  # look for "Connected to Home Assistant"
```

**No wake word detection:**
```bash
wpctl status | grep ASR  # should show: SJ201 ASR (VF_ASR_L)
```

**No audio / system reboot during playback:**
```bash
wpctl status | grep Speaker  # should show: SJ201 Speaker
systemctl --user restart pipewire pipewire-pulse wireplumber
```

**LED ring not lighting up:**
```bash
sudo systemctl status mark2-leds
systemctl --user status mark2-led-events
ls -la /tmp/mark2-leds.sock      # socket must exist
cat /tmp/mark2-face-event.json   # face state should match HA state
echo "listen" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock  # manual test
```

**All services:**
```bash
mark2-status  # shows all services, audio, HA connection
# or individually:
systemctl --user status lva sj201 mark2-volume-buttons mark2-face-events mark2-led-events
sudo systemctl status mark2-leds
```
