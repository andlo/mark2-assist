# XVF3510 Microphone Hardware — How It Works

This document captures everything learned about the XMOS XVF3510-INT microphone chip
on the SJ201 board after five investigation sessions (April–May 2026).

---

## Architecture

The SJ201 board contains:
- **XMOS XVF3510-INT** — far-field microphone DSP chip (no onboard flash)
- **TAS5806** — Class-D amplifier (I2C controlled, address 0x2F)
- **Raspberry Pi 4B** connection via 40-pin GPIO header

### XVF3510-INT specifics

The `-INT` variant has **no external SPI flash**. It boots exclusively via:
1. **SPI slave boot** — Pi sends firmware binary over SPI on every power-up
2. **Internal eFuse/ROM** — factory defaults only, no persistent user config

There is no way to store configuration permanently without XMOS JTAG hardware (`xflash`).

---

## The Root Cause (MCLK frequency)

### Symptom
Microphone produced no audio after boot. Only a ~250ms "boot tone" was audible
immediately after SPI flash, then permanent silence.

### Root cause
`sj201.dtbo` (the Device Tree overlay for the SJ201) sets **MCLK = 24.576 MHz** on GPIO4.
The XVF3510-INT requires exactly **12.288 MHz** to start its internal DSP pipeline.

With the wrong MCLK:
- Chip boots and acknowledges SPI firmware (I2C responds on 0x2C)
- `GET_RUN_STATUS` returns `SPIBOOT_WITH_DEFAULT_SETTINGS`
- I2S output is silent — DSP pipeline never activates

With the correct 12.288 MHz MCLK:
- DSP pipeline starts automatically
- I2S capture (`hw:sj201,1`) produces real microphone data
- RMS ~0.10–0.27 sustained, non-zero samples ~50–54%

### Why Mycroft's firmware worked
Mycroft's original `run.sh` used `setup_mclk` (compiled from XMOS's
`vocalfusion-rpi-setup`) which explicitly set 12.288 MHz via `/dev/mem`
before flashing. `sj201.dtbo` was created later by OpenVoiceOS and
introduced the wrong frequency.

---

## Boot Sequence (Required)

The following sequence **must** happen on every power-up in this exact order:

```
1. insmod i2s_master_loader.ko   # activate I2S hardware block (fe203000.i2s)
2. arecord -d 1 /dev/null        # force ALSA to configure I2S clocks
3. sudo setup_mclk               # GPIO4/GPCLK0 = 12.288 MHz via /dev/mem
4. sudo setup_bclk               # PCM clock divider = 3.072 MHz BCLK (clk_enable=0)
5. xvf3510-flash --direct fw.bin # SPI slave boot (bit-reversed transfer, 5 MHz)
6. init_tas5806                  # TAS5806 amplifier init via I2C
7. restart PipeWire/WirePlumber  # audio stack with correct clocks
```

This is implemented in `lib/mark2-xvf-post-wp.sh`, called by
`mark2-audio-init.service` at boot.

### GPIO assignments
| GPIO | Function       | Default state |
|------|----------------|---------------|
| 4    | GPCLK0 (MCLK)  | ALT0, 12.288 MHz after setup_mclk |
| 16   | PWR enable     | HIGH (chip powered) |
| 26   | BOOT_SEL       | HIGH = SPI slave boot, LOW = internal flash |
| 27   | RST_N          | HIGH (chip running), external pull-up |

---

## Clock Details

### MCLK (GPIO4 / GPCLK0)
- Source: PLLD (750 MHz on RPi4)
- Divider: I=61, F=144, MASH=1
- Result: **12.288 MHz**
- Set by: `setup_mclk` (compiled from `lib/setup_mclk_bclk.c` with `-DMCLK`)

### BCLK (PCM clock / I2S bit clock)
- Source: PLLD (750 MHz on RPi4)
- Divider: I=244, F=576, MASH=1
- Result: **3.072 MHz** (= 48000 Hz × 64 bits/frame)
- Set by: `setup_bclk` (same source, compiled without `-DMCLK`)
- Note: `clk_enable=0` — clock configured but not explicitly enabled via GPIO;
  the I2S driver activates it when PCM device is opened

---

## SPI Flash Protocol

The XVF3510-INT receives its firmware via SPI in **SPI slave boot mode**:
- SPI mode 0 (CPOL=0, CPHA=0) or mode 3
- Max speed: 5 MHz
- **Bit reversal required**: each byte must be bit-reversed before sending
  (XVF3510 reads LSB first)
- Block size: 4096 bytes, with 100ms pause after first block (PLL reboot)
- Total firmware size: 192 KB (`app_xvf3510_int_spi_boot_v4_2_0.bin`)

GPIO reset sequence for clean boot:
```python
GPIO16 HIGH  # PWR
GPIO27 LOW   # RST (hold in reset)
GPIO26 HIGH  # BOOT_SEL (SPI slave mode)
# wait 100ms
GPIO27 HIGH  # RST release — chip starts waiting for SPI
# send firmware via SPI
GPIO26 INPUT # release BOOT_SEL (chip holds it via external pull-up)
```

---

## I2C Control Interface

After successful boot, the XVF3510 is controllable via I2C:
- **Address: 0x2C** (bus 1)
- **Tool: `vfctrl_i2c`** (in `/opt/sj201/`)
- **Important**: I2C commands are ignored if I2S clocks are not running
  (per XMOS datasheet)

Key commands:
```bash
vfctrl_i2c -n GET_VERSION          # → v4.2.0
vfctrl_i2c -n GET_RUN_STATUS       # → SPIBOOT_WITH_DEFAULT_SETTINGS
vfctrl_i2c -n GET_I2S_START_STATUS # → 2 (default) or 1 (started)
vfctrl_i2c -n GET_MIC_START_STATUS # → 2 (default) or 1 (started)
```

### SPIBOOT_WITH_DEFAULT_SETTINGS
This status means the chip booted from SPI and has no data partition in
internal flash. The DSP pipeline **does start** when MCLK is correct (12.288 MHz)
— the status is misleading. Runtime `SET_MIC_START_STATUS 1` does NOT start
the pipeline; only the MCLK frequency matters.

---

## Data Partition (advanced / not required)

XMOS documentation mentions a "data partition" stored in the chip's internal
flash that configures boot-time parameters. On the SJ201, the internal flash
is inaccessible without XMOS JTAG hardware (`xflash` tool + XTAG adapter).

**This is not required for normal operation.** The correct MCLK frequency
alone is sufficient to start the microphone pipeline.

Investigation attempts (all confirmed non-viable):
- `SET_SPI_PUSH_AND_EXEC` for WREN → works (1 byte), Sector Erase → hangs forever
- Direct SPI access via Pi pins during reset → returns all zeros (internal flash only)
- DFU over I2C → documented as unsupported for XVF3510-INT
- Firmware binary patching → boot tone only, no pipeline start

---

## ALSA Device Names

| ALSA device      | Direction | Description |
|------------------|-----------|-------------|
| `hw:sj201,0`     | Playback  | I2S to TAS5806 amplifier |
| `hw:sj201,1`     | Capture   | I2S from XVF3510 (mic output) |
| `hw:CARD=sndrpisimplecar,DEV=0` | Both | i2s_master_loader dummy card |

Under PipeWire/WirePlumber, `hw:sj201,1` is held exclusively. Use the
PipeWire node name for LVA and other applications:
- **Input**: `Built-in Audio (bcm2835-i2s-dir-hifi dir-hifi-1)`
- **Output**: `pipewire/alsa_output.hw:sj201,0`

---

## Troubleshooting

### Silence after boot
1. Check `journalctl --user -u mark2-audio-init` — did it run?
2. Check `/usr/local/bin/setup_mclk` exists and is executable
3. Run manually: `bash /usr/local/bin/mark2-xvf-post-wp.sh`
4. Test: `pw-record --rate 16000 --channels 1 --format s16 /tmp/test.wav`

### I2C not responding (after flash)
- Ensure aplay or arecord is active when sending I2C commands
- The XVF3510 ignores I2C if I2S clocks are not running
- Check GPIO16 (PWR) is HIGH: `raspi-gpio get 16`

### Chip boots but no audio in PipeWire
- Check WirePlumber profile: `wpctl status | grep -A5 Sources`
- Verify `pipewire-alsa` is installed: `dpkg -l pipewire-alsa`
- Check WirePlumber conf: `~/.config/wireplumber/wireplumber.conf.d/90-sj201-profile.conf`

### LVA "Device or resource busy"
- WirePlumber holds `hw:sj201,1` exclusively
- Use PipeWire node name: `Built-in Audio (bcm2835-i2s-dir-hifi dir-hifi-1)`
- Or install `pipewire-alsa` and use `pipewire` ALSA device

---

## Files Reference

| File | Purpose |
|------|---------|
| `lib/setup_mclk_bclk.c` | XMOS clock utility source (MCLK + BCLK setup) |
| `lib/mark2-xvf-post-wp.sh` | Boot init script (full sequence) |
| `assets/xvf3510-flash` | SPI slave boot tool (Python) |
| `assets/app_xvf3510_int_spi_boot_v4_2_0.bin` | XVF3510 firmware binary |
| `assets/init_tas5806.py` | TAS5806 amplifier init |
| `assets/wireplumber-90-sj201-profile.conf` | WirePlumber pro-audio config |
