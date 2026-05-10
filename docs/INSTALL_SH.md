# install.sh — Architecture and Flow

`install.sh` is the main entry point. It runs the two installation
steps with automatic reboot handling.

---

## Design principles

1. **Zero prompts** — No questions during install. All configuration
   is done in Home Assistant UI after the device is up.

2. **Resume after reboot** — Hardware setup requires a reboot. A hook
   in `~/.bash_profile` reminds the user to re-run `./install.sh`.
   Running it again auto-detects the resume state.

3. **Idempotent steps** — Each step is guarded by `progress_is_done()`.
   Re-running the installer skips completed steps safely.

---

## Flow

```
./install.sh
  │
  ├── Step 1: mark2-hardware-setup.sh
  │     SJ201 kernel driver, DTBO overlays, Python venv,
  │     setup_mclk/setup_bclk binaries, WirePlumber profile
  │     → REBOOT REQUIRED
  │
  └── Step 2: mark2-satellite-setup.sh  (after reboot)
        Linux Voice Assistant, mark2-audio-init.service,
        face overlay, Weston kiosk, volume buttons, PipeWire config
        → REBOOT TO ACTIVATE
```

---

## Progress tracking

Progress is stored in `~/.config/mark2/install-progress` (one file per step).

```bash
progress_set "hardware" "done"   # mark step done
progress_is_done "hardware"      # returns 0 if done
progress_get "hardware"          # returns: done / failed / pending
```

Re-running `install.sh` after a partial failure resumes from the
last incomplete step.

---

## Optional modules

Optional modules (Snapcast, AirPlay, MPD, KDE Connect) are installed
separately and will eventually be managed via the HA UI.

See [MODULES.md](MODULES.md) and [issue #31](https://github.com/andlo/mark2-assist/issues/31).

Manual install:
```bash
bash modules/snapcast.sh
bash modules/airplay.sh
# etc.
```

---

## Configuration after install

`~/.config/mark2/config` — optional overrides:

```bash
# HA URL if homeassistant.local doesn't resolve via mDNS
HA_URL=http://192.168.1.100:8123

# HA long-lived token (for face event bridge + screensaver sync)
HA_TOKEN=eyJ...

# Screensaver timeout in seconds (0 = never)
SCREEN_BLANK_SECONDS=300
```
