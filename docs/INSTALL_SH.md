# install.sh — Architecture and Flow

`install.sh` is the main entry point. It orchestrates the full installation across
two reboots and manages resume logic, progress tracking and module selection.

---

## Design principles

1. **All questions upfront** — The installer asks all questions before doing any work.
   If something goes wrong later, the saved answers mean re-running starts from where
   it left off without re-asking questions.

2. **Resume after reboot** — Hardware setup requires a reboot. A hook in `~/.bash_profile`
   detects when to resume and continues the installation automatically.

3. **Idempotent steps** — Each step is guarded by `progress_is_done()`. Re-running the
   installer skips completed steps. This makes it safe to re-run after failures.

4. **Modules are standalone** — Each file in `modules/` can be run independently:
   `bash modules/leds.sh`. The `MARK2_MODULE_CONFIRMED=1` environment variable suppresses
   confirmation prompts when called from `install.sh`.

5. **Logging** — All output is logged to `~/.config/mark2/install.log` with timestamps.
   The screen shows only summary output; full package installation output goes to the log.

---

## Flow

```
install.sh
│
├── configure_upfront()
│   ├── Show banner (figlet + feature list)
│   ├── Module checklist (whiptail)
│   ├── HA URL (whiptail inputbox)
│   ├── HA Token (whiptail passwordbox, if needed)
│   ├── MQTT credentials (whiptail, if mqtt-sensors selected)
│   ├── Snapcast host (whiptail, if snapcast selected)
│   └── Confirmation summary (whiptail msgbox)
│
├── Step 1: Hardware Setup
│   ├── [if not done] run mark2-hardware-setup.sh
│   ├── install_resume_hook() → adds resume hook to ~/.bash_profile
│   └── sudo reboot
│
│   [reboot happens here]
│   [tty1 auto-login triggers .bash_profile]
│   [resume hook detects post-reboot state]
│   [install.sh --resume called automatically]
│
├── [Optional] Hardware Test
│   ├── ask_yes_no "Run hardware test now? (recommended)"
│   ├── [if yes] run mark2-hardware-test.sh
│   └── ask_yes_no "Continue with installation?"
│
├── Step 2: Satellite + Kiosk
│   ├── [if not done] run mark2-satellite-setup.sh
│   └── progress_set "satellite" "done"
│
├── Step 3: Optional Modules
│   ├── remove_resume_hook()  ← clean up .bash_profile
│   ├── [for each selected module]:
│   │   ├── MARK2_MODULE_CONFIRMED=1 bash modules/<name>.sh
│   │   └── progress_set "<name>" "done"
│   └── [done]
│
└── print_final_summary()
    └── sudo reboot (optional)
```

---

## Key functions

### `configure_upfront()`

Collects all user input before any installation begins. Uses whiptail dialogs
when running interactively, or reads from environment variables for non-interactive use.

The module checklist presents all optional modules grouped by category:
- **Display**: leds, face, overlay, screensaver
- **HA**: mqtt-sensors
- **Audio**: snapcast, airplay, mpd
- **Extra**: kdeconnect, usb-audio

Selected modules are saved to `SELECTED_MODULES` in `~/.config/mark2/config`.

### `install_resume_hook()` / `remove_resume_hook()`

The resume hook is a block appended to `~/.bash_profile` between
`# mark2-install-resume` markers:

```bash
# mark2-install-resume
if [ "$(tty)" = "/dev/tty1" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "Resuming mark2-assist installation..."
    cd /path/to/mark2-assist && ./install.sh --resume
fi
# mark2-install-resume-end
```

After the installation is complete `remove_resume_hook()` strips this block,
ensuring normal logins are not affected.

### `run_module()`

```bash
run_module "leds" "LED ring — SJ201 ring reacts to voice events"
```

Checks if the module is in `SELECTED_MODULES`. If yes, runs it with
`MARK2_MODULE_CONFIRMED=1` so the module skips its own confirmation prompt.
Errors are caught and reported as warnings rather than fatal failures.

### `print_progress()`

Shows a summary table of all installation steps and their status
(✓ done / ✗ failed / - skipped).

### Hardware test (post-reboot)

After hardware setup reboots, `install.sh` offers to run `mark2-hardware-test.sh`
before proceeding with satellite/kiosk installation. This catches hardware problems
early — a failed speaker or missing I2C device is better discovered now than after
a full satellite install.

The user can skip the test and continue directly. If the test reveals failures,
the user can exit the installer, fix the hardware, and re-run — the hardware step
is already marked `done` in progress so it won't re-run unnecessarily.

See [HARDWARE_TEST.md](HARDWARE_TEST.md) for full test documentation.

---

### `print_final_summary()`

Printed at the end of installation. Shows:
- Service status commands
- LVA ESPHome discovery instructions for HA
- **Trusted networks configuration block** — the exact YAML to add to HA's
  `configuration.yaml` for auto-login, with the device's actual IP address filled in

---

## Progress tracking

Progress is stored in `~/.config/mark2/install-progress`:
```
hardware=done
satellite=done
leds=done
mqtt-sensors=failed
```

`progress_is_done()` returns true if a step has status `done`.
`progress_set()` updates or adds a status line.

---

## Configuration file

`~/.config/mark2/config` stores all answers to prompts:
```bash
SELECTED_MODULES="leds face overlay screensaver mqtt-sensors"
HA_URL="http://192.168.1.100:8123"
HA_TOKEN="eyJhbGc..."
HA_WEATHER_ENTITY="weather.forecast_home"
MQTT_HOST="192.168.1.100"
MQTT_USER="mark2"
MQTT_PASS="secret"
MQTT_PORT="1883"
MARK2_IP="192.168.1.42"
```

The file is created with `chmod 600` since it contains the HA token.

---

## Running modules standalone

Any module can be run after installation:
```bash
bash modules/leds.sh           # Re-install LED module
bash modules/mqtt-sensors.sh   # Re-install MQTT sensors
```

Without `MARK2_MODULE_CONFIRMED=1` the module will ask for confirmation first.

To skip confirmation:
```bash
MARK2_MODULE_CONFIRMED=1 bash modules/leds.sh
```

---

## Non-interactive / scripted install

To run the installer without any prompts, pre-set all variables:
```bash
export HA_URL="http://192.168.1.100:8123"
export HA_TOKEN="your-token-here"
export MQTT_HOST="192.168.1.100"
export MQTT_USER="mark2"
export MQTT_PASS="secret"
export SELECTED_MODULES="leds face overlay screensaver mqtt-sensors"
./install.sh
```

---

## Final summary trusted_networks output

At the end of installation, `install.sh` prints the exact `configuration.yaml`
block needed for auto-login, with the device's real IP address:

```
=====================================================
 Home Assistant auto-login configuration
=====================================================

Add this to your HA configuration.yaml and restart HA:

homeassistant:
  auth_providers:
    - type: homeassistant
    - type: trusted_networks
      trusted_networks:
        - 192.168.1.42        ← your Mark II IP
      trusted_users:
        192.168.1.42:
          - <YOUR_USER_ID>    ← find in HA Settings → People → click user → URL
      allow_bypass_login: true

=====================================================
```

This makes it easy for users to set up auto-login without consulting the README.
