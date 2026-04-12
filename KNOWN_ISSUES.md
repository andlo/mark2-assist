# Known Issues

This file tracks known issues and limitations.
Create individual GitHub Issues at: https://github.com/andlo/mark2-assist/issues

Status legend: ✅ Fixed | ⚠️ Partial | ❌ Open

---

## Issue 1: LED ring I2C register layout needs verification ❌

**Labels:** `bug`, `hardware`, `needs-testing`

**Description:**
The SJ201 LED ring controller uses I2C address `0x04` and writes RGB data
starting at register `0x00`. This is based on reverse-engineering of the
Mycroft firmware and the OpenVoiceOS PHAL plugin. The exact register layout
has not been verified exhaustively on real hardware.

**Test:**
```bash
systemctl --user start mark2-leds
echo "listen" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
# Expected: LEDs light up blue
echo "idle" | socat - UNIX-CONNECT:/tmp/mark2-leds.sock
```

**References:**
- https://github.com/OpenVoiceOS/ovos-PHAL-plugin-mk2
- https://github.com/MycroftAI/mark-ii-hardware-testing

---

## Issue 2: SJ201 audio device name varies between Pi OS versions ⚠️

**Labels:** `bug`, `audio`, `needs-testing`

**Status:** Detection works on Trixie — device appears as `plughw:CARD=sj201,DEV=1`.
However there is no post-detection verification that the device actually records audio.

**Fix needed:**
Add a short test recording after detection to confirm the device works before
writing it to wyoming-satellite.service.

---

## Issue 3: Chromium starts before Wayland compositor is ready ✅

**Status:** Fixed.

`kiosk.sh` now waits for `/run/user/<uid>/wayland-0` socket to appear
(up to 30 seconds) before launching Chromium. The switch from labwc to
Weston also eliminated the timing race — Weston calls `startup.sh` only
after the Wayland session is fully established.

---

## Issue 4: VocalFusion kernel module lost after kernel update ⚠️

**Labels:** `enhancement`, `kernel`, `maintenance`

**Status:** Partially fixed — `mark2-vocalfusion-watchdog.service` runs at boot
before `sj201.service` and automatically rebuilds the module if it is missing
for the current kernel.

**Remaining issue:**
The watchdog clones VocalFusionDriver from GitHub during rebuild. If the device
is offline at boot after a kernel update, the rebuild will fail.

**Fix needed:**
Cache the VocalFusion source in `/usr/src/vocalfusion-rebuild` after initial
build so offline rebuilds are possible.

---

## Issue 5: AirPlay (shairport-sync) timing issues on Trixie with PipeWire ❌

**Labels:** `bug`, `audio`, `trixie`

**Description:**
Shairport-sync on Trixie (Debian 13) with PipeWire backend may log:
`warning: Shairport Sync's PipeWire backend can not get timing information`

**References:**
- https://github.com/mikebrady/shairport-sync/issues/1970
- https://github.com/mikebrady/shairport-sync/issues/2133

**Workarounds to investigate:**
- Run shairport-sync as system service instead of user service
- Use ALSA backend directly to SJ201 instead of PipeWire

---

## Issue 6: install.sh reboot flow over SSH requires manual resume ⚠️

**Labels:** `enhancement`, `ux`

**Status:** Partially improved — after reboot, `.bash_profile` shows a clear
message with the exact command to resume. However the user still needs to
SSH back in and run `./install.sh` manually.

**Fix needed:** Consider a systemd service that auto-continues the install
after reboot without SSH interaction, for headless setups.

---

## Issue 7: Screensaver HA token stored in plaintext HTML file ❌

**Labels:** `security`, `enhancement`

**Description:**
The HA long-lived access token is embedded in
`~/.config/mark2-screensaver/screensaver.html` as a JavaScript variable.
This file is world-readable.

**Fix needed:**
Fetch the token at runtime from `~/.config/mark2/config` (which is chmod 600)
via a local proxy script, rather than embedding it in HTML.

---

## Issue 8: MPD HTTP stream port 8000 may conflict with other services ❌

**Labels:** `enhancement`, `configuration`

**Description:**
`modules/mpd.sh` configures MPD to stream on port 8000 (line 82 in mpd.sh).
This port is commonly used by other services. No conflict detection is done.

**Fix needed:**
Check if port 8000 is free before configuring it, or make the port configurable.

---

## Issue 9: labwc removed as main compositor — optional modules may need update ⚠️

**Labels:** `enhancement`, `display`

**Description:**
The main kiosk display now uses Weston instead of labwc. The optional `face`
and `overlay` modules still launch Chromium `--app` windows and rely on
labwc window rules (`rc.xml`) for always-on-top positioning.

These modules have not been fully retested with the Weston-based setup.
The HUD windows may not display correctly on top of the Weston kiosk.

**Status:** labwc is still installed alongside Weston so the modules can
still run, but the interaction between Weston (kiosk) and labwc-managed
HUD windows needs verification.

---

## Issue 10: Chromium GPU — invalid ANGLE backend on Trixie ✅

**Status:** Fixed.

Debian Trixie's `/usr/bin/chromium` wrapper sets `want_gles=1` which appends
`--use-angle=gles` — an invalid ANGLE backend. This caused Chromium's GPU
process to crash in a loop resulting in a blank/white page.

Fixed by `/etc/chromium.d/gpu-flags`:
```bash
want_gles=0
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --use-angle=opengles"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ignore-gpu-blocklist"
```

---

## Issue 11: Fan overlay only applies to Rev10 — Rev6 Dev Kits have no fan ❌

**Labels:** `hardware`, `documentation`

**Description:**
`sj201-rev10-pwm-fan-overlay.dtbo` is installed for all units. Rev6 Dev Kits
have no fan connector — the overlay loads harmlessly but generates a dmesg warning.

**Fix needed:**
Detect board revision during setup and skip fan overlay on Rev6.

---

## Issue 12: Fan thermal thresholds are fixed in DTBO ❌

**Labels:** `enhancement`, `configuration`

**Description:**
Fan temperature thresholds are hardcoded in the DTBO overlay:
40°C start / 50°C medium / 55°C high / 60°C full speed.

**Workaround:**
Thresholds can be overridden in `/boot/firmware/cmdline.txt`:
```
dtoverlay=sj201-rev10-pwm-fan-overlay,poe_fan_temp0=35000,poe_fan_temp0_hyst=5000
```

**Fix needed:** Document this workaround in README or add a helper command.

---

## Issue 13: MQTT sensors publish wrong JSON format ❌

**Labels:** `bug`, `mqtt`

**Description:**
HA logs show template warnings when MQTT sensors publish:
```
'dict object' has no attribute 'disk_usage'
'dict object' has no attribute 'cpu_temp'
```
This means `mqtt-bridge.py` is publishing a nested dict instead of flat
key-value pairs expected by the MQTT sensor templates in `mqtt-sensors.sh`.

**Fix needed:**
Review `lib/mqtt-bridge.py` publish format and align with the templates
defined in `modules/mqtt-sensors.sh`.
