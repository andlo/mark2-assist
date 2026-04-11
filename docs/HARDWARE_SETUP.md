# Hardware Setup — Technical Documentation

`mark2-hardware-setup.sh` prepares the Raspberry Pi 4 for Mark II hardware.
It must run before `mark2-satellite-setup.sh` and requires a reboot to take effect.

---

## What it does (in order)

### 1. Dependency detection

Detects the Pi model, Debian version and boot directory:

- **Pi 5 detection** — reads `/proc/device-tree/model`. If Pi 5 is detected, a
  `-pi5` suffix is appended to overlay filenames (the SJ201 board has Pi 5 specific overlays)
- **Debian version** — reads `/etc/os-release`. On Debian 13 (Trixie) the kernel
  headers package is `linux-headers-rpi-v8`; on older releases it is `raspberrypi-kernel-headers`
- **Boot directory** — uses `/boot/firmware` if present (Bookworm+), falls back to `/boot`

### 2. Kernel headers and build tools

```
apt install linux-headers-rpi-v8 build-essential git python3-venv python3-pip python3-dev
```

Required to build the VocalFusion kernel module from source.

### 3. EEPROM update

Sets `FIRMWARE_RELEASE_STATUS=latest` in `/etc/default/rpi-eeprom-update` and runs
`rpi-eeprom-update -a`. This ensures the Raspberry Pi bootloader is up to date,
which is important for reliable SPI and I2C operation.

### 4. VocalFusion driver build

The XVF-3510 microphone array requires a custom kernel module (`vocalfusion-soundcard.ko`)
to appear as an ALSA sound card.

```
git clone https://github.com/OpenVoiceOS/VocalFusionDriver /usr/src/vocalfusion
cd /usr/src/vocalfusion/driver
make -j$(nproc) KDIR=/lib/modules/$(uname -r)/build all
cp vocalfusion-soundcard.ko /lib/modules/$(uname -r)/
depmod -a
```

The DTBO overlay files (device tree binary overlays) are copied to `/boot/firmware/overlays/`:
- `sj201.dtbo` — main SJ201 device tree overlay
- `sj201-buttons-overlay.dtbo` — hardware buttons (volume up/down, action)
- `sj201-rev10-pwm-fan-overlay.dtbo` — PWM fan control on rev10 carrier boards

### 5. Boot configuration (`/boot/firmware/config.txt`)

Several hardware interfaces must be enabled:

| Setting | Purpose |
|---------|---------|
| `enable_uart=1` | UART for SJ201 initialization communication |
| `dtparam=spi=on` | SPI bus for `xvf3510-flash` to access `/dev/spidev0.0` |
| `dtparam=i2c_arm=on` | I2C bus for SJ201 LED ring (APA102 via I2C) and TAS5806 amp |
| `dtoverlay=sj201` | Loads the VocalFusion sound card device tree |
| `dtoverlay=sj201-buttons-overlay` | Loads button GPIO mappings |
| `dtoverlay=sj201-rev10-pwm-fan-overlay` | PWM fan on rev10 boards |
| `dtoverlay=rpi-backlight` | DSI display backlight control |
| `dtoverlay=vc4-kms-dsi-waveshare-800x480` | Waveshare 4.3" 800×480 DSI display |
| `dtoverlay=vc4-kms-v3d` | Full KMS GPU driver (required for Weston) |

Note: `vc4-fkms-v3d` (Fake KMS) is **removed** if present — it is deprecated on
kernel 6.x and causes `No displays found` errors with the DSI display.

### 6. Module autoload

Creates `/etc/modules-load.d/vocalfusion.conf` containing `vocalfusion-soundcard`
so the module loads automatically at boot.

### 7. Python venv for SJ201 firmware flash

The `xvf3510-flash` script requires Python with GPIO access. On Python 3.13 (Trixie)
the venv is created with `--system-site-packages` so system-installed GPIO packages
(`python3-rpi-lgpio`, `python3-smbus2`, `python3-libgpiod`) are accessible.

The venv is created at `~/.venvs/sj201`.

### 8. SJ201 firmware and scripts (from `assets/`)

Three files are installed to `/opt/sj201/`:

- **`xvf3510-flash`** — Python script that loads firmware onto the XVF-3510 chip
  via SPI (`/dev/spidev0.0`). Must run with sudo. Runs every boot via sj201.service.
- **`init_tas5806`** — Python script that initializes the TAS5806 amplifier via I2C.
  Runs after xvf3510-flash via sj201.service ExecStartPost.
- **`app_xvf3510_int_spi_boot_v4_2_0.bin`** — XVF-3510 firmware binary. This is
  loaded into the chip's RAM on each boot (the XVF-3510 has no persistent storage).

These files are vendored in the `assets/` directory of mark2-assist so no internet
connection is needed at install time.

### 9. sj201.service (systemd user service)

```ini
[Service]
Type=oneshot
ExecStart=sudo python xvf3510-flash --direct firmware.bin --verbose
ExecStartPost=python init_tas5806
RemainAfterExit=yes
```

`Type=oneshot` with `RemainAfterExit=yes` means the service is considered "active"
after the commands complete. Other services use `After=sj201.service` to ensure
audio hardware is initialized before they start.

The service runs as the user (not root) but calls sudo for `xvf3510-flash` since
SPI access requires elevated privileges.

### 10. WirePlumber audio profile

WirePlumber (PipeWire's session manager) needs to be told to use the `pro-audio`
profile for the SJ201 sound card. Without this it may try to use incorrect audio
profiles and the microphone/speaker may not work correctly.

Configuration file: `~/.config/wireplumber/wireplumber.conf.d/90-sj201-profile.conf`

The `pro-audio` profile exposes all audio channels individually, giving Wyoming
satellite direct access to the mic array capture stream.

### 11. VocalFusion kernel watchdog

Since the VocalFusion module must be compiled against the running kernel, any kernel
update will invalidate the compiled module. The watchdog service handles this:

- **`/etc/systemd/system/mark2-vocalfusion-watchdog.service`** — runs at boot before
  sj201.service, checks if the compiled module matches the current kernel, and rebuilds
  it if not
- **`~/.config/mark2/rebuild-vocalfusion.sh`** — the rebuild script itself

A weekly cron job (`/etc/cron.d/mark2-updates`) runs `sudo apt upgrade` every Sunday
at 03:00 to keep the system updated. Kernel updates will trigger a module rebuild on
the next boot.

---

## After running hardware setup

A reboot is required for all changes to take effect:
- Kernel module loaded via modules-load.d
- Boot overlays active
- sj201.service starts and initializes hardware

After reboot, verify:
```bash
systemctl --user status sj201.service   # Should be active (exited)
aplay -l                                 # Should list soc_sound card
arecord -L | grep sj201                  # Should show plughw:CARD=sj201
```
