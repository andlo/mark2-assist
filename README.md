# Mycroft Mark II Assist

Complete setup suite for repurposing a Mycroft Mark II as a:
- Wyoming Voice Satellite for Home Assistant
- Home Assistant kiosk display (touchscreen)
- Multiroom audio endpoint (Snapcast + AirPlay)
- Full media player (MPD + Music Assistant)

Built for **Raspberry Pi OS Lite Trixie (Debian 13)** — the current latest image.
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

1. Flash **Raspberry Pi OS Lite Trixie (64-bit)** to a USB 3.0 stick
   - Use Raspberry Pi Imager
   - Select: Raspberry Pi OS Lite (64-bit)
   - Plug USB into the **top-left blue USB 3.0 port** on Mark II
2. Enable SSH during flashing (Raspberry Pi Imager > Advanced Options)
3. Boot Mark II and SSH in:
   ```bash
   ssh pi@<mark2-ip-address>
   ```
4. Clone this repo to the Mark II:
   ```bash
   git clone https://github.com/andlo/mark2-assist.git
   cd mark2-assist
   ```

---

## Quick Install

Run the installer for a guided setup:

```bash
./install.sh
```

The installer walks through all steps in order and prompts for each optional module.

To skip hardware setup (already done + rebooted):
```bash
./install.sh --skip-hardware
```

---

## Manual Installation

### Step 1 — Hardware Drivers (required)

```bash
./mark2-hardware-setup.sh
sudo reboot
```

**What it does:**
- Installs kernel headers and build tools
- Clones and builds VocalFusion sound card driver (SJ201/XMOS XVF-3510)
- Copies DTBO overlays to `/boot/firmware/overlays`
- Configures `config.txt` (uart, sj201, buttons, touchscreen)
- Creates Python venv for SJ201 firmware flash
- Installs SJ201 firmware and init scripts from `assets/`
- Creates and enables `sj201.service`
- Configures WirePlumber audio profile
- Installs kernel watchdog (auto-rebuilds VocalFusion after kernel updates)

**Reboot is required** before continuing.

---

### Step 2 — Wyoming Satellite + Kiosk (required for voice + display)

```bash
./mark2-satellite-setup.sh
```

**Prompts for:**
- Home Assistant URL (e.g. `http://192.168.1.100:8123`)

**What it does:**
- Installs Wyoming Satellite + openWakeWord
- Auto-detects SJ201 audio device
- Creates `wyoming-satellite.service` + `wyoming-openwakeword.service`
- Installs minimal Wayland kiosk stack (labwc, seatd, Chromium)
- Opens Home Assistant in fullscreen kiosk mode
- Configures PipeWire for audio playback
- Enables auto-login to graphical session

**After running — add Wyoming integration in Home Assistant:**
```
Settings > Devices & Services > Add Integration > Wyoming Protocol
Host: <Mark II IP address>
Port: 10700
```

Default wake word: **"ok nabu"**

---

### Step 3 — Optional Modules

Each module is a standalone script in `modules/` and can be run individually:

```bash
bash modules/<module>.sh
```

| Module | Script | What it does |
|--------|--------|-------------|
| **Snapcast client** | `modules/snapcast.sh` | Synchronized multiroom audio. Mark II appears as media player in HA Snapcast integration. |
| **AirPlay receiver** | `modules/airplay.sh` | Shairport-sync. Mark II appears as AirPlay speaker (AirPlay 1). |
| **Screensaver** | `modules/screensaver.sh` | Fullscreen clock + weather from HA. Activates after 2 min idle, touch to dismiss. |
| **LED ring control** | `modules/leds.sh` | SJ201 LED ring shows Wyoming status. Idle=off, wake=pulse blue, listen=solid blue, think=spin cyan, speak=green, error=red. |
| **MPD** | `modules/mpd.sh` | Local music player. Integrates with HA, Music Assistant, and Snapcast. HTTP stream on port 8000. |
| **KDE Connect** | `modules/kdeconnect.sh` | Pair Android phone with Mark II. Share notifications, control media, sync clipboard. |
| **USB audio fallback** | `modules/usb-audio.sh` | Auto-switches to USB DAC/speaker if SJ201 fails at boot. Includes `mark2-audio-switch` command. |
| **Volume overlay** | `modules/overlay.sh` | Transparent on-screen overlay showing volume and Wyoming status. Auto-hides after 3 seconds. |

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
- **MPD** at `<mark2-ip>:6600` (if installed)
- **Snapcast** client (if installed)
- **Wyoming** media player (HA native)

Docs: https://music-assistant.io/integration/ha/
---

## Fan Control

The Mark II has a PWM-controlled fan on the SJ201 board.
**Fan control is fully automatic — no extra configuration needed.**

The `sj201-rev10-pwm-fan-overlay.dtbo` file (installed by `mark2-hardware-setup.sh`)
configures the Linux kernel's thermal management to control the fan via hardware PWM on GPIO 13.

| CPU Temperature | Fan state |
|----------------|-----------|
| Below 40°C | Off |
| 40°C | Low speed |
| 50°C | Medium speed |
| 55°C | High speed |
| 60°C+ | Full speed |

Temperature thresholds can be tuned via kernel command line parameters
(see `sj201-rev10-pwm-fan-overlay.dts` in the VocalFusion repo for parameter names).

**Note:** The PWM fan overlay is only present on Mark II Rev10 (production units).
Early Dev Kit units (Rev6) do not have a fan and the overlay will simply have no effect.

To verify the fan is working:
```bash
# Check thermal zones
cat /sys/class/thermal/thermal_zone0/temp

# Check fan cooling state (0=off, 4=full)
cat /sys/class/thermal/cooling_device*/cur_state 2>/dev/null || echo "Fan device not found"
```



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
systemctl --user status ha-kiosk
journalctl --user -u ha-kiosk -f
```

**Kernel update broke audio:**
```bash
sudo ~/.config/mark2/rebuild-vocalfusion.sh
sudo reboot
```

**AirPlay not visible:**
```bash
systemctl --user status shairport-sync
sudo systemctl status avahi-daemon
```

---

## Repository Structure

```
install.sh                  # Guided installer (runs all steps in order)
mark2-hardware-setup.sh     # Hardware drivers + kernel watchdog
mark2-satellite-setup.sh    # Wyoming satellite + Wayland kiosk
modules/                    # Optional feature modules (each standalone)
    snapcast.sh
    airplay.sh
    screensaver.sh
    leds.sh
    mpd.sh
    kdeconnect.sh
    usb-audio.sh
    overlay.sh
lib/
    common.sh               # Shared functions sourced by all scripts
assets/                     # Vendored firmware and scripts
    xvf3510-flash
    app_xvf3510_int_spi_boot_v4_2_0.bin
    init_tas5806.py
templates/                  # HTML templates for kiosk UI
    screensaver.html
    overlay.html
```

---

## Sources

- Hardware drivers: Converted from [OpenVoiceOS ovos-installer](https://github.com/OpenVoiceOS/ovos-installer) Ansible roles
- Wyoming Satellite: [rhasspy/wyoming-satellite](https://github.com/rhasspy/wyoming-satellite)
- openWakeWord: [rhasspy/wyoming-openwakeword](https://github.com/rhasspy/wyoming-openwakeword)
- VocalFusion driver: [OpenVoiceOS/VocalFusionDriver](https://github.com/OpenVoiceOS/VocalFusionDriver)
- Snapcast: [badaix/snapcast](https://github.com/badaix/snapcast)
- AirPlay: [mikebrady/shairport-sync](https://github.com/mikebrady/shairport-sync)

---

## Notes

- All scripts are **idempotent** — safe to run multiple times
- Tested against Raspberry Pi OS Lite Trixie (Debian 13, October 2025+)
- Bookworm (Debian 12) is also supported with minor differences
- Not affiliated with Mycroft AI, OpenVoiceOS, or Anthropic
