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

### 7. mark2-face-events.service

Polls HA satellite entity state and writes `/tmp/mark2-face-event.json` for HUD overlays.

```
idle → idle | listening → listen | processing → think | responding → speak
```

---

## Service dependency graph

```
sj201.service
pipewire.service + wireplumber.service
    └── lva.service
            └── mark2-face-events.service
mark2-volume-buttons.service   (independent)
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

**All services:**
```bash
systemctl --user status lva sj201 mark2-volume-buttons mark2-face-events
```
