# Satellite & Kiosk Setup — Technical Documentation

`mark2-satellite-setup.sh` installs the Linux Voice Assistant (LVA), Weston kiosk display,
and all supporting services. Run this after `mark2-hardware-setup.sh` and a reboot.

> **Note:** This project previously used Wyoming Satellite. Replaced by LVA in April 2026
> when Nabu Casa deprecated wyoming-satellite. See [HISTORY.md](HISTORY.md) for background.

---

## Prerequisites

- `mark2-hardware-setup.sh` completed successfully
- Rebooted after hardware setup
- SJ201 ALSA card visible: `aplay -l | grep sj201`

---

## What it does (in order)

### 1. HA URL prompt

Loads `~/.config/mark2/config` if it exists. If `HA_URL` is not set, prompts for it.

### 2. SJ201 audio device detection

Verifies SJ201 is present via ALSA (`hw:sj201,0` playback, `hw:sj201,1` capture).

### 3. XVF3510 initialization service (mark2-audio-init)

Installs and enables `mark2-audio-init.service` — a user-scope oneshot service that
runs on every boot. This is the most critical piece for microphone functionality.

**Why this is needed:** `sj201.dtbo` sets MCLK=24.576MHz on GPIO4, but the XVF3510-INT
requires exactly 12.288MHz to start its DSP pipeline. Without this service, the
microphone is permanently silent after boot.

The service runs `/usr/local/bin/mark2-xvf-post-wp.sh` which executes:
```
setup_mclk    → GPIO4/GPCLK0 = 12.288MHz
setup_bclk    → PCM clock divider = 3.072MHz BCLK
xvf3510-flash → SPI slave boot (192KB firmware)
init_tas5806  → TAS5806 amplifier init
restart PipeWire/WirePlumber
start lva.service
```

See [XVF3510_HARDWARE.md](XVF3510_HARDWARE.md) for full technical details.

### 4. PipeWire audio routing

WirePlumber manages both SJ201 devices in pro-audio mode
(`~/.config/wireplumber/wireplumber.conf.d/90-sj201-profile.conf`):

| PipeWire node | Direction | ALSA device |
|---------------|-----------|-------------|
| `alsa_output.hw:sj201,0` | Playback | TAS5806 amplifier |
| `Built-in Audio (bcm2835-i2s-dir-hifi dir-hifi-1)` | Capture | XVF3510 mic |

**Speaker sink** (`~/.config/pipewire/pipewire.conf.d/sj201-output.conf`):
Creates a named sink `sj201-output` → `plughw:CARD=sj201,DEV=0` for reliable
python-mpv playback callbacks.

`pipewire-alsa` package is required for ALSA→PipeWire routing.

### 5. Linux Voice Assistant

Clones [OHF-Voice/linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant)
to `~/lva` and runs `python3 script/setup`.

LVA uses the ESPHome protocol and includes OWW/MWW wake word detection, timers,
announcements, continue-conversation, and auto-discovery in HA.

### 6. lva.service

```ini
ExecStart=.../python3 -m linux_voice_assistant \
    --name 'Nabu-1' \
    --wake-model 'okay_nabu' \
    --audio-input-device 'Built-in Audio (bcm2835-i2s-dir-hifi dir-hifi-1)' \
    --audio-output-device 'pipewire/alsa_output.hw:sj201,0'
```

**Important:** Use the PipeWire node name for `--audio-input-device`, not `hw:sj201,1`.
WirePlumber holds `hw:sj201,1` exclusively; direct access fails with "Device or resource busy".

Run `python3 -m linux_voice_assistant --list-input-devices` to see available names.

### 7. Supporting services

| Service | Description |
|---------|-------------|
| `mark2-face-events.service` | LVA state → `/tmp/mark2-face-event.json` |
| `mark2-led-events.service` | Face events → LED ring animation |
| `mark2-volume-buttons.service` | Hardware volume buttons → TAS5806 |
| `mark2-volume-monitor.service` | Volume overlay in HUD |
| `mark2-mqtt-bridge.service` | Hardware sensors → HA via MQTT |

### 8. Weston + Chromium kiosk

Installs Weston (Wayland compositor) and Chromium in kiosk mode showing the HA dashboard.
Auto-login on tty1 starts Weston, which launches Chromium pointing to the HA URL.

---

## Boot sequence (after setup)

```
systemd user session starts
  └── mark2-audio-init.service (oneshot, After=network.target)
        ├── setup_mclk (MCLK=12.288MHz)
        ├── setup_bclk (BCLK=3.072MHz)
        ├── xvf3510-flash (SPI slave boot)
        ├── init_tas5806
        ├── restart pipewire + wireplumber
        └── start lva.service
              └── LVA connects to HA, listens for "okay nabu"
```

---

## Verification

```bash
# Services running?
systemctl --user status mark2-audio-init lva wireplumber pipewire

# Microphone producing signal?
pw-record --rate 16000 --channels 1 --format s16 /tmp/test.wav
# (wait 3s, Ctrl-C, then check with aplay or sox)

# LVA connected to HA?
journalctl --user -u lva -f
# Look for: ✅ Connected to Home Assistant

# PipeWire nodes?
wpctl status | grep -A10 "Sources:"
# Should show: Built-in Audio (bcm2835-i2s-dir-hifi dir-hifi-1)
```

---

## Troubleshooting

**Microphone silent after boot:**
```bash
journalctl --user -u mark2-audio-init
bash /usr/local/bin/mark2-xvf-post-wp.sh
```

**LVA "Device or resource busy":**
- WirePlumber is holding `hw:sj201,1`
- Use PipeWire node name instead (see lva.service above)

**LVA not connecting to HA:**
```bash
systemctl --user restart lva
journalctl --user -u lva -f
```

**Kiosk not starting:**
```bash
journalctl -u getty@tty1 -f
cat /tmp/mark2-kiosk.log
```
