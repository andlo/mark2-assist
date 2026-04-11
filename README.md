# Mycroft Mark II Setup Scripts

Complete setup suite for repurposing a Mycroft Mark II as a:
- Wyoming Voice Satellite for Home Assistant
- Home Assistant kiosk display (touchscreen)
- Multiroom audio endpoint (Snapcast + AirPlay)
- Full media player (MPD + Music Assistant)

Built for **Raspberry Pi OS Trixie (Debian 13)** — the current latest image.
Converted from the OpenVoiceOS ovos-installer Ansible roles and extended with
additional integrations.

---

## Hardware

The Mycroft Mark II contains:
- Raspberry Pi CM4
- SJ201 daughterboard with XMOS XVF-3510 audio frontend
- 6-mic array + stereo speakers + LED ring
- 4.3" DSI touchscreen
- GPIO buttons

---

## Prerequisites

1. Flash **Raspberry Pi OS Trixie (64-bit)** to a USB 3.0 stick
   - Use Raspberry Pi Imager
   - Plug USB into the **top-left blue USB 3.0 port** on Mark II
2. Enable SSH during flashing (Raspberry Pi Imager > Advanced Options)
3. Boot Mark II and SSH in:
   ```bash
   ssh pi@<mark2-ip-address>
   ```
4. Clone or copy this folder to the Mark II:
   ```bash
   scp -r mark2-setup/ pi@<mark2-ip>:~/
   ```

---

## Installation Order

### Step 1 — Hardware Drivers (required)

```bash
chmod +x ~/mark2-setup/*.sh
~/mark2-setup/mark2-hardware-setup.sh
sudo reboot
```

**What it does:**
- Installs kernel headers and build tools
- Clones and builds VocalFusion sound card driver (SJ201/XMOS XVF-3510)
- Copies DTBO overlays to `/boot/firmware/overlays`
- Configures `config.txt` (uart, sj201, buttons, touchscreen)
- Creates Python venv for SJ201 firmware flash
- Downloads SJ201 firmware and init scripts
- Creates and enables `sj201.service`
- Configures WirePlumber audio profile

**Reboot is required** before running further scripts.

---

### Step 2 — Wyoming Satellite + Kiosk (required for voice + display)

```bash
~/mark2-setup/mark2-satellite-setup.sh
```

**Prompts for:**
- Home Assistant URL (e.g. `http://192.168.1.100:8123`)

**What it does:**
- Installs Wyoming Satellite + openWakeWord
- Auto-detects SJ201 audio device
- Creates `wyoming-satellite.service` + `wyoming-openwakeword.service`
- Installs Chromium in kiosk mode showing Home Assistant
- Configures labwc autostart (Trixie Wayland compositor)
- Disables screen blanking
- Installs MPV + PipeWire for media playback
- Enables auto-login to graphical session

**After running — add Wyoming integration in Home Assistant:**
```
Settings > Devices & Services > Add Integration > Wyoming Protocol
Host: <Mark II IP address>
Port: 10700
```

Default wake word: **"ok nabu"**

---

### Step 3 — Extra Audio Services (optional)

```bash
~/mark2-setup/mark2-extras-setup.sh
```

Each module is prompted individually:

| Module | What it does |
|--------|-------------|
| **Snapcast client** | Synchronized multiroom audio endpoint. Requires a Snapcast server on your network. Mark II appears as media player in HA Snapcast integration. |
| **AirPlay receiver** | Shairport-sync. Mark II appears as AirPlay speaker. Works on Trixie with minor caveats (AirPlay 1 only). |
| **Screensaver** | Fullscreen clock + weather from HA. Activates after 2 min idle, touch to dismiss. Requires HA long-lived access token. |

---

### Step 4 — Advanced Features (optional)

```bash
~/mark2-setup/mark2-advanced-setup.sh
```

Each module is prompted individually:

| Module | What it does |
|--------|-------------|
| **LED ring control** | SJ201 LED ring shows Wyoming status. Idle=off, wake word=pulse blue, listening=solid blue, thinking=spin cyan, speaking=green, error=red. |
| **Kernel watchdog** | Auto-rebuilds VocalFusion driver after kernel updates. Weekly safe apt upgrade cron job. |
| **KDE Connect** | Pair Android phone with Mark II. Share notifications, control media, sync clipboard. |
| **MPD** | Local music player. Integrates with HA, Music Assistant, and Snapcast. HTTP stream on port 8000. |
| **USB audio fallback** | Auto-switches to USB DAC/speaker if SJ201 fails at boot. Includes `mark2-audio-switch` command. |
| **Volume overlay** | Transparent on-screen overlay showing volume level and Wyoming status. Auto-hides after 3 seconds. |

---

### Final reboot

```bash
sudo reboot
```

---

## Music Assistant

Music Assistant runs as a **Home Assistant addon** (not on Mark II).

Install in HA:
```
Settings > Add-ons > Music Assistant
```

Mark II will appear as a player target via:
- **MPD** at `<mark2-ip>:6600` (if installed in step 4)
- **Snapcast** client (if installed in step 3)
- **Wyoming** media player (HA native)

Docs: https://music-assistant.io/integration/ha/

---

## Useful Commands

```bash
# Check all Mark II services
systemctl --user status wyoming-satellite wyoming-openwakeword sj201

# View Wyoming logs
journalctl --user -u wyoming-satellite -f

# Test LED ring (if LED module installed)
echo "listen" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
echo "speak"  | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
echo "idle"   | socat - UNIX-CONNECT:/tmp/mark2-leds.sock

# Switch audio output manually (if USB fallback installed)
mark2-audio-switch list
mark2-audio-switch sj201
mark2-audio-switch usb

# Show overlay (if volume overlay installed)
mark2-overlay volume 75
mark2-overlay status "Hello!"

# MPD control (if MPD installed)
mpc status
mpc volume 80
mpc play

# Manual VocalFusion rebuild (after kernel update)
sudo ~/.config/mark2/rebuild-vocalfusion.sh
```

---

## Troubleshooting

**No sound after reboot:**
```bash
systemctl --user status sj201.service
journalctl --user -u sj201 --no-pager
aplay -l
```

**Wyoming not discovered in HA:**
- Check Mark II IP: `hostname -I`
- Verify service is running: `systemctl --user status wyoming-satellite`
- Check HA firewall allows port 10700

**Touchscreen shows blank/black:**
```bash
# Check Chromium kiosk service
systemctl --user status ha-kiosk
journalctl --user -u ha-kiosk -f
```

**Kernel update broke audio:**
```bash
# Run manually
sudo ~/.config/mark2/rebuild-vocalfusion.sh
sudo reboot
```

**AirPlay not visible:**
```bash
systemctl --user status shairport-sync
# Check avahi is running
sudo systemctl status avahi-daemon
```

---

## Script Sources

- Hardware drivers: Converted from [OpenVoiceOS ovos-installer](https://github.com/OpenVoiceOS/ovos-installer) Ansible roles
- Wyoming Satellite: [rhasspy/wyoming-satellite](https://github.com/rhasspy/wyoming-satellite)
- openWakeWord: [rhasspy/wyoming-openwakeword](https://github.com/rhasspy/wyoming-openwakeword)
- VocalFusion driver: [OpenVoiceOS/VocalFusionDriver](https://github.com/OpenVoiceOS/VocalFusionDriver)
- Snapcast: [badaix/snapcast](https://github.com/badaix/snapcast)
- AirPlay: [mikebrady/shairport-sync](https://github.com/mikebrady/shairport-sync)

---

## Notes

- All scripts are **idempotent** — safe to run multiple times
- Scripts tested against Raspberry Pi OS Trixie (Debian 13, October 2025+)
- Bookworm (Debian 12) is also supported with minor differences
- These scripts are **not** affiliated with Mycroft AI, OpenVoiceOS, or Anthropic
- Always verify scripts before running on production hardware
