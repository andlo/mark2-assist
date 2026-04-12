# Mycroft Mark II Assist

<p align="center">
  <img src="https://img.shields.io/badge/Mycroft-Mark%20II-blue?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0id2hpdGUiIGQ9Ik0xMiAyQzYuNDggMiAyIDYuNDggMiAxMnM0LjQ4IDEwIDEwIDEwIDEwLTQuNDggMTAtMTBTMTcuNTIgMiAxMiAyem0tMiAxNWwtNS01IDEuNDEtMS40MUwxMCAxNC4xN2w3LjU5LTcuNTlMMTkgOGwtOSA5eiIvPjwvc3ZnPg==" alt="Mycroft Mark II">
  <img src="https://img.shields.io/badge/Home%20Assistant-Assist-41BDF5?style=for-the-badge&logo=home-assistant&logoColor=white" alt="Home Assistant Assist">
  <img src="https://img.shields.io/badge/Wyoming-Satellite-green?style=for-the-badge" alt="Wyoming Satellite">
  <img src="https://img.shields.io/badge/Debian-Trixie-A81D33?style=for-the-badge&logo=debian&logoColor=white" alt="Debian Trixie">
</p>

<p align="center">
  <strong>Repurpose your Mycroft Mark II as a Home Assistant voice satellite with touchscreen kiosk display.</strong>
</p>

<p align="center">
  Powered by Home Assistant Assist — you choose the pipeline.
</p>

---

**mark2-assist** installs everything needed to use a Mycroft Mark II as a fully featured
Home Assistant voice satellite: Wyoming Protocol integration, wake word detection,
touchscreen HA dashboard, LED ring feedback, animated face, volume overlay, screensaver,
MQTT sensors, and optional audio streaming.

The voice pipeline runs entirely through Home Assistant Assist — meaning you choose what
powers each step. Wake word runs locally on the device. STT, TTS and conversation can be
anything HA supports: fully local (Whisper, Piper), cloud (Nabu Casa), or AI-powered
(OpenAI, Claude via custom conversation agents, OVOS, or any other HA integration).

## Hardware

| Component | Details |
|-----------|---------|
| Base board | Mycroft Mark II carrier board |
| Compute | Raspberry Pi 4 Model B (2 GB or 4 GB RAM) |
| Audio | SJ201 board (XMOS XVF-3510 mic array + TAS5806 amp) |
| Display | Waveshare 4.3" 800×480 DSI touchscreen |
| OS | Raspberry Pi OS Lite **Trixie** (Debian 13, 64-bit) |
| Kernel | 6.x (vc4-kms-v3d, not fkms) |

> **Note:** Pi 5 is partially supported (separate SJ201 overlays exist) but untested.

---

## What gets installed

### Core (always installed)
- **SJ201 hardware driver** — VocalFusion kernel module, XVF-3510 firmware flash, TAS5806 amp init, WirePlumber profile
- **Wyoming satellite** — Voice satellite using [wyoming-satellite](https://github.com/rhasspy/wyoming-satellite) + [wyoming-openwakeword](https://github.com/rhasspy/wyoming-openwakeword)
- **Touchscreen kiosk** — Weston Wayland compositor + Chromium in kiosk mode showing your HA dashboard
- **Face event bridge** — Monitors Wyoming states, writes `/tmp/mark2-face-event.json` for HUD overlays

### Optional modules (choose during install)
| Module | What it does |
|--------|-------------|
| **homeassistant** | Show HA dashboard on the touchscreen (on by default) |
| **leds** | SJ201 LED ring reacts to wake/listen/speak/error/idle states |
| **face** | Animated face overlay — zooms in on voice, dances to music |
| **overlay** | On-screen volume bar — appears on volume change, auto-hides |
| **screensaver** | Fullscreen clock + live weather from HA, activates after 2 min idle |
| **mqtt-sensors** | Publishes Wyoming state, MPD playback, CPU/memory/disk/temp to HA via MQTT |
| **snapcast** | Snapcast multiroom audio endpoint |
| **airplay** | AirPlay 1 speaker via shairport-sync |
| **mpd** | Local music player (works with Music Assistant in HA) |
| **kdeconnect** | Android phone integration — notifications, media control |
| **usb-audio** | Fallback audio device if SJ201 fails at boot |

> Without the **homeassistant** module the touchscreen still shows the
> animated face and clock — Mark II works as a pure voice satellite.

---

## Prerequisites

Before running the installer you need:

1. **Raspberry Pi OS Lite Trixie** (64-bit) flashed to SD card via [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
   - Enable SSH and set username/password in Imager advanced settings
2. **SSH access** to the device on your local network
3. **Home Assistant** running on your local network
4. **HA Long-Lived Access Token** — for MQTT sensors and screensaver
   - In HA: Profile (bottom left) → Long-Lived Access Tokens → Create token

---

## Hardware test

After running `mark2-hardware-setup.sh` and rebooting, run the hardware test
to verify all components before proceeding with satellite/kiosk installation:

```bash
./mark2-hardware-test.sh
```

The test covers all Mark II hardware components interactively:

| # | Test | What it checks |
|---|------|---------------|
| 1 | SJ201 Service | Firmware loaded, kernel module, XMOS init wait |
| 2 | Audio Devices | ALSA sees SJ201 for capture and playback |
| 3 | Microphone + Roundtrip | One recording: checks signal level AND plays back |
| 4 | Speaker | Verified by roundtrip, or separate beep if needed |
| 5 | LED Ring | NeoPixel GPIO12 cycles red/green/blue/white |
| 6 | Buttons | evdev events from volume up/down/action |
| 7 | Touchscreen & Display | DSI display + touch input device |
| 8 | Backlight | Dims and restores display brightness |
| 9 | I2C Bus | Scans bus 1 for 0x2c and 0x2f |
| 10 | SPI Bus | /dev/spidev0.0 exists |

If any tests fail, fix them before running `./install.sh` — the installer
also offers to run the hardware test automatically after reboot.

Non-interactive mode (for scripted use):
```bash
./mark2-hardware-test.sh --auto
```

---

## Quick start

```bash
git clone https://github.com/andlo/mark2-assist
cd mark2-assist
./install.sh
```

The installer will:
1. Ask all questions upfront (HA URL, token, MQTT credentials, which modules to install)
2. Run hardware setup and reboot automatically
3. Resume after reboot and install Wyoming satellite + kiosk
4. Install your chosen optional modules
5. Reboot to the finished system

Total time: **20–40 minutes** depending on network speed.

---

## Auto-login on the touchscreen

After installation the touchscreen shows your HA dashboard and prompts for login.
To enable **automatic login without a keyboard**, add the following to your HA
`configuration.yaml` and restart HA:

```yaml
homeassistant:
  auth_providers:
    - type: homeassistant
    - type: trusted_networks
      trusted_networks:
        - 192.168.1.x        # Replace with your Mark II's exact IP address
      trusted_users:
        192.168.1.x:         # Same IP as above
          - YOUR_USER_ID     # Find in HA: Settings → People → click user → ID in URL
      allow_bypass_login: true
```

**How to find your user ID:**
In HA go to Settings → People → click your user. The URL ends with
`/config/users/edit/abc123def456` — that last part is your user ID.

**How to find Mark II's IP:**
```bash
hostname -I
```

**How to edit configuration.yaml in HA:**
Use the Studio Code Server add-on or File Editor add-on.
Navigate to `/config/configuration.yaml` and add the block above.

After restarting HA and rebooting Mark II, the dashboard loads automatically — no keyboard needed.

> **Security note:** `allow_bypass_login: true` grants passwordless access from that specific IP.
> Using the exact device IP (not a whole subnet like `192.168.1.0/24`) limits this to your
> Mark II only. Always keep `- type: homeassistant` as the first provider so you can still
> log in from other devices with a password.

---

## Adding Mark II to Home Assistant

After installation add the Wyoming integration in HA:

1. Settings → Devices & Services → Add Integration
2. Search for **Wyoming Protocol**
3. Host: `<Mark II IP address>` — Port: `10700`

Mark II will appear as your **hostname** (e.g. `Nabu-1`) and is immediately ready
to use as an Assist satellite. Say your wake word to test it.

---

## Wake word

Default wake word is **"Ok Nabu"**.

| Option | What to say |
|--------|-------------|
| `ok_nabu` | "Ok Nabu" |
| `hey_mycroft` | "Hey Mycroft" |
| `alexa` | "Alexa" |
| `hey_jarvis` | "Hey Jarvis" |

To change the wake word after installation:
```bash
nano ~/.config/systemd/user/wyoming-satellite.service
# Edit the --wake-word-name value
systemctl --user daemon-reload
systemctl --user restart wyoming-satellite
```

---

## Keeping the system updated

Run the update script to update everything at once:

```bash
cd ~/mark2-assist
./update.sh
```

This updates system packages, mark2-assist scripts, Wyoming satellite and openWakeWord, and restarts all services. Wyoming setup only re-runs if new commits were pulled.

Optional flags:
- `--skip-apt` — skip system package update
- `--skip-wyoming` — skip Wyoming update
- `--skip-restart` — skip service restart
- `--yes` — non-interactive, no confirmation prompt

### Manual component updates
```bash
sudo apt update && sudo apt upgrade
```

A safe weekly update also runs automatically every Sunday at 03:00 via cron.
After any kernel update the VocalFusion audio driver is automatically rebuilt
by `mark2-vocalfusion-watchdog.service` before the next boot — no manual action needed.

### mark2-assist scripts
```bash
cd ~/mark2-assist
git pull
```

Re-run the relevant setup script to apply changes:
```bash
./mark2-satellite-setup.sh   # Update kiosk/Wyoming configuration
./mark2-hardware-setup.sh    # Update hardware/driver configuration (rare)
```

Individual modules can be re-run at any time:
```bash
bash modules/leds.sh
bash modules/mqtt-sensors.sh
# etc.
```

### Wyoming satellite and openWakeWord
```bash
cd ~/wyoming-satellite && git pull && python3 script/setup
cd ~/wyoming-openwakeword && git pull && python3 script/setup
systemctl --user restart wyoming-satellite wyoming-openwakeword
```

---

## Uninstalling

```bash
cd ~/mark2-assist
./uninstall.sh
```

This removes:
- All mark2-assist systemd user services (Wyoming, kiosk, LEDs, face, overlay, MQTT, etc.)
- Installed packages (Chromium, weston, snapcast, shairport-sync, mpd, etc.)
- Configuration files in `~/.config/mark2/`, `~/.config/mark2-kiosk/`, etc.
- Weston/labwc autostart from `~/.bash_profile`
- Auto-login getty override in `/etc/systemd/system/getty@tty1.service.d/`

It does **not** remove:
- The VocalFusion kernel module (rebooting clears it from memory; `.ko` file stays)
- Boot overlay entries in `/boot/firmware/config.txt` (remove manually if needed)
- The `~/wyoming-satellite` and `~/wyoming-openwakeword` directories
- The mark2-assist git repository itself

---

## Troubleshooting

**Touchscreen is black after boot**
```bash
grep vc4-kms-dsi-waveshare /boot/firmware/config.txt
# Should show: dtoverlay=vc4-kms-dsi-waveshare-800x480
# If missing: ./mark2-hardware-setup.sh && sudo reboot
```

**Wyoming satellite not showing in HA**
```bash
systemctl --user status wyoming-satellite
journalctl --user -u wyoming-satellite -n 30
```

**Test microphone directly**
```bash
arecord -D plughw:CARD=sj201,DEV=1 -r 16000 -c 1 -f S16_LE -d 3 /tmp/test.wav
aplay /tmp/test.wav
```

**HA dashboard shows login screen instead of auto-login**
- Verify trusted_networks is configured in `configuration.yaml` (see above)
- Verify the IP in config matches Mark II's actual IP exactly (not a subnet)
- Restart HA after any configuration.yaml change

**Kiosk not starting after reboot**
```bash
cat /tmp/mark2-startup.log
cat /tmp/weston.log
```

**Check all service statuses**
```bash
systemctl --user status wyoming-satellite wyoming-openwakeword sj201 mark2-face-events
```

---

## File locations reference

| Path | Purpose |
|------|---------|
| `~/.config/mark2/config` | Saved install configuration (HA URL, token, MQTT credentials) |
| `~/.config/mark2/install.log` | Full installation log |
| `~/.config/mark2/install-progress` | Tracks which install steps have completed (for resume after reboot) |
| `~/startup.sh` | Weston startup script — called by weston `--` flag, launches kiosk + hud |
| `~/kiosk.sh` | HA Chromium kiosk launcher — waits for HA then opens in kiosk mode |
| `~/hud.sh` | HUD overlay launcher — face animation + volume bar on top of kiosk |
| `~/.config/mark2-kiosk/hud.html` | HUD overlay HTML template |
| `/tmp/mark2-startup.log` | Weston startup runtime log (recreated each boot) |
| `/tmp/mark2-kiosk.log` | Kiosk runtime log |
| `/tmp/weston.log` | Weston Wayland compositor log |
| `/tmp/mark2-face-event.json` | Current Wyoming state written by face-event bridge for HUD |
| `/tmp/mark2-leds.sock` | Unix socket — send state strings to control LED ring |

---

## Documentation

See the `docs/` directory for detailed technical documentation:

- [`docs/HISTORY.md`](docs/HISTORY.md) — History of Mark II, Mycroft, OVOS and HA Assist
- [`docs/INSTALL_SH.md`](docs/INSTALL_SH.md) — Install script architecture and flow
- [`docs/HARDWARE_SETUP.md`](docs/HARDWARE_SETUP.md) — Hardware setup technical deep dive
- [`docs/SATELLITE_SETUP.md`](docs/SATELLITE_SETUP.md) — Wyoming satellite setup deep dive
- [`docs/MODULES.md`](docs/MODULES.md) — All optional modules documented in detail
- [`docs/HA_INTEGRATION.md`](docs/HA_INTEGRATION.md) — HA companion integration spec

---

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.

This project uses code adapted from [OpenVoiceOS/ovos-installer](https://github.com/OpenVoiceOS/ovos-installer)
(Apache 2.0) for the SJ201 hardware setup routines.
