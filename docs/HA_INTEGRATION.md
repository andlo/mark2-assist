# Mark II Assist — Home Assistant Integration Spec

This document describes what a companion Home Assistant custom integration
(`hacs: mark2-assist`) should do to provide the full Mark II experience.

The integration is intentionally kept as a **separate repository** so it can
evolve independently and be installed via HACS without touching the Mark II
setup scripts.

---

## Overview

The integration bridges HA and the Mark II kiosk display. It:

1. Discovers Mark II devices on the network
2. Receives MQTT sensor data from the device
3. Pushes display content (images, text, weather cards) to the kiosk screen
4. Optionally hooks into Assist pipelines to enrich voice responses with visuals
5. Exposes HA services for automations to drive the display

---

## Device Discovery

Mark II devices publish an MQTT availability topic on connect:

```
mark2/<hostname>/availability  →  "online" / "offline"
```

The integration should listen for these and auto-create a device entry for
each hostname it sees, using the existing MQTT device payload from
auto-discovery (`homeassistant/sensor/<id>/config`).

---

## Display Content API

The kiosk page polls `/tmp/mark2-content.json` on the device every 500ms.
The integration pushes content by writing this file via SSH.

### Content format

```json
{
  "action": "show",
  "type": "image | weather | text | map",
  "title": "Optional heading",
  "text": "Optional body text",
  "image_url": "https://...",
  "image_data": "data:image/jpeg;base64,...",
  "duration": 15
}
```

`duration` is in seconds. `0` means the panel stays until dismissed manually
(touch or explicit dismiss action). Default is 15 seconds.

To dismiss:
```json
{ "action": "dismiss" }
```

### Delivery method

The integration writes the JSON file to the Mark II device via one of:

- **SSH** — `ssh <user>@<ip> "cat > /tmp/mark2-content.json"` (simplest, uses existing SSH key)
- **Local HTTP** — a small Flask/aiohttp server on Mark II listens on port 8765 for POST requests (more robust, no SSH needed)

The SSH approach requires the user to have SSH key authentication set up.
The HTTP approach requires installing a small service on Mark II (could be
added as an optional module `modules/content-server.sh`).

**Recommended:** Start with SSH, add HTTP server as optional upgrade.

---

## HA Services

The integration should expose these HA services:

### `mark2_assist.show_content`

Show arbitrary content on the kiosk screen.

```yaml
service: mark2_assist.show_content
target:
  device_id: abc123
data:
  title: "Vejret i morgen"
  text: "18°C og delvist skyet. Vind 4 m/s fra vest."
  image_url: "https://openweathermap.org/img/wn/02d@2x.png"
  duration: 12
```

### `mark2_assist.dismiss_content`

Dismiss the content panel.

```yaml
service: mark2_assist.dismiss_content
target:
  device_id: abc123
```

### `mark2_assist.set_face_state`

Override the face animation state (useful for automations).

```yaml
service: mark2_assist.set_face_state
target:
  device_id: abc123
data:
  state: "speak"   # idle | wake | listen | think | speak | error
```

Delivered by writing to `/tmp/mark2-face-event.json` on the device.

---

## Assist Pipeline Hook (advanced)

To show visuals when a user asks a question via voice, the integration can
hook into the Assist pipeline using a custom conversation agent or a
post-response automation.

### Option A — Automation approach (simple)

An HA automation listens for `assist_pipeline` events and triggers a
webhook or script that:

1. Parses the intent/response text
2. Decides what to show (weather → fetch weather image, etc.)
3. Calls `mark2_assist.show_content`

```yaml
automation:
  trigger:
    platform: event
    event_type: assist_pipeline.run.finish
  action:
    service: mark2_assist.show_content
    data:
      title: "{{ trigger.event.data.tts_output.message[:60] }}"
      duration: 10
```

### Option B — Custom conversation agent (full)

A custom conversation agent (implementing `async_process`) can:

1. Forward the query to Claude/OpenAI
2. Parse the response for display intent (weather, image search, etc.)
3. Return the TTS text to Assist
4. Simultaneously push display content to the Mark II

This is the most powerful approach and allows the Mark II to show rich
content that matches what is being spoken. It requires a separate
`conversation` platform implementation.

The response from the LLM could include a structured block:

```
[DISPLAY]
title: Vejret i dag
image_url: https://...
text: 18 grader og delvist skyet
duration: 12
[/DISPLAY]

Der er 18 grader i dag og delvist skyet...
```

The integration strips the `[DISPLAY]` block before sending TTS,
and sends the display payload to the Mark II separately.

---

## Content Types

The kiosk content panel currently supports:

| Type | Fields | Notes |
|------|--------|-------|
| `image` | `image_url` or `image_data` | JPEG/PNG, shown full width |
| `text` | `title`, `text` | Plain text, no markdown |
| `weather` | `title`, `text`, `image_url` | Weather icon + summary |

Future content types to consider:

- `map` — show a map tile centered on a location
- `camera` — show a live camera snapshot from HA
- `chart` — show a simple sensor graph

---

## MQTT Sensors (read-only)

The integration reads these MQTT topics published by `mark2-assist`:

```
mark2/<hostname>/state     →  JSON with all sensor values
mark2/<hostname>/availability  →  online / offline
```

State payload example:
```json
{
  "lva_state": "idle",
  "mpd_state": "play",
  "mpd_track": "Wish You Were Here",
  "mpd_artist": "Pink Floyd",
  "mpd_volume": 72,
  "cpu_temp": 48.2,
  "cpu_usage": 12.4,
  "memory_usage": 31.0,
  "disk_usage": 18
}
```

These are already handled by HA's built-in MQTT integration via
auto-discovery. The custom integration does not need to re-implement
sensor reading — it can simply reference the entities by device.

---

## Configuration

Minimum required config (config flow):

```yaml
mark2_assist:
  devices:
    - host: 192.168.1.37
      name: "Mark II Stue"
      ssh_user: <mark2_user>   # the user running the Mark II kiosk
      ssh_key: /config/.ssh/mark2_rsa   # optional, falls back to password
```

Or auto-discovered via MQTT (preferred — no manual IP needed).

---

## Suggested Repository Structure

```
custom_components/mark2_assist/
    __init__.py
    config_flow.py          # UI config flow, discovers via MQTT
    const.py
    device.py               # Mark2Device class (SSH + MQTT)
    services.py             # show_content, dismiss, set_face_state
    sensor.py               # Optional: wrap MQTT sensors under this integration
    conversation.py         # Optional: custom conversation agent (LLM hook)
    manifest.json
    strings.json
hacs.json
README.md
```

---

## Related

- Mark II Assist (this repo): https://github.com/andlo/mark2-assist
- Wyoming Satellite: https://github.com/rhasspy/wyoming-satellite
- HA Custom Components: https://developers.home-assistant.io/docs/creating_component_index
- HA Conversation agents: https://developers.home-assistant.io/docs/intent_conversation_api
