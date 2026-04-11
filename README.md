# Mycroft Mark II Assist

Repurpose your Mycroft Mark II as a smart Home Assistant satellite — with voice control, animated kiosk display, multiroom audio, and MQTT sensor integration.

Built for **Raspberry Pi OS Lite Trixie (Debian 13)**.

---

## What it does

- **Wyoming voice satellite** — wake word detection, speech-to-text, TTS response via Home Assistant Assist
- **Animated kiosk display** — touchscreen shows HA dashboard with an animated face that reacts to voice events, music playback with cover art, and a content display API for showing images and text from HA
- **Multiroom audio** — Snapcast client and/or AirPlay receiver
- **Local music player** — MPD with Music Assistant and HTTP stream support
- **MQTT sensors** — publishes Wyoming state, MPD state/track, CPU temp, and more to HA via auto-discovery
- **LED ring** — SJ201 LED ring follows voice assistant state

---

## Hardware

The Mycroft Mark II contains:
- Raspberry Pi CM4
- SJ201 daughterboard with XMOS XVF-3510 audio frontend (6-mic array, stereo speakers, LED ring)
- 4.3" DSI touchscreen
- GPIO buttons

---

## Prerequisites

1. Flash **Raspberry Pi OS Lite Trixie (64-bit)** to a USB 3.0 stick
   - Use Raspberry Pi Imager — select Raspberry Pi OS Lite (64-bit)
   - Enable SSH and set username/password in Advanced Options
   - Plug USB into the **top-left blue USB 3.0 port** on Mark II
2. Boot Mark II and SSH in:
   ```bash
   ssh pi@<mark2-ip-address>
   ```
3. Clone this repo:
   ```bash
   git clone https://github.com/andlo/mark2-assist.git
   cd mark2-assist
   ```

---

## Installation

```bash
./install.sh
```

### Installer — welcome screen

```
    __  ___           __      ________     ___              _      __
   /  |/  /___ ______/ /__   /  _/  _/    /   |  __________(_)____/ /_
  / /|_/ / __ `/ ___/ //_/   / / / /     / /| | / ___/ ___/ / ___/ __/
 / /  / / /_/ / /  / ,<    _/ /_/ /     / ___ |(__  |__  ) (__  ) /_
/_/  /_/\__,_/_/  /_/|_|  /___/___/    /_/  |_/____/____/_/____/\__/

  Welcome to the Mark II Assist installer
  github.com/andlo/mark2-assist
```

### Installer — yes/no dialogs (whiptail)

```
 ┌────────────────────────────────────────────────────┐
 │                  Mark II Assist                    │
 │                                                    │
 │         Ready to begin installation?               │
 │                                                    │
 │               <Yes>          <No>                  │
 └────────────────────────────────────────────────────┘
```

### Installer — input dialogs

```
 ┌────────────────────────────────────────────────────┐
 │                  Mark II Assist                    │
 │                                                    │
 │  Home Assistant URL                                │
 │                                                    │
 │  ┌──────────────────────────────────────────────┐  │
 │  │ http://192.168.1.100:8123                    │  │
 │  └──────────────────────────────────────────────┘  │
 │                                                    │
 │               <Ok>           <Cancel>              │
 └────────────────────────────────────────────────────┘
```

### Installer — module selection menu

```
 ┌────────────────────────────────────────────────────────────────┐
 │                      Mark II Assist                            │
 │  Select modules to install:                                    │
 │  (Space to toggle, Enter to confirm)                           │
 │                                                                │
 │  [*] snapcast    Snapcast — multiroom audio                    │
 │  [ ] airplay     AirPlay — Mark II as AirPlay speaker          │
 │  [*] screensaver Screensaver — clock + weather display         │
 │  [*] leds        LED ring — visual Wyoming feedback            │
 │  [ ] mpd         MPD — local music player                      │
 │  [ ] kdeconnect  KDE Connect — Android phone integration       │
 │  [ ] usb-audio   USB audio — fallback if SJ201 fails           │
 │  [*] overlay     Volume overlay — on-screen status             │
 │  [*] face        Animated face — reacts to Wyoming events      │
 │  [ ] mqtt-sensors MQTT sensors — publish status to HA          │
 │                                                                │
 │                   <Ok>              <Cancel>                   │
 └────────────────────────────────────────────────────────────────┘
```

### Installer — progress tracking

```
  Installation progress:
    ✓ hardware
    ✓ satellite
    ✓ screensaver
    ✓ leds
    - airplay       (skipped)
    ✗ mpd           (failed)
    · kdeconnect    (pending)
```

### After reboot — resume reminder

```
╔══════════════════════════════════════════╗
║   Mark II installation paused            ║
║                                          ║
║   Hardware setup complete ✓              ║
║   Reboot done ✓                          ║
║                                          ║
║   Run to continue:                       ║
║     ./mark2-assist/install.sh            ║
╚══════════════════════════════════════════╝
```

The installer is fully guided:

1. Asks for Home Assistant URL (saved and reused by all modules)
2. Runs hardware setup and **reboots automatically**
3. On next SSH login a reminder appears — run `./install.sh` to continue
4. Installs Wyoming satellite + Wayland kiosk
5. Shows a **module selection menu** (whiptail checklist) with sensible defaults pre-selected
6. Prompts for reboot when done

All configuration is saved to `~/.config/mark2/config` and reused — you only enter your HA URL, token, and MQTT credentials once.

Progress is tracked in `~/.config/mark2/install-progress` so re-running the installer skips already-completed steps.

### Running individual modules later

```bash
bash modules/snapcast.sh
bash modules/mqtt-sensors.sh
# etc.
```

---

## Manual Installation

### Step 1 — Hardware Drivers (required)

```bash
./mark2-hardware-setup.sh
sudo reboot
```

Installs SJ201 audio drivers, VocalFusion kernel module, boot overlays, SPI/I2C, WirePlumber config, and a kernel watchdog that auto-rebuilds the driver after kernel updates.

### Step 2 — Wyoming Satellite + Kiosk (required)

```bash
./mark2-satellite-setup.sh
```

Installs Wyoming satellite, openWakeWord, Chromium kiosk (served from `~/.config/mark2-kiosk/kiosk.html`), labwc Wayland compositor, PipeWire, and configures getty auto-login.

### Step 3 — Optional Modules

| Module | Script | What it does |
|--------|--------|-------------|
| **Snapcast** | `modules/snapcast.sh` | Synchronized multiroom audio endpoint |
| **AirPlay** | `modules/airplay.sh` | Mark II as AirPlay speaker (AirPlay 1) |
| **Screensaver** | `modules/screensaver.sh` | Fullscreen clock + weather from HA, activates after 2 min idle |
| **LED ring** | `modules/leds.sh` | SJ201 LED ring follows Wyoming state |
| **MPD** | `modules/mpd.sh` | Local music player, HTTP stream on port 8000 |
| **KDE Connect** | `modules/kdeconnect.sh` | Android phone integration |
| **USB audio fallback** | `modules/usb-audio.sh` | Auto-switch to USB DAC if SJ201 fails |
| **Volume overlay** | `modules/overlay.sh` | On-screen volume indicator |
| **Animated face** | `modules/face.sh` | Animated robot face reacting to voice events and music |
| **MQTT sensors** | `modules/mqtt-sensors.sh` | Publish device status to HA via MQTT auto-discovery |

---

## Kiosk Display

The touchscreen runs a single Chromium window (`kiosk.html`) with layered content:

### Normal — Home Assistant full screen

```
┌─────────────────────────────────────────┐
│                                         │
│         Home Assistant Dashboard        │
│                                         │
│   ┌──────────┐  ┌──────────┐           │
│   │  Lights  │  │  Climate │           │
│   └──────────┘  └──────────┘           │
│                                         │
│   ┌──────────┐  ┌──────────┐           │
│   │  Media   │  │  Energy  │           │
│   └──────────┘  └──────────┘           │
│                                         │
└─────────────────────────────────────────┘
```

### Voice active — animated face zooms from corner

```
┌─────────────────────────────────────────┐
│                                         │
│          ● Listening...                 │  ← status pill
│                                         │
│   ╭─────────────────────────────────╮   │
│   │                                 │   │
│   │         (  ◉      ◉  )         │   │  ← face full screen
│   │              ╰──╯               │   │     zoomed from corner
│   │                                 │   │
│   ╰─────────────────────────────────╯   │
│                                         │
└─────────────────────────────────────────┘
```

### Music playing — cover art full screen, face reacts in corner

```
┌─────────────────────────────────────────┐
│                                         │
│         ░░░░░░░░░░░░░░░░░░░░░           │
│         ░░                 ░░           │
│         ░░   [cover art]   ░░           │
│         ░░                 ░░           │
│         ░░░░░░░░░░░░░░░░░░░░░           │
│                                         │
│  Wish You Were Here                     │  ← track info
│  Pink Floyd                             │
│  ▁▃▅▇▅▃▁▂▄▆▄▂▁▃▅▃▁  ╭──────╮           │  ← viz bars + face
│                      │ ◉  ◉ │           │     (mouth moves
│                      │  ~~  │           │      with music)
│                      ╰──────╯           │
└─────────────────────────────────────────┘
```

### Wyoming activates during music — face takes over

```
┌─────────────────────────────────────────┐
│                                         │
│   ░ ░ ░ [cover art dimmed] ░ ░ ░       │
│                                         │
│   ╭─────────────────────────────────╮   │
│   │                                 │   │
│   │         (  ◉      ◉  )         │   │  ← face full screen
│   │              ╰──╯               │   │     over dimmed cover
│   │             · · ·               │   │     (thinking dots)
│   │                                 │   │
│   ╰─────────────────────────────────╯   │
└─────────────────────────────────────────┘
```

### Volume changed — bar pops up briefly

```
┌─────────────────────────────────────────┐
│                                         │
│         Home Assistant Dashboard        │
│                                         │
│                                         │
│         ┌─────────────────────┐         │
│         │ 🔊 ████████░░░  72% │         │  ← auto-hides 3s
│         └─────────────────────┘         │
│                                         │
└─────────────────────────────────────────┘
```

### Screensaver — after 2 min idle

```
┌─────────────────────────────────────────┐
│                                         │
│                                         │
│               22:47:03                  │
│         SATURDAY · 11 APRIL 2026        │
│                                         │
│          ☀️  18°C  Sunny                │
│      Humidity: 45%  ·  Wind: 3 m/s     │
│                                         │
│                                         │
└─────────────────────────────────────────┘
```
*Touch screen to return to Home Assistant.*

---

## LED Ring States

When the LED module is installed, the SJ201 ring follows Wyoming events:

| State | LED behaviour |
|-------|--------------|
| Idle | Off |
| Wake word | Pulsing blue |
| Listening | Solid blue |
| Thinking | Spinning cyan |
| Speaking | Solid green |
| Error | Flashing red |

---

## MQTT Sensors

When the `mqtt-sensors` module is installed, these sensors appear automatically in HA:

| Sensor | Entity ID example | Description |
|--------|-------------------|-------------|
| Wyoming state | `sensor.nabu_1_wyoming_state` | idle / listening / speaking / thinking |
| MPD state | `sensor.nabu_1_mpd_state` | playing / paused / stopped |
| MPD track | `sensor.nabu_1_mpd_track` | Current track title |
| MPD artist | `sensor.nabu_1_mpd_artist` | Current artist |
| MPD volume | `sensor.nabu_1_mpd_volume` | 0–100 |
| CPU temperature | `sensor.nabu_1_cpu_temp` | °C |
| CPU usage | `sensor.nabu_1_cpu_usage` | % |
| Memory usage | `sensor.nabu_1_memory_usage` | % |
| Disk usage | `sensor.nabu_1_disk_usage` | % |

Entity IDs are based on the device hostname, so multiple Mark II devices each get unique sensors.

Requires: MQTT broker (Mosquitto HA addon) with MQTT integration enabled in HA.

---

## After Installation

Add Wyoming integration in Home Assistant:
```
Settings > Devices & Services > Add Integration > Wyoming Protocol
Host: <Mark II IP>   Port: 10700
```

Default wake word: **"ok nabu"**

---

## Music Assistant

Runs as a HA addon (not on Mark II itself):
```
Settings > Add-ons > Music Assistant
```

Mark II appears as a player target via MPD (port 6600), Snapcast, or Wyoming media player.

---

## Useful Commands

```bash
# Service status
systemctl --user status wyoming-satellite wyoming-openwakeword sj201

# Logs
journalctl --user -u wyoming-satellite -f
cat ~/.config/mark2/install.log

# LED ring test
echo "listen" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
echo "speak"  | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
echo "idle"   | socat - UNIX-CONNECT:/tmp/mark2-leds.sock

# Audio
mark2-audio-switch list
mark2-overlay volume 75
mpc status

# Show content on kiosk screen
echo '{"action":"show","title":"Hello","text":"World","duration":10}' \
  > /tmp/mark2-content.json

# Kernel driver rebuild
sudo ~/.config/mark2/rebuild-vocalfusion.sh
```

---

## Troubleshooting

**No sound after reboot:**
```bash
systemctl --user status sj201.service
journalctl --user -u sj201 --no-pager
aplay -l
ls /dev/spidev*   # should show /dev/spidev0.0
```

**Wyoming not discovered in HA:**
```bash
hostname -I
systemctl --user status wyoming-satellite
# Check HA firewall allows port 10700
```

**Touchscreen blank:**
```bash
systemctl --user status ha-kiosk
journalctl --user -u ha-kiosk -f
```

**Kernel update broke audio:**
```bash
sudo ~/.config/mark2/rebuild-vocalfusion.sh && sudo reboot
```

**AirPlay not visible:**
```bash
systemctl --user status shairport-sync
sudo systemctl status avahi-daemon
```

**Install failed:**
```bash
cat ~/.config/mark2/install.log
```

---

## Repository Structure

```
install.sh                    # Guided installer (auto-resume, progress tracking)
mark2-hardware-setup.sh       # SJ201 drivers, SPI/I2C, kernel watchdog
mark2-satellite-setup.sh      # Wyoming satellite, Wayland kiosk, PipeWire
modules/
    snapcast.sh               # Snapcast multiroom audio client
    airplay.sh                # AirPlay receiver (shairport-sync)
    screensaver.sh            # Clock + weather screensaver
    leds.sh                   # SJ201 LED ring control
    mpd.sh                    # MPD music player
    kdeconnect.sh             # KDE Connect phone integration
    usb-audio.sh              # USB audio fallback
    overlay.sh                # Volume overlay
    face.sh                   # Animated face display
    mqtt-sensors.sh           # MQTT sensor bridge
lib/
    common.sh                 # Shared functions, config, progress tracking
    mpd-watcher.py            # Polls MPD, writes cover art + track info
    mqtt-bridge.py            # MQTT auto-discovery sensor publisher
assets/
    xvf3510-flash             # SPI flash tool (vendored)
    app_xvf3510_int_spi_boot_v4_2_0.bin  # XVF3510 firmware (vendored)
    init_tas5806.py           # TAS5806 amplifier init (vendored)
templates/
    kiosk.html                # Main kiosk page (HA iframe + HUD + face)
    screensaver.html          # Clock + weather screensaver
    overlay.html              # Volume overlay (standalone)
    face.html                 # Animated face (standalone)
docs/
    HA_INTEGRATION.md         # Spec for companion HA integration
```

---

## Sources

- Hardware drivers: [OpenVoiceOS ovos-installer](https://github.com/OpenVoiceOS/ovos-installer) Ansible roles
- Wyoming Satellite: [rhasspy/wyoming-satellite](https://github.com/rhasspy/wyoming-satellite)
- openWakeWord: [rhasspy/wyoming-openwakeword](https://github.com/rhasspy/wyoming-openwakeword)
- VocalFusion driver: [OpenVoiceOS/VocalFusionDriver](https://github.com/OpenVoiceOS/VocalFusionDriver)
- Snapcast: [badaix/snapcast](https://github.com/badaix/snapcast)
- AirPlay: [mikebrady/shairport-sync](https://github.com/mikebrady/shairport-sync)

---

## Notes

- All scripts are idempotent — safe to run multiple times
- Tested against Raspberry Pi OS Lite Trixie (Debian 13, October 2025+)
- Bookworm (Debian 12) supported with minor differences
- Not affiliated with Mycroft AI, OpenVoiceOS, or Anthropic
