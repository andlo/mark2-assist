# Known Issues

This file tracks known issues to be created as GitHub Issues.
Create each as an individual issue at: https://github.com/andlo/mark2-assist/issues

---

## Issue 1: LED ring I2C register layout needs verification

**Labels:** `bug`, `hardware`, `needs-testing`

**Description:**
The SJ201 LED ring controller Python script in `mark2-advanced-setup.sh` uses
I2C address `0x04` and writes RGB data starting at register `0x00`.

This is based on reverse-engineering of the Mycroft firmware and the
OpenVoiceOS PHAL plugin. The exact register layout has not been verified on
real hardware and may be incorrect.

**Steps to reproduce:**
1. Run `mark2-advanced-setup.sh` and install LED module
2. Test with: `echo "listen" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock`
3. Check if LEDs respond

**Expected:** LEDs light up blue
**Actual:** Unknown - needs hardware test

**References:**
- https://github.com/OpenVoiceOS/ovos-PHAL-plugin-mk2
- https://github.com/MycroftAI/mark-ii-hardware-testing

---

## Issue 2: SJ201 audio device name varies between Pi OS versions

**Labels:** `bug`, `audio`, `needs-testing`

**Description:**
In `mark2-satellite-setup.sh`, `detect_sj201_audio()` searches for
`soc_sound|xvf3510|sj201` in `arecord -L` output.

The actual device name reported by ALSA may differ between kernel versions
and Pi OS releases. If detection fails, it defaults to `plughw:0,0` which
may not be correct if other audio devices are present.

**Steps to reproduce:**
1. Run `mark2-satellite-setup.sh`
2. Check detected device in wyoming-satellite.service ExecStart line
3. Test: `arecord -D <detected-device> -r 16000 -c 1 -f S16_LE -d 3 test.wav`

**Fix needed:**
Add a verification step that actually records a short sample and confirms
the device works before writing it to the service file.

---

## Issue 3: labwc Chromium kiosk may start before Wayland compositor is ready

**Labels:** `bug`, `display`, `needs-testing`

**Description:**
In `mark2-satellite-setup.sh`, Chromium is launched from `~/.config/labwc/autostart`.
If Chromium starts before labwc has fully initialized Wayland, it will fail
silently and the kiosk display will be blank.

**Steps to reproduce:**
1. Run `mark2-satellite-setup.sh`
2. Reboot
3. Observe whether touchscreen shows HA or stays blank

**Fix needed:**
Add a `sleep 2` or a `while ! wlr-randr 2>/dev/null; do sleep 1; done`
wait loop at the top of `kiosk.sh` before launching Chromium.

---

## Issue 4: VocalFusion kernel module lost after kernel update

**Labels:** `enhancement`, `kernel`, `maintenance`

**Description:**
The VocalFusion soundcard driver (`vocalfusion-soundcard.ko`) is a compiled
kernel module. It is tied to the specific kernel version it was built for.
After `apt upgrade` updates the kernel, the module will be missing and
SJ201 audio will silently stop working on next reboot.

**Status:** Partially addressed by `mark2-advanced-setup.sh` kernel watchdog module.
The watchdog service checks and rebuilds on boot if the module is missing.

**Remaining issue:**
The watchdog requires internet access to clone VocalFusionDriver from GitHub.
If the device is offline at boot after a kernel update, the rebuild will fail.

**Fix needed:**
Cache the VocalFusion source locally after build instead of deleting it,
so rebuild can happen offline.

---

## Issue 5: AirPlay (shairport-sync) known issues on Trixie with PipeWire

**Labels:** `bug`, `audio`, `trixie`

**Description:**
Shairport-sync on Trixie (Debian 13) with PipeWire backend has reported
timing sync issues. The service may log:
`warning: Shairport Sync's PipeWire backend can not get timing information`

**References:**
- https://github.com/mikebrady/shairport-sync/issues/1970
- https://github.com/mikebrady/shairport-sync/issues/2133

**Workarounds to investigate:**
- Run shairport-sync as system service instead of user service
- Use ALSA backend directly to SJ201 instead of PipeWire
- Wait for upstream fix in shairport-sync

---

## Issue 6: install.sh reboot flow is awkward when running over SSH

**Labels:** `enhancement`, `ux`

**Description:**
When running `install.sh` over SSH, the script reboots the device mid-way
through after step 1. The user must then SSH back in and re-run
`./install.sh --skip-hardware`. This is error-prone.

**Fix needed:**
Consider splitting into two clearly named scripts:
- `install-step1.sh` (hardware only, ends with reboot prompt)
- `install-step2.sh` (everything else)

Or add clear instructions in the reboot message with the exact SSH command
to run after reconnecting.

---

## Issue 7: Screensaver HA token stored in plaintext HTML file

**Labels:** `security`, `enhancement`

**Description:**
In `mark2-extras-setup.sh`, the Home Assistant long-lived access token
is embedded directly in `~/.config/mark2-screensaver/screensaver.html`
as a JavaScript variable. This file is readable by any user on the system.

**Fix needed:**
- Store token in a separate config file with restricted permissions (600)
- Have the screensaver fetch it via a local proxy script or environment variable
- Or use HA's existing kiosk mode which doesn't require a token

---

## Issue 8: MPD HTTP stream port 8000 may conflict with other services

**Labels:** `enhancement`, `configuration`

**Description:**
MPD is configured to stream on port 8000 in `mark2-advanced-setup.sh`.
Port 8000 is commonly used by other services (Home Assistant dev server,
various web apps). This may cause a conflict.

**Fix needed:**
Make the HTTP stream port configurable, or check if port 8000 is free
before configuring it.
