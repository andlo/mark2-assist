# The History of Mark II, Mycroft, OVOS and Home Assistant Assist

## The Mycroft Mark II

The Mycroft Mark II was a voice assistant device designed and produced by
[Mycroft AI](https://mycroft.ai/) — an open source voice assistant company founded in 2015
in Kansas City, Missouri. The Mark II was funded through a Kickstarter campaign in 2018,
raising over $1 million from backers who believed in the promise of a privacy-respecting,
open source alternative to Amazon Echo and Google Home.

The Mark II hardware is a custom-designed Raspberry Pi carrier board. The final production
version uses a Raspberry Pi 4 Compute Module, though the public-facing retail version
shipped with a Raspberry Pi 4 Model B. The board includes:

- **SJ201** — a custom audio board with an XMOS XVF-3510 far-field microphone array
  (6 mics arranged in a circular pattern), a TAS5806 Class-D amplifier for the speaker,
  and an APA102 LED ring for visual feedback
- **Waveshare 4.3" DSI touchscreen** — 800×480 resolution, connected via the DSI ribbon
  cable port on the Raspberry Pi
- **Hardware buttons** — volume up/down and action button, connected via SJ201

The Mark II shipped to Kickstarter backers in 2022, years behind schedule and after
considerable turmoil. The hardware was well-regarded — the microphone array has excellent
far-field pickup and the build quality is solid. The software, however, was perpetually
unfinished.

## Mycroft AI's Demise

Mycroft AI never achieved financial sustainability. Despite multiple funding rounds and
a dedicated community, the company struggled to compete with well-funded alternatives
from Amazon, Google and Apple. In early 2023 Mycroft AI announced it was ceasing
operations and [open-sourcing all remaining code](https://mycroft.ai/blog/mycroft-ai-update/).

This left Mark II owners with working hardware but an orphaned software stack. The
Mycroft "MIMIC" TTS, Neon skills framework and the Mycroft AI backend all went offline.

## OpenVoiceOS (OVOS)

Before Mycroft's closure, a community fork called
[OpenVoiceOS (OVOS)](https://openvoiceos.org/) had already emerged. OVOS maintained
compatibility with Mycroft skills but moved to a more modular architecture. When Mycroft
shut down OVOS became the primary continuation of the open source voice assistant project
for Mark II hardware.

OVOS provides a full voice assistant stack: wake word detection, speech-to-text,
natural language understanding, skill execution, text-to-speech. It can run entirely
locally or connect to cloud services for STT/TTS. The OVOS community maintains drivers
and overlays for the SJ201 hardware, including the
[VocalFusionDriver](https://github.com/OpenVoiceOS/VocalFusionDriver) kernel module and
the SJ201 initialisation scripts that mark2-assist also uses.

## Home Assistant Assist

Meanwhile [Home Assistant](https://www.home-assistant.io/) — the leading open source
home automation platform — had been building its own local voice assistant capabilities.

In 2022 Home Assistant introduced **Assist** — a pipeline for local voice control of
smart home devices. Assist uses:

- **Wyoming Protocol** — a simple TCP-based protocol for streaming audio and events
  between voice components, developed specifically for HA
- **Piper** — fast, high-quality local text-to-speech
- **Whisper** — OpenAI's speech-to-text model, running locally via faster-whisper
- **openWakeWord** — wake word detection running on-device

The key insight of the Wyoming approach is separation of concerns: each component
(wake word detection, speech-to-text, the satellite device itself) is a separate process
communicating over TCP sockets. This makes it easy to run wake word detection on the
satellite device (the Mark II) while running the heavier STT/TTS workloads on the HA
server — which typically has more CPU and RAM.

## The Wyoming Satellite

[wyoming-satellite](https://github.com/rhasspy/wyoming-satellite) is a lightweight
Python program that turns any microphone-equipped device into a voice satellite for
Home Assistant. It:

1. Connects to a Wyoming wake word service (openWakeWord) running locally
2. Listens for the wake word
3. On detection, streams microphone audio over TCP to the HA server
4. Receives synthesized speech audio back and plays it through the speaker
5. Reports events (detecting, detected, streaming, etc.) that can drive LED/face animations

The satellite is designed to be resource-efficient — it runs comfortably on a Raspberry Pi
Zero 2 W. The Mark II is considerably more powerful, which means it can also run
wake word detection locally without impacting performance.


## Linux Voice Assistant — The Next Generation

In January 2026 the wyoming-satellite project was deprecated by Nabu Casa in favour of
a new approach: [linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant)
(LVA), developed by the [Open Home Foundation](https://www.openhomefoundation.org/).

Where Wyoming used a custom TCP protocol, LVA uses the **ESPHome protocol** — the same
protocol used by HA Voice Preview Edition hardware. This brings the Mark II onto exactly
the same integration path as purpose-built HA voice hardware.

LVA provides significant improvements over Wyoming Satellite:

- **Single service** — wake word detection (OpenWakeWord or MicroWakeWord) is built in,
  no separate wyoming-openwakeword process needed
- **Timer support** — set and cancel timers by voice ("set a timer for 10 minutes")
- **Announcement support** — HA can push announcements through the satellite speaker
- **Continue conversation** — after responding, LVA automatically listens again without
  needing to say the wake word
- **Media player entity** — exposed to HA for media control
- **Auto-discovery** — HA finds it via Zeroconf as an ESPHome device, no manual
  integration configuration needed

mark2-assist migrated from Wyoming Satellite to LVA in April 2026 (commit `8ff3823`).

## mark2-assist

mark2-assist was created in 2025 to combine the best of both worlds:

- The excellent Mark II hardware (microphone array, speaker, touchscreen, LED ring)
- The mature and actively developed Home Assistant Assist ecosystem

Rather than maintaining a full voice assistant stack (as OVOS does), mark2-assist
takes a minimal approach: install only what is needed to make the Mark II hardware work
as an HA satellite. The result is a system that:

- Boots in under 30 seconds to a full HA dashboard
- Responds to voice commands via HA Assist with sub-second wake word detection
- Shows rich visual feedback on the LED ring and animated face
- Stays up to date alongside HA without any separate software stack to maintain
- Is entirely local — no cloud services required

The driver code (SJ201 initialization, VocalFusion kernel module) is adapted from the
OVOS [ovos-installer](https://github.com/OpenVoiceOS/ovos-installer) Ansible roles,
with gratitude to the OVOS community for their hardware work.

## Technical decisions

### Why Weston instead of labwc?

During development, labwc (a Wayland compositor popular on Raspberry Pi OS) was
initially used for the kiosk display. However, Chromium 146 (as shipped in Debian
Trixie) does not correctly composite its render surface to the Wayland display when
using labwc on a Pi 4 with the vc4-kms-v3d driver. The root cause appears to be
in how labwc handles the wlr-layer-shell protocol combined with Chromium's use of
the EGL ANGLE renderer.

Weston, the reference Wayland compositor, works correctly with Chromium on this
hardware. Weston's `--shell=kiosk` provides a simple fullscreen kiosk experience
without any window decorations or taskbars.

### Why vc4-kms-v3d instead of vc4-fkms-v3d?

`vc4-fkms-v3d` (Fake/Firmware KMS) is deprecated on kernel 6.x. The "firmware"
in the name refers to the VideoCore GPU firmware handling the display pipeline —
on newer kernels this causes `No displays found` errors. `vc4-kms-v3d` (full KMS)
uses the kernel's DRM subsystem directly and is the correct overlay for Debian Trixie.


### Why Linux Voice Assistant instead of Wyoming Satellite?

Wyoming Satellite was deprecated by Nabu Casa in January 2026 and replaced by LVA.
Beyond following upstream, LVA offers several advantages for the Mark II specifically:

- The ESPHome protocol is the same used by HA Voice Preview Edition — tight HA integration
- Timers, announcements and continue-conversation work out of the box
- One service instead of two (no separate openWakeWord daemon)
- No port conflicts or mDNS quirks — ESPHome discovery is robust and well-tested in HA

The migration also required solving two Mark II-specific hardware challenges:

**Microphone signal level:** LVA uses `soundcard` (PipeWire/PulseAudio) for mic input.
PipeWire exposed only the raw `plughw:sj201,DEV=1` at 48kHz stereo (RMS~17), which is
too low for OWW. A PipeWire virtual source reading from ALSA's `VF_ASR_(L)` device
gives RMS~500+ — the same fix that was applied for Wyoming's `arecord` command.

**Half-duplex I2S bus:** Pi's I2S bus cannot support simultaneous capture and playback
at the ALSA driver level. When LVA holds the mic open and MPV attempts direct ALSA
playback, the kernel panics (system reboot). The fix is a PipeWire virtual sink that
owns the ALSA playback device — PipeWire's internal graph multiplexes both streams
without ALSA-level conflicts.

Additionally, `python-mpv`'s `end-file` callback never fires on aarch64/Python 3.13
with the generic `pipewire` device (MPV freezes at position 0.021s). Using the named
`pipewire/sj201-output` sink gives reliable callbacks.

### Why Wyoming instead of OVOS?

Wyoming is the native voice protocol of Home Assistant. Using it means:
- Tight integration with HA Assist pipelines, automations and the HA companion app
- Voice commands can trigger HA actions directly without an intermediate skill layer
- STT and TTS processing can be offloaded to the (typically more powerful) HA server
- Updates to HA's voice capabilities automatically benefit the Mark II

OVOS remains an excellent choice if you want a standalone voice assistant with
skills, but for a Mark II that is primarily a smart home controller the Wyoming
approach is simpler and more integrated.

---

*mark2-assist is not affiliated with Mycroft AI, OpenVoiceOS or Nabu Casa.*
*Home Assistant is a project of the Open Home Foundation.*
