# Hardware Test — Technical Documentation

`mark2-hardware-test.sh` is an interactive test suite that verifies all Mark II
hardware components after `mark2-hardware-setup.sh` has been run and the device
has rebooted.

Run it before `mark2-satellite-setup.sh` to catch hardware problems early.
The main installer (`install.sh`) also offers to run it automatically after
the hardware setup reboot.

---

## Usage

```bash
# Interactive (recommended)
./mark2-hardware-test.sh

# Non-interactive / automatic (skips manual yes/no checks)
./mark2-hardware-test.sh --auto
```

---

## Test order

| # | Test | What it checks |
|---|------|---------------|
| 1 | SJ201 Service | Firmware loaded, kernel module, 5s XMOS init wait |
| 2 | Audio Devices | ALSA sees SJ201 for capture and playback |
| 3 | Microphone | Records 3s, checks RMS signal level |
| 4 | Mic → Speaker Roundtrip | Records then plays back (sox resampling) |
| 5 | Speaker | Plays 440Hz test tone |
| 6 | LED Ring | NeoPixel GPIO12 cycles red/green/blue/white |
| 7 | Buttons | evdev events from volume up/down/action |
| 8 | Touchscreen & Display | DSI display + touch input device |
| 9 | Backlight | Dims and restores display brightness |
| 10 | I2C Bus | Scans bus 1 for 0x2c and 0x2f |
| 11 | SPI Bus | /dev/spidev0.0 exists |

---

## Dependencies installed by hardware setup

`mark2-hardware-setup.sh` installs these tools needed by the test:
- `sox` — audio resampling for mic→speaker roundtrip
- `i2c-tools` — I2C bus scan (`i2cdetect`)
- `evtest` — button input event testing

If missing, the test auto-installs `i2c-tools` and `sox` on demand.

---

## Test descriptions

### 1. SJ201 Service

Checks that the SJ201 hardware initialization completed successfully:

- **sj201.service active** — `systemctl --user is-active sj201.service`
  Should be `active (exited)` — oneshot service that runs at boot
- **5 second wait** — XMOS XVF-3510 needs time after firmware is loaded via SPI
  before the kernel module appears in `lsmod` and the microphone is ready.
  Without this wait, tests 1 and 3 will incorrectly fail.
- **XVF3510 firmware file** — `/opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin`
  Must exist; loaded into XMOS chip RAM on each boot via SPI
- **VocalFusion kernel module** — `lsmod | grep vocalfusion`
  Module name is `vocalfusion_soundcard` (underscore). Must be loaded for
  SJ201 to appear as an ALSA sound card.

If sj201.service failed:
```bash
systemctl --user status sj201
journalctl --user -u sj201 -n 20
```

### 2. Audio Devices (ALSA)

Verifies that ALSA sees the SJ201 sound card for both capture and playback:

- **SJ201 capture device** — `arecord -l | grep sj201`
  Card 1, device 1: `bcm2835-i2s-dir-hifi` (microphone array input)
- **SJ201 playback device** — `aplay -l | grep sj201`
  Card 1, device 0: `bcm2835-i2s-dit-hifi` (speaker output via XMOS)
- Detects the correct `plughw:CARD=sj201,DEV=X` device names for subsequent tests

### 3. Microphone

Records 3 seconds and analyses the signal level. Waits an additional 2 seconds
before recording to ensure XMOS is fully ready.

Press Enter when prompted — recording starts immediately afterwards.
Speak clearly or clap your hands during the 3 second window.

```bash
arecord -D plughw:CARD=sj201,DEV=1 -r 16000 -c 1 -f S16_LE -d 3 /tmp/test.wav
```

Signal level thresholds:
- RMS > 200 — good level ✅
- RMS 50–200 — low (speak louder) ✅
- RMS < 50 — no signal, check SJ201 timing ❌

### 4. Microphone → Speaker Roundtrip

Records 4 seconds, resamples with sox from 16kHz mono to 48kHz stereo,
then plays back through the speaker.

Press Enter when ready — then speak clearly for 4 seconds.

**Important:** Playback quality will sound processed and distorted — this is
completely normal. The XMOS XVF-3510 applies noise reduction and beamforming
to the microphone signal, which is optimised for speech recognition, not
hi-fi playback. What matters is that you can roughly recognise what was said.

sox resampling provides proper sinc interpolation. The earlier naive Python
sample-repeat method caused severe clicking and is no longer used.

### 5. Speaker

Generates a 440 Hz sine wave tone at 48kHz stereo and attempts to play it
through the SJ201 amplifier.

**Audio routing on SJ201:**
```
Raspberry Pi I2S → XMOS XVF-3510 → TAS5806 amplifier → Speakers
```
Audio does NOT go directly from the Pi to the TAS5806. The XMOS chip
sits in the middle and routes/processes audio. This means:
- The correct format for playback is 48kHz stereo
- Playing 16kHz mono may not produce sound even if aplay reports no error
- aplay can hang indefinitely if XMOS is not ready or expects a different format

The test tries multiple formats with a 5-second timeout each:
1. `plughw:CARD=sj201,DEV=0 -r 48000 -c 2` ← most likely to work
2. `plughw:CARD=sj201,DEV=0 -r 16000 -c 2`
3. `plughw:CARD=sj201,DEV=0`
4. `default`

### 6. LED Ring

**Important discovery:** The SJ201 LED ring is **NeoPixel WS2812B connected
to GPIO12 (PWM pin)** — it is NOT an I2C device.

The `0x2c` address seen on I2C bus 1 is a different component on the SJ201
board, not the LED ring controller.

LED control uses `adafruit-circuitpython-neopixel` + `adafruit-blinka`:
- 12 pixels, GRB colour order, brightness 0.2
- Requires running as `sudo` (GPIO12/PWM access)
- Cycles: Red → Green → Blue → White → Off

If neopixel is not installed:
```bash
sudo pip3 install adafruit-circuitpython-neopixel --break-system-packages
```

### 7. Hardware Buttons

Tests the three hardware buttons via Linux evdev input events:
- Volume Up
- Volume Down
- Action (center, in LED ring)

The buttons are registered via `sj201-buttons-overlay.dtbo` as a GPIO
input device at `/devices/platform/soc/soc:sj201_buttons/input/input0`.

Press Enter when prompted — then press any button within 8 seconds.
The test uses `evtest` to detect `EV_KEY` (type 1) events.

If `evtest` is not installed: `sudo apt install evtest`

### 8. Touchscreen & Display

Checks that the DSI display and touch controller are detected:

- **DSI display** — `/sys/class/drm/card*-DSI*` DRM connector
- **Touch input** — `/dev/input/event*` matching `touch`, `waveshare`, or `ft5`
  (FT5x06 touch controller in the Waveshare 4.3" display)

### 9. Backlight

Verifies `/sys/class/backlight/rpi_backlight/`. Dims to brightness 10
for 2 seconds then restores. Requires `dtoverlay=rpi-backlight` in config.txt.

### 10. I2C Bus Scan

Scans I2C bus 1 with `sudo i2cdetect -y 1`. Auto-installs `i2c-tools` if missing.

**Known SJ201 I2C addresses (bus 1):**

| Address | Device |
|---------|--------|
| `0x2c` | Unknown SJ201 component (NOT the LED ring) |
| `0x2f` | TAS5806 amplifier |

Note: The LED ring is on GPIO12 (NeoPixel), not I2C. `0x2c` accepts single
byte writes but rejects block writes — its exact function is undetermined.

### 11. SPI Bus

Checks that `/dev/spidev0.0` exists. Required for `xvf3510-flash` to load
the XMOS XVF-3510 firmware via SPI at boot.

---

## Common failures and fixes

| Failure | Likely cause | Fix |
|---------|-------------|-----|
| sj201.service not active | SPI not enabled, firmware flash failed | Check config.txt, rerun hardware setup |
| VocalFusion not loaded | XMOS init timing | Run test again; wait longer after boot |
| SJ201 capture missing | VocalFusion not loaded | Same as above |
| Mic RMS = 0/1 | XMOS not ready | Run test again after fresh boot |
| Speaker no sound | XMOS format or 12V missing | Check 12V barrel jack; try 48kHz stereo |
| Roundtrip sounds distorted | Normal! XMOS processes audio | Expected — not a failure |
| LED Errno 5 | Old I2C code (now fixed) | Update to latest mark2-assist |
| Buttons no event | evtest not installed | `sudo apt install evtest` |
| DSI display missing | Wrong overlay | Check config.txt overlays |

---

## Exit codes

The script always exits 0. Check the summary at the end for pass/fail counts.
