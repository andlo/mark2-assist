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
| 1 | SJ201 Service | Firmware loaded, kernel module, XMOS init wait |
| 2 | Audio Devices | ALSA sees SJ201 for capture and playback |
| 3 | Microphone + Roundtrip | One recording: checks level AND plays back |
| 4 | Speaker | Verified by roundtrip, or separate beep if needed |
| 5 | LED Ring | NeoPixel GPIO12 cycles red/green/blue/white |
| 6 | Buttons | evdev events from volume up/down/action |
| 7 | Touchscreen & Display | DSI display + touch input device |
| 8 | Backlight | Dims and restores display brightness |
| 9 | I2C Bus | Scans bus 1 for 0x2c and 0x2f |
| 10 | SPI Bus | /dev/spidev0.0 exists |

---

## Design principles

- **One recording, two tests** — test 3 records once, checks signal level
  automatically, then plays back the same recording. No need to record twice.
- **Speaker verified by roundtrip** — if the user confirms they heard the
  roundtrip playback, test 4 marks speaker as PASS automatically. The beep
  tone only plays if roundtrip was skipped or failed.
- **Press Enter before every interactive action** — each test that requires
  the user's attention explains what will happen, then waits for Enter.
- **Poll instead of fixed sleep** — vocalfusion module readiness is polled
  each second (up to 15s) rather than a fixed wait, so tests run faster
  when hardware is ready early.

---


## Dependencies

`mark2-hardware-setup.sh` installs these tools needed by the test:
- `sox` — audio resampling for mic→speaker roundtrip
- `i2c-tools` — I2C bus scan (`i2cdetect`)
- `evtest` — button input event testing

The test auto-installs `i2c-tools` and `sox` on demand if missing.

For LED ring tests, the neopixel library must be installed as root:
```bash
sudo pip3 install adafruit-circuitpython-neopixel --break-system-packages
```

---

## Test descriptions

### 1. SJ201 Service

- **sj201.service active** — `systemctl --user is-active sj201.service`
  Should be `active (exited)` — oneshot service that runs at boot.
- **Poll for vocalfusion module** — waits up to 15 seconds, checking each
  second until `vocalfusion_soundcard` appears in `lsmod`. Shows how many
  seconds it took. Avoids false failures from fixed sleep timers.
- **XVF3510 firmware file** — `/opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin`

If sj201.service failed:
```bash
systemctl --user status sj201
journalctl --user -u sj201 -n 20
```

### 2. Audio Devices (ALSA)

- **SJ201 capture device** — `arecord -l | grep sj201`
  Card 1, device 1: `bcm2835-i2s-dir-hifi`
- **SJ201 playback device** — `aplay -l | grep sj201`
  Card 1, device 0: `bcm2835-i2s-dit-hifi`

### 3. Microphone + Roundtrip

One recording serves both tests:

1. Waits 2 extra seconds for XMOS to be ready for capture
2. Prompts "Press Enter when ready" — recording starts immediately after
3. Records 4 seconds at 16kHz mono (`plughw:CARD=sj201,DEV=1`)
4. Automatically checks RMS/Peak signal level → PASS/FAIL
5. Converts to 48kHz stereo with `sox` for playback via XMOS
6. Plays back through speaker
7. Asks: "Could you roughly hear what you said?"

**About roundtrip audio quality:** The XMOS XVF-3510 applies noise reduction
and beamforming to the microphone signal. This is designed for speech
recognition, not hi-fi playback. Roundtrip audio will sound processed and
distorted — this is completely normal and not a failure. What matters is
that you can roughly recognise what was said.

Signal level thresholds:
- RMS > 200 — good level ✅
- RMS 50–200 — low (speak louder) ✅
- RMS < 50 — no signal ❌

### 4. Speaker

If the user answered "yes" to the roundtrip question, speaker is marked
PASS automatically — no separate test needed.

Only runs a separate beep tone test if roundtrip was skipped or failed.
The tone is 440 Hz, 48kHz stereo, 2 seconds — the format XMOS expects.

### 5. LED Ring

**Important:** The SJ201 LED ring is **NeoPixel WS2812B on GPIO12 (PWM)**
— NOT an I2C device. The `0x2c` address on I2C bus 1 is a different
component whose function is not yet determined.

LED control uses `adafruit-circuitpython-neopixel` + `adafruit-blinka`:
- 12 pixels, GRB colour order, brightness 0.2
- Must run as `sudo` (GPIO12 PWM access requires root)
- Cycles: Red → Green → Blue → White → Off

### 6. Hardware Buttons

Tests volume up/down/action buttons via Linux evdev (`/dev/input/event0`).
Uses `evtest` to detect `EV_KEY` (type 1) events. Waits 8 seconds.

The buttons are registered by `sj201-buttons-overlay.dtbo` as
`/devices/platform/soc/soc:sj201_buttons/input/input0`.

### 7. Touchscreen & Display

- Checks `/sys/class/drm/card*-DSI*` for the DSI connector
- Checks `/dev/input/event*` for touch device (FT5x06 controller)
- Asks: "Is the display lit up and visible?"

### 8. Backlight

- Reads `/sys/class/backlight/rpi_backlight/brightness`
- Dims to 10 for 2 seconds, then restores
- Asks: "Did the display dim and return to normal?"

Requires `dtoverlay=rpi-backlight` in config.txt.

### 9. I2C Bus Scan

Scans I2C bus 1 with `sudo i2cdetect -y 1`. Auto-installs `i2c-tools` if
missing.

**Known SJ201 I2C addresses (bus 1):**

| Address | Device |
|---------|--------|
| `0x2c` | Unknown SJ201 component (NOT the LED ring) |
| `0x2f` | TAS5806 amplifier |

### 10. SPI Bus

Checks `/dev/spidev0.0`. Required for `xvf3510-flash` to load XMOS firmware.
Requires `dtparam=spi=on` in config.txt.

---

## Common failures and fixes

| Failure | Likely cause | Fix |
|---------|-------------|-----|
| sj201.service not active | SPI not enabled, firmware flash failed | Check config.txt, rerun hardware setup |
| VocalFusion not loaded after 15s | Module compile failed | Check `dmesg \| grep vocalfusion` |
| Mic RMS = 0/1 | XMOS not ready | Run test again after fresh boot |
| Speaker no sound | XMOS format or 12V missing | Check 12V barrel jack |
| Roundtrip sounds distorted | Normal — XMOS processes audio | Expected, not a failure |
| LED fails with ImportError | neopixel not installed | `sudo pip3 install adafruit-circuitpython-neopixel --break-system-packages` |
| Buttons no event | evtest not installed or not pressed in time | `sudo apt install evtest` |
| DSI display missing | Wrong overlay | Check config.txt for `vc4-kms-dsi-waveshare-800x480` |
| 0x2c not on I2C | SJ201 not powered | Check 12V, check i2c_arm=on |
