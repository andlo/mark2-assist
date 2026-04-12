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

## Test descriptions

### 1. SJ201 Service

Checks that the SJ201 hardware initialization completed successfully:

- **sj201.service active** — `systemctl --user is-active sj201.service`
  Should be `active (exited)` — oneshot service that runs at boot
- **XVF3510 firmware file** — `/opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin`
  Must exist; loaded into XMOS chip RAM on each boot via SPI
- **VocalFusion kernel module** — `lsmod | grep vocalfusion`
  Must be loaded for SJ201 to appear as an ALSA sound card

If sj201.service failed, check:
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

If not found: reboot and check `dmesg | grep -i vocalfusion`

### 3. Microphone

Records 3 seconds of audio and analyses the signal level:

```bash
arecord -D plughw:CARD=sj201,DEV=1 -r 16000 -c 1 -f S16_LE -d 3 /tmp/test.wav
```

Signal level thresholds:
- RMS > 200 — good level ✅
- RMS 50–200 — low (speak louder) ✅
- RMS < 50 — no signal, check SJ201 initialization ❌

**Say something or clap** while the test records. The SJ201 has 6 MEMS
microphones in a circular array — it should pick up sound from any direction
at normal speaking volume from across the room.

### 4. Speaker

Generates a 440 Hz sine wave tone at 48kHz stereo and attempts to play it
through the SJ201 amplifier.

**Important — audio routing on SJ201:**
```
Raspberry Pi I2S → XMOS XVF-3510 → TAS5806 amplifier → Speakers
```
Audio does NOT go directly from the Pi to the TAS5806. The XMOS chip
sits in the middle and routes/processes audio. This means:
- The correct format for playback is likely 48kHz stereo (XMOS requirement)
- Playing 16kHz mono may not produce sound even if aplay reports no error
- aplay can hang indefinitely if XMOS is not ready or expects a different format

The test tries multiple formats with a 5-second timeout each:
1. `plughw:CARD=sj201,DEV=0 -r 48000 -c 2` (most likely to work)
2. `plughw:CARD=sj201,DEV=0 -r 16000 -c 2`
3. `plughw:CARD=sj201,DEV=0` (ALSA default format)
4. `default` (system default sink)

After playing, the test asks: "Did you hear a tone?"

If TAS5806 is initialized (reg 0x03 = 0x03 play state) but no sound:
- Check 12V power is connected to the barrel jack
- Check `gpioget --chip gpiochip0 5` returns `active` (SHTDN signal)
- The XMOS firmware may not be routing audio correctly

### 5. Microphone → Speaker Roundtrip

Records 3 seconds at 16kHz mono (standard mic format), converts to 48kHz
stereo, then plays back through the speaker. Lets you hear your own voice
to confirm the full audio chain works end-to-end.

### 6. LED Ring

Tests the SJ201 LED ring (12 APA102 LEDs) via I2C smbus2:

```python
bus = smbus2.SMBus(1)
# Write RGB data to I2C address 0x2c
bus.write_i2c_block_data(0x2c, 0x00, [R, G, B] * 12)
```

**Known I2C addresses on SJ201 (I2C bus 1):**
- `0x2c` — LED ring controller
- `0x2f` — TAS5806 amplifier (address set by ADR pins)

Cycles through: Red → Green → Blue → White → Off

Asks: "Did the LED ring cycle through colors?"

### 7. Hardware Buttons

Tests the three hardware buttons via Linux evdev input events:
- Volume Up
- Volume Down
- Action (center, in LED ring)

The buttons are registered via `sj201-buttons-overlay.dtbo` as a GPIO
input device (`/devices/platform/soc/soc:sj201_buttons/input/input0`).

The test looks for `/dev/input/event*` devices matching `sj201` or `button`
in udevadm info, then waits 5 seconds for a key press event.

If buttons are not detected: check `dmesg | grep sj201_buttons`

### 8. Touchscreen & Display

Checks that the DSI display and touch controller are detected:

- **DSI display** — looks for `/sys/class/drm/card*-DSI*` DRM connector
  Status should be `connected` or at least `unknown` (display present)
- **Touch input** — looks for `/dev/input/event*` matching `touch`, `waveshare`,
  or `ft5` (FT5x06 touch controller in the Waveshare display)

The `vc4-kms-dsi-waveshare-800x480` overlay must be present in `config.txt`.

### 9. Backlight

Verifies backlight control via `/sys/class/backlight/rpi_backlight/`:

- Reads current brightness and maximum brightness
- Dims to brightness 10 for 2 seconds then restores
- Asks: "Did the display dim and return to normal?"

Requires `dtoverlay=rpi-backlight` in `config.txt`.

### 10. I2C Bus Scan

Runs `i2cdetect -y 1` on I2C bus 1 (the main Pi I2C bus) and checks
for known SJ201 device addresses:

| Address | Device |
|---------|--------|
| `0x2c` | LED ring controller |
| `0x2f` | TAS5806 amplifier |

Note: TAS5806 may not appear in i2cdetect after initialization as it
enters a state that doesn't respond to address scanning. The `init_tas5806`
script reports `[TAS5806] Initialized successfully` in sj201.service logs.

### 11. SPI Bus

Checks that `/dev/spidev0.0` exists — required for `xvf3510-flash` to load
the XMOS XVF-3510 firmware via SPI at boot.

Requires `dtparam=spi=on` in `config.txt`.

---

## Common failures and fixes

| Failure | Likely cause | Fix |
|---------|-------------|-----|
| sj201.service not active | SPI/I2C not enabled, or firmware flash failed | Check `config.txt`, rerun `mark2-hardware-setup.sh` |
| VocalFusion module not loaded | Kernel update invalidated module | Wait for watchdog to rebuild, or run `mark2-hardware-setup.sh` |
| SJ201 capture device missing | VocalFusion module not loaded | See above |
| Microphone RMS = 0 | Wyoming satellite holding mic | Stop wyoming-satellite before testing |
| Speaker no sound | XMOS format mismatch, or 12V missing | Check 12V barrel jack, try 48kHz stereo |
| LED I/O error | Wrong I2C address or SJ201 not powered | Check `sudo i2cdetect -y 1` for 0x2c |
| Buttons no event | sj201-buttons-overlay not loaded | Check `dmesg | grep sj201_buttons` |
| DSI display missing | Wrong overlay or vc4-fkms instead of vc4-kms | Check `config.txt` overlays |
| I2C devices missing | dtparam=i2c_arm=on not set | Check `config.txt`, rerun hardware setup |

---

## Exit codes

- `0` — all tests passed (or all failures were in skipped tests)
- Non-zero — one or more tests failed

The summary at the end lists all failed tests with their error messages.
