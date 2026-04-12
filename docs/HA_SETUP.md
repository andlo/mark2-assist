# Home Assistant Setup for Mark II

This document covers everything needed to set up Home Assistant for Mark II:
creating a dedicated user, configuring trusted network auto-login, and
installing the touch-optimised dashboard.

---

## Overview

The recommended HA setup for Mark II consists of:

1. **A dedicated `mark2` user** — logs in automatically via trusted network,
   sees only the Mark II dashboard, cannot change HA settings
2. **Trusted network auto-login** — Mark II's IP is whitelisted so it logs
   in without a password prompt on the touchscreen
3. **Mark II dashboard** — 800×480 touch-optimised, 4-column grid layout
   with clock, weather, media player, lights, scenes, and presence

---

## Step 1 — Create the mark2 user

1. In HA go to **Settings → People → Users** (tab at top)
2. Click **Add User**
3. Fill in:
   - Display name: `Mark II`
   - Username: `mark2`
   - Password: something strong (it will only be used as fallback)
   - **Uncheck** "Can login" if you want a device-only account
     (leave checked so trusted network login works)
   - **Uncheck** "Administrator"
4. Click **Create**

---

## Step 2 — Create the Mark II dashboard

1. In HA go to **Settings → Dashboards**
2. Click **Add Dashboard**
3. Fill in:
   - Title: `Mark II`
   - URL slug: `mark2`
   - Icon: `mdi:speaker`
   - **Uncheck** "Show in sidebar" (optional — keeps it clean for other users)
4. Click **Create**
5. Open the new dashboard, click **⋮ → Edit dashboard → Raw configuration editor**
6. Select all and replace with the YAML from `docs/mark2-dashboard.yaml`
7. Click **Save**

---

## Step 3 — Set Mark II dashboard as default for the mark2 user

1. Log out of your admin account (or open incognito)
2. Log in as `mark2`
3. Go to **Profile** (bottom left) → **Default Dashboard** → select **Mark II**
4. Log out and log back in as your admin account

---

## Step 4 — Configure trusted network auto-login

This allows Mark II to log in automatically without entering a password.
The `trusted_networks` provider grants passwordless access from a specific IP.

Edit `/config/configuration.yaml` (use Studio Code Server or File Editor add-on):

```yaml
homeassistant:
  auth_providers:
    - type: homeassistant          # Keep first — used for all other logins
    - type: trusted_networks
      trusted_networks:
        - 192.168.65.37            # Mark II's exact IP address
      trusted_users:
        192.168.65.37:             # Same IP
          - USER_ID_FOR_MARK2      # See below for how to find this
      allow_bypass_login: true
```

**How to find the mark2 user ID:**
In HA go to **Settings → People → Users**, click the `mark2` user.
The URL will be something like `/config/users/edit/abc123def456` —
the last part (`abc123def456`) is the user ID.

**Restart HA** after saving configuration.yaml.

> **Security note:** `trusted_networks` with `allow_bypass_login: true` grants
> passwordless access from that specific IP only. Using the exact device IP
> (not a whole subnet like `192.168.65.0/24`) limits exposure to Mark II only.
> Always keep `- type: homeassistant` first so other devices still require a password.

---

## Step 5 — Set the dashboard URL in mark2-assist

If the `mark2` user has the Mark II dashboard set as their default dashboard
(Step 3), you can simply use the base HA URL — HA will redirect automatically
to the default dashboard after login:

```
HA_URL=http://192.168.65.200:8123
```

If you prefer to hardcode the dashboard path (e.g. you skipped Step 3):

```
HA_URL=http://192.168.65.200:8123/lovelace/mark2
```

Set this during install, or afterwards in `~/.config/mark2/config`,
or by re-running the satellite setup:
```bash
cd ~/mark2-assist
./mark2-satellite-setup.sh
```

---

## Dashboard HACS requirements

The dashboard uses these custom cards — install via HACS before pasting the YAML:

| Card | HACS search |
|------|-------------|
| Mushroom Cards | `mushroom` |
| layout-card | `layout-card` |
| card-mod | `card-mod` |

Install HACS: https://hacs.xyz/docs/use/download/download/

---

## Dashboard entity customisation

After pasting the dashboard YAML, update these entity IDs to match your setup:

| Placeholder | Replace with |
|-------------|-------------|
| `weather.forecast_home` | Your weather entity |
| `light.living_room` | Main light in the room where Mark II lives |
| `media_player.mark2` | Mark II media player (MPD or Music Assistant) |
| `person.andreas_lorensen` | Your person entity |
| `person.sonia` | Second person (or remove the card) |
| `scene.good_night` | Your good night scene |
| `scene.good_morning` | Your good morning scene |
| `input_boolean.mark2_dnd` | Create this helper or replace with another toggle |
| `climate.living_room` | Thermostat in the room where Mark II lives |

**To create `input_boolean.mark2_dnd`:**
Settings → Helpers → Add Helper → Toggle
Name: `Mark2 Do Not Disturb`, Entity ID: `input_boolean.mark2_dnd`

---

## Verifying auto-login works

After reboot, the Mark II touchscreen should open directly to the dashboard
without showing a login screen. If it still shows login:

1. Verify the IP in `trusted_networks` matches `hostname -I` on Mark II
2. Verify HA was restarted after editing configuration.yaml
3. Check HA logs: Settings → System → Logs → search `trusted`
4. Verify the user ID in `trusted_users` matches the mark2 user
