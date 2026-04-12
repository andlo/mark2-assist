# Mycroft Mark II Assist

<p align="center">
  <img src="https://img.shields.io/badge/Mycroft-Mark%20II-blue?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0id2hpdGUiIGQ9Ik0xMiAyQzYuNDggMiAyIDYuNDggMiAxMnM0LjQ4IDEwIDEwIDEwIDEwLTQuNDggMTAtMTBTMTcuNTIgMiAxMiAyem0tMiAxNWwtNS01IDEuNDEtMS40MUwxMCAxNC4xN2w3LjU5LTcuNTlMMTkgOGwtOSA5eiIvPjwvc3ZnPg==" alt="Mycroft Mark II">
  <img src="https://img.shields.io/badge/Home%20Assistant-Assist-41BDF5?style=for-the-badge&logo=home-assistant&logoColor=white" alt="Home Assistant Assist">
  <img src="https://img.shields.io/badge/Linux%20Voice%20Assistant-ESPHome-green?style=for-the-badge" alt="Linux Voice Assistant">
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
Home Assistant voice satellite: voice integration via [Linux Voice Assistant](https://github.com/OHF-Voice/linux-voice-assistant) (ESPHome protocol), local wake word detection,
touchscreen HA dashboard, LED ring feedback, animated face, volume overlay, screensaver,
MQTT sensors, and optional audio streaming.

The voice pipeline runs entirely through Home Assistant Assist — meaning you choose what
powers each step. Wake word detection runs locally on the device. STT, TTS and conversation
can be anything HA supports: fully local (Whisper + Piper, no cloud required), via Nabu Casa,
or AI-powered using OpenAI, Claude, OVOS, or any other conversation agent HA integrates with.

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
- **Linux Voice Assistant** — Voice satellite using [linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant) (ESPHome protocol). Includes local OWW wake word detection, timers, announcements and continue-conversation. Replaces the deprecated wyoming-satellite.
- **Touchscreen kiosk** — Weston Wayland compositor + Chromium in kiosk mode showing your HA dashboard
- **Face event bridge** — Monitors LVA states via HA API, writes `/tmp/mark2-face-event.json` for HUD overlays
- **mark2-status** — CLI command showing all service states, audio levels, HA connection and satellite state

### Optional modules (choose during install)

Modules are selected during install via a checklist. Defaults are marked with ✓.

| Module | Default | What it does |
|--------|:-------:|-------------|
| **homeassistant** | ✓ | Show your HA dashboard full-screen on the touchscreen |
| **leds** | ✓ | LED ring reacts to voice states — idle pulse, listening spin, speaking glow, error red |
| **face** | ✓ | Animated face overlay — reacts to voice, dances to music playback |
| **overlay** | ✓ | On-screen volume bar — appears on volume change, auto-hides after 3 seconds |
| **screensaver** | ✓ | Fullscreen clock + live weather pulled from HA, activates after 2 min idle |
| **mqtt-sensors** | ✓ | Publishes voice satellite state, audio playback, CPU/memory/disk/temp to HA via MQTT |
| **snapcast** |  | Multiroom audio — synced playback as a Snapcast endpoint |
| **airplay** |  | AirPlay 1 speaker — stream audio from iPhone, Mac or any AirPlay source |
| **mpd** |  | Local music player — integrates with Music Assistant in HA |
| **kdeconnect** |  | Android phone integration — notifications on screen, media control |
| **usb-audio** |  | USB audio fallback — uses a USB sound card if SJ201 fails at boot |

> Without the **homeassistant** module the touchscreen still shows the animated
> face and clock — Mark II works as a pure voice satellite without any dashboard.

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
3. Resume after reboot and install Linux Voice Assistant + kiosk
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

After installation Mark II announces itself on the network via **Zeroconf/mDNS**
using the ESPHome protocol. Home Assistant will discover it automatically and show
a notification to add it as an ESPHome device — no manual configuration needed.

If auto-discovery doesn't appear, add it manually:

1. Settings → Devices & Services → Add Integration
2. Search for **ESPHome**
3. Host: `<Mark II IP address>` — Port: `6053`

Mark II will appear as your **hostname** (e.g. `Nabu-1`) under ESPHome devices and
is immediately ready to use as an Assist satellite.

**Set the voice pipeline:**
In HA go to Settings → Voice Assistants → your Mark II device → select which
pipeline to use (e.g. "preferred", "Whisper+Piper local", "Claude", etc).

Say your wake word to test it.

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
nano ~/.config/systemd/user/lva.service
# Edit the --wake-model value
systemctl --user daemon-reload
systemctl --user restart lva
```

---

## Keeping the system updated

Run the update script to update everything at once:

```bash
cd ~/mark2-assist
./update.sh
```

This updates system packages, mark2-assist scripts, Linux Voice Assistant, and restarts all services. LVA setup only re-runs if new commits were pulled.

Optional flags:
- `--skip-apt` — skip system package update
- `--skip-lva` — skip Linux Voice Assistant update
- `--skip-restart` — skip service restart
- `--yes` — non-interactive, no confirmation prompt

### Manual component updates
```bash
sudo apt update && sudo apt upgrade
```

A **safe weekly update** runs automatically every Sunday at 03:00 via `/etc/cron.d/mark2-updates`.
It runs in two steps:
1. `apt upgrade` — system packages
2. `update.sh --skip-apt --yes` — mark2-assist scripts + LVA (git pull + setup if new commits)

The log is written to `/var/log/mark2-updates.log`.

After any kernel update the VocalFusion audio driver is automatically rebuilt
by `mark2-vocalfusion-watchdog.service` before the next boot — no manual action needed.

### mark2-assist scripts
```bash
cd ~/mark2-assist
git pull
```

Re-run the relevant setup script to apply changes:
```bash
./mark2-satellite-setup.sh   # Update kiosk/LVA configuration
./mark2-hardware-setup.sh    # Update hardware/driver configuration (rare)
```

Individual modules can be re-run at any time:
```bash
bash modules/leds.sh
bash modules/mqtt-sensors.sh
# etc.
```

### Linux Voice Assistant
```bash
cd ~/lva && git pull
rm -rf .venv && python3 script/setup
systemctl --user restart lva
```

---

## Uninstalling

```bash
cd ~/mark2-assist
./uninstall.sh
```

This removes:
- All mark2-assist systemd user services (LVA, kiosk, LEDs, face, overlay, MQTT, etc.)
- Installed packages (Chromium, weston, snapcast, shairport-sync, mpd, etc.)
- Configuration files in `~/.config/mark2/`, `~/.config/mark2-kiosk/`, etc.
- Weston/labwc autostart from `~/.bash_profile`
- Auto-login getty override in `/etc/systemd/system/getty@tty1.service.d/`

It does **not** remove:
- The VocalFusion kernel module (rebooting clears it from memory; `.ko` file stays)
- Boot overlay entries in `/boot/firmware/config.txt` (remove manually if needed)
- The `~/lva` directory
- The mark2-assist git repository itself

---

## Troubleshooting

**Touchscreen is black after boot**
```bash
grep vc4-kms-dsi-waveshare /boot/firmware/config.txt
# Should show: dtoverlay=vc4-kms-dsi-waveshare-800x480
# If missing: ./mark2-hardware-setup.sh && sudo reboot
```

**LVA not showing in HA**
```bash
systemctl --user status lva
journalctl --user -u lva -n 50
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

**Check all service statuses at a glance**
```bash
mark2-status
```

Or individually:
```bash
systemctl --user status lva sj201 mark2-volume-buttons mark2-face-events mark2-led-events
sudo systemctl status mark2-leds
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
| `/tmp/mark2-face-event.json` | Current voice satellite state written by face-event bridge for HUD and LED ring |
| `/tmp/mark2-leds.sock` | Unix socket — send state strings to control LED ring (e.g. `echo listen \| socat - UNIX-CONNECT:/tmp/mark2-leds.sock`) |

---

## Documentation

See the `docs/` directory for detailed technical documentation:

- [`docs/HISTORY.md`](docs/HISTORY.md) — History of Mark II, Mycroft, OVOS and HA Assist
- [`docs/INSTALL_SH.md`](docs/INSTALL_SH.md) — Install script architecture and flow
- [`docs/HARDWARE_SETUP.md`](docs/HARDWARE_SETUP.md) — Hardware setup technical deep dive
- [`docs/SATELLITE_SETUP.md`](docs/SATELLITE_SETUP.md) — Linux Voice Assistant setup deep dive
- [`docs/MODULES.md`](docs/MODULES.md) — All optional modules documented in detail
- [`docs/HA_INTEGRATION.md`](docs/HA_INTEGRATION.md) — HA companion integration spec
- [`docs/HA_SETUP.md`](docs/HA_SETUP.md) — HA user, trusted network auto-login, and dashboard setup
- [`docs/mark2-dashboard.yaml`](docs/mark2-dashboard.yaml) — Ready-to-paste Mark II dashboard YAML

**Issues** are tracked on GitHub: https://github.com/andlo/mark2-assist/issues

---

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.

This project uses code adapted from [OpenVoiceOS/ovos-installer](https://github.com/OpenVoiceOS/ovos-installer)
(Apache 2.0) for the SJ201 hardware setup routines.
