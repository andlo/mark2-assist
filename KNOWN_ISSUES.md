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
writing it to lva.service.

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

## Issue 6: install.sh reboot flow over SSH requires manual resume ✅

**Status:** Fixed.

`install.sh` has a full resume system:
- After hardware setup completes, `install_resume_hook()` writes a block to
  `~/.bash_profile` that displays a clear message on next login
- After reboot, `install.sh` auto-detects that hardware is done but satellite
  is not, and sets `RESUME=true` automatically
- Simply re-run `./install.sh` after SSH reconnect — no `--resume` flag needed
- `remove_resume_hook()` cleans up `.bash_profile` once installation completes

---

## Issue 7: Screensaver HA token stored in plaintext HTML file ❌

**Labels:** `security`, `enhancement`

**Description:**
`modules/screensaver.sh` embeds the HA long-lived access token directly into
`~/.config/mark2-screensaver/screensaver.html` (line 39 in screensaver.sh,
line 45 in templates/screensaver.html). This file is world-readable.

**Fix needed:**
Fetch the token at runtime from `~/.config/mark2/config` (chmod 600) via a
local proxy script or small backend, rather than embedding it in HTML.

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

## Issue 13: MQTT sensors publish wrong JSON format ✅

**Status:** Fixed.

System metrics (`cpu_temp`, `cpu_usage`, `memory_usage`, `disk_usage`) were
only added to the state dict after the first `POLL_INTERVAL` (10 seconds).
During those first 10 seconds HA's `value_template` tried to read missing
keys and logged `'dict object' has no attribute 'disk_usage'` etc.

Fixed in `lib/mqtt-bridge.py`: sys_metrics dict is now initialised with
`None` values before the loop, so all keys are always present in every
published payload. `None` serialises as JSON `null` which HA handles fine.

---

## Issue 14: Speaker audio — XMOS XVF-3510 requires specific audio format ✅

**Labels:** `audio`, `hardware`, `needs-testing`

**Description:**
The audio path on SJ201 is: **Pi I2S → XMOS XVF-3510 → TAS5806 → Speaker**

Audio does NOT go directly from Pi to TAS5806. XMOS sits in the middle.
The correct aplay format for XMOS output has not been confirmed — likely
48kHz stereo. Playing 16kHz mono (TTS format) may require resampling.

**Status:** Fixed.

Pi's I2S bus is half-duplex — direct ALSA playback crashes the kernel when LVA holds
the mic capture open. Fixed via PipeWire virtual sink (`sj201-output.conf`) that owns
`plughw:CARD=sj201,DEV=0` and multiplexes capture + playback safely. Audio format is
48kHz stereo S32_LE (plughw auto-converts). See `docs/SATELLITE_SETUP.md`.

---

## Issue 15: Wake word detection — verified working ✅

**Labels:** `audio`, `lva`, `needs-testing`

**Description:**
Wake word detection works when tested directly against the OWW service
(score 0.96 on okay_nabu.wav test file). However end-to-end detection via
LVA + microphone has not been confirmed working.

**Status:** Fixed. LVA with PipeWire virtual source `SJ201 ASR (VF_ASR_L)` gives RMS~500+,
resulting in reliable OWW detection (prob > 0.5 on "Ok Nabu"). Full pipeline
idle→listening→processing→responding confirmed working.

---

## Issue 16: python-mpv end-file callback freezes on aarch64/Python 3.13 with PipeWire ✅

**Labels:** `audio`, `lva`, `fixed`

**Status:** Fixed.

With the generic `pipewire` audio device, `python-mpv`'s `end-file` callback never
fires — MPV opens, loads the file (duration visible), but playback position freezes
at 0.021s indefinitely. This caused LVA to hang after wake word detection.

Root cause: PipeWire AO in mpv v0.40.0 has a thread-loop interaction issue on aarch64
that prevents the stream from advancing. Using a named PipeWire sink
(`pipewire/sj201-output`, created by `sj201-output.conf`) works correctly.

---

## Issue 17: LVA pipeline not set after first ESPHome discovery ⚠️

**Labels:** `lva`, `ha-integration`, `needs-documentation`

**Description:**
When LVA is first discovered by HA as an ESPHome device, the Assist pipeline
defaults to "preferred" (HA's default pipeline). If you want a specific pipeline
(e.g. Claude, local Whisper+Piper), you must set it manually.

**Workaround:**
```bash
# Via HA service call
curl -X POST http://<HA_IP>:8123/api/services/select/select_option \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "select.<device>_assistant", "option": "Claude"}'
```
Or in HA UI: Settings → Voice Assistants → your device → select pipeline.

---

## Issue 18: mark2-satellite-setup.sh does not verify PipeWire devices after install ⚠️

**Labels:** `enhancement`, `audio`

**Description:**
After installing PipeWire configs and restarting PipeWire, the setup script does not
verify that `SJ201 ASR (VF_ASR_L)` and `SJ201 Speaker` are visible in `wpctl status`.
If PipeWire fails to load the configs (e.g. due to a syntax error or missing ALSA device),
the failure is silent and LVA will use wrong audio devices.

**Fix needed:**
Add a post-install check: `wpctl status | grep -q "SJ201 ASR" || warn "PipeWire ASR source not found"`

---

## Issue 19: LVA service starts before PipeWire virtual devices are ready ⚠️

**Labels:** `audio`, `lva`, `boot`

**Description:**
On some boots, LVA starts before wireplumber has fully loaded the PipeWire
virtual sinks/sources from `pipewire.conf.d/`. This causes LVA to fall back
to the default PipeWire device (which freezes MPV) or the raw ALSA device
(which crashes on concurrent capture+playback).

`lva.service` has `After=wireplumber.service` but wireplumber does not signal
readiness until the graph is fully set up.

**Workaround:**
If LVA fails to produce sound after boot, restart it:
```bash
systemctl --user restart lva
```

**Fix needed:**
Add `ExecStartPre=/bin/sh -c 'sleep 3'` or poll `wpctl status` for the named
devices before starting LVA.
