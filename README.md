# mark2-assist

Setup suite for running Mycroft Mark II as a Home Assistant voice satellite with touchscreen kiosk display.

## What it does

- **Wyoming voice satellite** — Mark II works as a fully featured voice assistant satellite in Home Assistant using Wyoming Protocol and openWakeWord
- **Touchscreen kiosk** — DSI touchscreen shows your HA dashboard on boot, full screen, no browser UI
- **LED ring** — SJ201 LED ring reacts to wake word, listening, speaking, and errors
- **Animated face** — OLED-style face overlay that reacts to voice states and dances to music
- **MQTT sensors** — publishes Wyoming state, MPD playback, CPU temp, memory, and disk usage to HA
- **Optional audio** — Snapcast multiroom, AirPlay, MPD local music player
- **Optional extras** — KDE Connect (Android phone integration), USB audio fallback

## Hardware

- Mycroft Mark II (Raspberry Pi 4B + SJ201 audio board + Waveshare 4.3" DSI touchscreen)
- Raspberry Pi OS Lite **Trixie** (Debian 13, 64-bit)

## Quick start

```bash
git clone https://github.com/andlo/mark2-assist
cd mark2-assist
./install.sh
```

The installer guides you through everything. It reboots once mid-way through hardware setup, then resumes automatically.

## What you need before installing

- Raspberry Pi OS Lite Trixie flashed to SD card (use Raspberry Pi Imager)
- SSH enabled and network connected
- Your Home Assistant URL (e.g. `http://192.168.1.100:8123`)
- A Home Assistant long-lived access token (for MQTT sensors and screensaver)

## Installation steps

The installer runs in three phases:

1. **Hardware setup** — SJ201 audio drivers, SPI/I2C, display overlay, kernel watchdog → reboots
2. **Satellite + kiosk** — Wyoming satellite, openWakeWord, Chromium kiosk, labwc Wayland, PipeWire
3. **Optional modules** — choose what you want from a menu

Total install time: approximately 20–30 minutes depending on network speed.

---

## Auto-login on the touchscreen

After installation, the touchscreen shows your Home Assistant dashboard. The first time it opens, HA shows a login screen. To enable **automatic login without a keyboard**, add the following to your Home Assistant `configuration.yaml`:

```yaml
homeassistant:
  auth_providers:
    - type: homeassistant
    - type: trusted_networks
      trusted_networks:
        - 192.168.65.37  # Replace with your Mark II's IP address
      allow_bypass_login: true
```

Then restart Home Assistant (Settings → System → Restart).

**How to find your Mark II's IP address:**

```bash
hostname -I
```

**How to edit configuration.yaml in HA:**

The easiest way is via **Studio Code Server** add-on in HA, or via **File Editor** add-on.
Navigate to `/config/configuration.yaml` and add the block above.

After restarting HA, the touchscreen will log in automatically on every boot — no keyboard needed.

> **Note:** `allow_bypass_login: true` means anyone on your local network who knows the IP can access HA without a password. This is fine for a trusted home network. If you need more security, add specific `trusted_users` — see [HA docs](https://www.home-assistant.io/docs/authentication/providers/#trusted-networks).

---

## Adding Mark II to Home Assistant

After installation, add the Wyoming integration in HA:

1. Settings → Devices & Services → Add Integration
2. Search for **Wyoming Protocol**
3. Host: `<Mark II IP address>` — Port: `10700`

Mark II will appear as **Nabu-1** (or your hostname) and is ready to use as a voice satellite.

---

## Wake word

Default wake word is **"Ok Nabu"**. Available options:

| Wake word | Say |
|-----------|-----|
| `ok_nabu` | "Ok Nabu" |
| `hey_mycroft` | "Hey Mycroft" |
| `alexa` | "Alexa" |
| `hey_jarvis` | "Hey Jarvis" |

To change wake word, edit `/home/pi/.config/systemd/user/wyoming-satellite.service` and change `--wake-word-name`.

---

## Optional modules

| Module | What it does |
|--------|-------------|
| **leds** | SJ201 LED ring reacts to wake/listen/speak/error states |
| **face** | Animated face overlay — zooms in on voice, reacts to music |
| **overlay** | On-screen volume bar, auto-hides after 3 seconds |
| **screensaver** | Fullscreen clock + weather from HA, activates after 2 min idle |
| **mqtt-sensors** | Publishes Wyoming state, MPD, CPU/memory/disk to HA via MQTT |
| **snapcast** | Synchronized multiroom audio endpoint |
| **airplay** | Mark II as AirPlay 1 speaker |
| **mpd** | Local music player (works with Music Assistant) |
| **kdeconnect** | Android phone integration — notifications, media control |
| **usb-audio** | Fallback audio device if SJ201 fails at boot |

---

## Troubleshooting

**Touchscreen is black after boot**

Check that the Waveshare overlay is loaded:
```bash
grep vc4-kms-dsi-waveshare /boot/firmware/config.txt
```
Should show `dtoverlay=vc4-kms-dsi-waveshare-800x480`. If missing, run `mark2-hardware-setup.sh` again.

**Wyoming satellite not showing in HA**

Check the service status:
```bash
systemctl --user status wyoming-satellite
```
If it shows errors, check the log:
```bash
journalctl --user -u wyoming-satellite -n 30
```

**Voice commands not working**

Check that openWakeWord is running:
```bash
systemctl --user status wyoming-openwakeword
```
Test the microphone:
```bash
arecord -D plughw:CARD=sj201,DEV=1 -r 16000 -c 1 -f S16_LE -d 3 /tmp/test.wav && aplay /tmp/test.wav
```

**HA dashboard shows "Unable to connect"**

This usually means `trusted_networks` is not configured in HA. See the auto-login section above.

**Kiosk not starting after reboot**

Check the kiosk log:
```bash
cat /tmp/mark2-kiosk.log
```

---

## File locations

| File | Purpose |
|------|---------|
| `~/.config/mark2/config` | Saved configuration (HA URL, token, etc.) |
| `~/.config/mark2/install.log` | Full installation log |
| `~/.config/labwc/autostart` | Wayland compositor autostart |
| `~/kiosk.sh` | HA kiosk launcher |
| `~/startup.sh` | labwc startup script |
| `/tmp/mark2-kiosk.log` | Kiosk runtime log |
| `/tmp/mark2-startup.log` | Startup script log |

---

## Uninstall

```bash
./uninstall.sh
```

This removes all services, packages, and configuration installed by mark2-assist.

---

## License

MIT
