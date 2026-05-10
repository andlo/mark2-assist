# Optional Modules

Optional modules extend the Mark II with additional audio capabilities.

## Status (May 2026)

Module management via the HA UI is planned as `mark2-manager`
([issue #31](https://github.com/andlo/mark2-assist/issues/31)).
When implemented, modules will appear as ESPHome switch entities in HA
and install automatically when toggled on.

**Until then:** install manually from the `modules/` directory.

---

## Available modules

### snapcast.sh — Synchronized multiroom audio
Turns the Mark II into a [Snapcast](https://github.com/badaix/snapcast) client,
synchronized with other rooms. Integrates with Music Assistant in Home Assistant.

```bash
bash modules/snapcast.sh
# Prompts for Snapcast server host/IP
```

### airplay.sh — AirPlay 1 speaker
Streams audio from iPhone, Mac or any AirPlay source.

```bash
bash modules/airplay.sh
```

### mpd.sh — Local music player
[MPD](https://www.musicpd.org/) for local music playback.
Integrates with Music Assistant and media player card in HA.

```bash
bash modules/mpd.sh
```

### kdeconnect.sh — Android integration
[KDE Connect](https://kdeconnect.kde.org/) for Android notifications
and media control from your phone.

```bash
bash modules/kdeconnect.sh
```

### usb-audio.sh — USB audio fallback
Configures a USB sound card as fallback if SJ201 fails at boot.

```bash
bash modules/usb-audio.sh
```

---

## Deprecated modules

These modules are no longer called by `install.sh`. Their functionality
is now built into the base installation.

| Module | Replaced by |
|--------|------------|
| `ui.sh` | `mark2-satellite-setup.sh` (face overlay, volume buttons, LEDs) |
| `face.sh` | `templates/face.html` + `lib/kiosk.sh` |
| `screensaver.sh` | `templates/face.html` (built-in screensaver timer) |
| `homeassistant.sh` | `lib/kiosk.sh` (opens HA directly) |
| `mqtt-sensors.sh` | Planned: ESPHome entities via mark2-manager (#31) |

---

## Writing a new module

Each module in `modules/` is a standalone bash script.
It must source `lib/common.sh` and be idempotent (safe to re-run).

```bash
#!/bin/bash
source "$(dirname "$0")/../lib/common.sh"
check_not_root
setup_paths
# ... install steps ...
```
