# Optional Modules — Technical Documentation

Each module in `modules/` is a standalone bash script that can be run independently
or as part of the main installation. All modules source `lib/common.sh`.

---

## leds.sh — SJ201 LED Ring

The SJ201 carries a ring of 12 APA102 LEDs (addressable RGB) connected via I2C.
This module installs a Python daemon that listens for state change commands on a
Unix socket and animates the LED ring accordingly.

### Architecture

```
wyoming-satellite → mark2-led-events.service → /tmp/mark2-leds.sock → mark2-leds.service → hardware
```

**mark2-leds.service** runs `led_control.py`:
- Opens a Unix socket at `/tmp/mark2-leds.sock`
- Accepts state strings: `idle`, `wake`, `listen`, `think`, `speak`, `error`, `mute`, `volume`
- Animates LEDs using `smbus2` I2C writes to address `0x04` (SJ201 LED controller)

**mark2-led-events.service** runs `led_event_handler.py`:
- Reads Wyoming satellite events from stdin (piped from wyoming-satellite `--event-uri`)
- Maps Wyoming event types to LED states
- Sends state strings to the LED socket

**wyoming-satellite.service** is patched to add:
```
--event-uri 'tcp://127.0.0.1:10500'
```
This makes Wyoming stream events to the LED event bridge.

### LED states and animations

| State | Animation | Color | Description |
|-------|-----------|-------|-------------|
| `idle` | Off | — | No activity |
| `wake` | Pulse | Blue | Wake word detected |
| `listen` | Solid | Blue | Recording speech |
| `think` | Spin | Cyan | Processing |
| `speak` | Solid | Green | TTS playing |
| `error` | Flash | Red | Error occurred |
| `mute` | Solid dim | Amber | Microphone muted |
| `volume` | Pulse | Teal | Volume change |

### Testing
```bash
echo 'listen' | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
echo 'idle'   | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
```

---

## face.sh — Animated Face Overlay

Displays an animated face in the corner of the screen that reacts to voice states
and animates to music when MPD is playing. Implemented as a Chromium `--app` window
displaying `~/.config/mark2-face/face.html`.

The face HTML file reads `/tmp/mark2-face-event.json` (written by the face-event
bridge service installed with the satellite) to determine the current state.

### Face animations

| State | Animation |
|-------|-----------|
| `idle` | Calm blinking eyes |
| `wake` | Eyes open wide, zoom in |
| `listen` | Pulsing ring around face |
| `think` | Spinning/processing animation |
| `speak` | Mouth moving |
| `error` | Sad/confused expression |

When MPD is playing (`mark2-mpd-watcher.service` reports `play` state),
the face dances in time with music using the beat detection from MPD's elapsed time.

### Window positioning

The face window is positioned at the bottom-right of the 800×480 display:
- Size: 260×260 px
- Position: 540,220 (right side, vertically centered)

labwc window rules keep it always on top of other windows.

---

## overlay.sh — Volume Bar Overlay

Shows a transparent volume bar overlay that appears when volume changes and
automatically hides after 3 seconds of inactivity.

Implemented as a Chromium `--app` window displaying `~/.config/mark2-overlay/overlay.html`.

The overlay HTML polls `/tmp/mark2-volume.json` (written by `mark2-volume-monitor.service`)
and animates a volume bar.

### Volume monitoring service

`mark2-volume-monitor.service` runs `volume-monitor.sh` which:
- Monitors PipeWire/ALSA volume changes using `pactl subscribe`
- Writes current volume to `/tmp/mark2-volume.json`
- Triggers the overlay to appear

### Window positioning

The overlay is positioned at the bottom of the screen:
- Size: 400×120 px
- Position: 200,360 (horizontally centered on 800px display)

---

## screensaver.sh — Clock + Weather Screensaver

Activates after 2 minutes of inactivity and displays a fullscreen clock with
live weather data from Home Assistant.

### Implementation

- Uses `swayidle` to detect inactivity and trigger the screensaver
- Screensaver is a Chromium window displaying `~/.config/mark2-screensaver/screensaver.html`
- Weather data is fetched from HA's REST API using the HA token
- Clock uses system time

### Configuration

Requires:
- `HA_URL` — Home Assistant URL
- `HA_TOKEN` — Long-lived access token for weather API access
- `HA_WEATHER_ENTITY` — Weather entity (e.g. `weather.forecast_home`)

Idle timeout (default 2 minutes) can be changed:
```bash
nano ~/.config/swayidle/config
# Change the timeout value (in seconds)
```

---

## mqtt-sensors.sh — MQTT Sensor Publisher

Publishes Mark II system state to Home Assistant via MQTT with automatic discovery.
Once set up, sensors appear automatically in HA under the device name.

### Published sensors

| Sensor | Entity ID | Update rate |
|--------|-----------|-------------|
| Wyoming state | `sensor.<hostname>_wyoming_state` | On change |
| MPD state | `sensor.<hostname>_mpd_state` | On change |
| MPD track | `sensor.<hostname>_mpd_track` | On change |
| MPD artist | `sensor.<hostname>_mpd_artist` | On change |
| MPD volume | `sensor.<hostname>_mpd_volume` | On change |
| CPU temperature | `sensor.<hostname>_cpu_temp` | Every 30s |
| CPU usage | `sensor.<hostname>_cpu_usage` | Every 30s |
| Memory usage | `sensor.<hostname>_memory_usage` | Every 30s |
| Disk usage | `sensor.<hostname>_disk_usage` | Every 30s |

### MQTT Auto-discovery

The `mqtt-bridge.py` script publishes HA MQTT discovery messages on startup.
This registers the device and all sensors in HA without manual configuration.
Discovery topic format: `homeassistant/sensor/<hostname>_<sensor>/config`

### Architecture

```
mqtt-bridge.py
├── Subscribes to: /tmp/mark2-face-event.json  (Wyoming state)
├── Subscribes to: /tmp/mark2-mpd-state.json   (MPD state)
├── Publishes to:  MQTT broker
└── Reads: /proc/stat, /sys/thermal, /proc/meminfo  (system metrics)
```

`mark2-mpd-watcher.service` runs `mpd-watcher.py` which polls MPD's TCP interface
(port 6600) and writes current playback state to `/tmp/mark2-mpd-state.json`.

---

## snapcast.sh — Multiroom Audio

Installs snapclient to receive synchronized audio streams from a Snapcast server.
Snapcast is a multiroom audio system that keeps all speakers in perfect sync.

The module prompts for the Snapcast server IP and creates a systemd user service
to connect automatically.

---

## airplay.sh — AirPlay Speaker

Installs shairport-sync to make Mark II appear as an AirPlay 1 receiver.
Any Apple device or iTunes can then stream audio to Mark II.

shairport-sync is configured to use PipeWire as the audio output backend.

---

## mpd.sh — Local Music Player

Installs MPD (Music Player Daemon) for local music playback.
Works with the Music Assistant integration in HA for browsing and controlling music.

Also installs `mark2-mpd-watcher.service` (if not already present from mqtt-sensors)
which monitors MPD state for the MQTT sensors and face animation.

---

## kdeconnect.sh — Android Phone Integration

Installs kdeconnectd for pairing with Android phones via the KDE Connect app.
Enables:
- Phone notifications shown as overlays
- Media playback control from phone
- Clipboard sharing

---

## usb-audio.sh — USB Audio Fallback

Creates a systemd service that detects if the SJ201 audio fails at boot and
automatically switches to a USB audio device as fallback.

Useful for development/testing with a USB headset when the SJ201 is not available
or fails to initialize.
