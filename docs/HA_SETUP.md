# Home Assistant Setup for Mark II

This document covers everything needed to set up Home Assistant for Mark II:
allowing the HA dashboard to be embedded in the kiosk, creating a dedicated
user, configuring trusted network auto-login, and installing the
touch-optimised dashboard.

---

## Overview

The recommended HA setup for Mark II consists of:

1. **`use_x_frame_options: false`** — required so the HA dashboard can load
   inside the Mark II kiosk (one line in configuration.yaml)
2. **A dedicated `mark2` user** — logs in automatically via trusted network,
   sees only the Mark II dashboard, cannot change HA settings
3. **Trusted network auto-login** — Mark II's IP is whitelisted so the
   touchscreen logs in without a password prompt
4. **Mark II dashboard** — 800×480 touch-optimised, 4-column grid layout
5. **Kiosk mode** — hides the HA header/sidebar, giving the full screen to cards

---

## Step 0 — Allow HA to be shown in the kiosk (required)

The Mark II kiosk displays the HA dashboard inside an iframe. By default,
Home Assistant sends `X-Frame-Options: SAMEORIGIN` which blocks this.

Add the following to `/config/configuration.yaml` and **restart HA**:

```yaml
http:
  use_x_frame_options: false
```

> **Security note:** This allows any page on your local network to embed
> your HA frontend in an iframe. It does not expose HA externally or
> remove authentication — users still need to be logged in. For most home
> setups this is perfectly safe, but if you expose HA externally (e.g. via
> Nabu Casa or a reverse proxy) you may want to consider the implications.

Without this setting the Mark II touchscreen will show a blank grey page
instead of your HA dashboard.

---

## Step 1 — HACS requirements

Install these via HACS before setting up the dashboard:

| Card | HACS search | Purpose |
|------|-------------|---------|
| Mushroom Cards | `mushroom` | Clean touch-friendly cards |
| layout-card | `layout-card` | CSS grid layout for 800×480 |
| card-mod | `card-mod` | Custom card CSS (clock size etc.) |
| Kiosk Mode | `kiosk-mode` | Hides HA header/sidebar on the device |

Install HACS: https://hacs.xyz/docs/use/download/download/

> **Why Kiosk Mode?** Chromium already runs in OS-level kiosk mode (no
> address bar, no tabs). But HA itself still shows its own header bar with
> hamburger menu, notifications, and user avatar — wasting ~50px on a 480px
> screen. The Kiosk Mode card hides this completely for the `mark2` user.

---

## Step 2 — Create the mark2 user

It is strongly recommended to create a dedicated HA user for Mark II rather
than using your admin account. This gives you clean separation between the
device and your personal account, and ensures the touchscreen always shows
the Mark II dashboard — never your personal default view.

1. In HA go to **Settings → People → Users** (tab at top)
2. Click **Add User**
3. Fill in:
   - Display name: `Mark II`
   - Username: `mark2`
   - Password: something strong (only used as fallback if trusted network fails)
   - Uncheck **Administrator**
4. Click **Create**
5. Note the user ID from the URL — you will need it in Step 4.
   The URL will look like `/config/users/edit/abc123def456` — the last part
   is the user ID.

> **Why a dedicated user?** With a separate `mark2` account you can set the
> Mark II dashboard as the default, configure kiosk mode to hide the header
> for this user only, and avoid the device ever landing on your personal HA view.

---

## Step 3 — Create the Mark II dashboard

1. In HA go to **Settings → Dashboards**
2. Click **Add Dashboard**
3. Fill in:
   - Title: `Mark II`
   - URL slug: `mark2`
   - Icon: `mdi:speaker`
   - Uncheck **Show in sidebar** (keeps it clean for other users)
4. Click **Create**
5. Open the new dashboard → **⋮ → Edit dashboard → Raw configuration editor**
6. Select all and replace with the YAML from `docs/mark2-dashboard.yaml`
7. Click **Save**

---

## Step 4 — Set Mark II dashboard as default for the mark2 user

1. Log out (or open an incognito window)
2. Log in as `mark2`
3. Go to **Profile** (bottom left) → **Default Dashboard** → select **Mark II**
4. Log out and log back in as your admin account

After this, the `mark2` user always lands directly on the Mark II dashboard.
The kiosk in `mark2-assist` can simply point to the base HA URL — HA redirects
automatically to the default dashboard after login:

```
HA_URL=http://192.168.1.x:8123
```

---

## Step 5 — Configure trusted network auto-login

This allows Mark II to log in automatically as the `mark2` user without
showing a password prompt on the touchscreen.

Edit `/config/configuration.yaml` (use Studio Code Server or File Editor add-on):

### Single device

```yaml
homeassistant:
  auth_providers:
    - type: homeassistant          # Keep first — used for all other logins
    - type: trusted_networks
      trusted_networks:
        - 192.168.1.x              # Mark II's exact IP address
      trusted_users:
        192.168.1.x:
          - USER_ID_FOR_MARK2      # The mark2 user ID from Step 1
      allow_bypass_login: true
```

### Multiple devices (e.g. nabu-1 and nabu-2)

All devices share the same `mark2` user and dashboard — just add each IP.
The devices are distinguished in HA by their hostname (set during install):

```yaml
homeassistant:
  auth_providers:
    - type: homeassistant
    - type: trusted_networks
      trusted_networks:
        - 192.168.1.10             # nabu-1
        - 192.168.1.11             # nabu-2
      trusted_users:
        192.168.1.10:
          - USER_ID_FOR_MARK2      # same mark2 user ID for all devices
        192.168.1.11:
          - USER_ID_FOR_MARK2
      allow_bypass_login: true
```

**Restart HA** after saving configuration.yaml.

> **Security note:** `allow_bypass_login: true` grants passwordless access
> from those exact IPs only. Using specific device IPs (not a whole subnet
> like `192.168.1.0/24`) limits exposure to Mark II devices only. Always
> keep `- type: homeassistant` as the first provider so all other devices
> still require a password.

---

## Step 6 — Configure Kiosk Mode for the mark2 user

After installing the Kiosk Mode HACS card, configure it **in your dashboard
YAML** — not in `configuration.yaml`. Kiosk Mode is a frontend plugin, not a
HA integration, so it has no `configuration.yaml` support.

Open your Mark II dashboard → **⋮ → Edit dashboard → Raw configuration editor**
and add a `kiosk:` block at the top level:

```yaml
title: Mark II
kiosk:
  user_settings:
    - users:
        - mark2
      hide_header: true
      hide_sidebar: true
views:
  ...
```

This hides the HA header and sidebar for the `mark2` user only, giving the
full 480px screen height to dashboard cards. Your admin account and other
users still see the normal HA interface.

> **Note:** Do NOT add `kiosk_mode:` to `configuration.yaml` — HA will report
> "Integration 'kiosk_mode' not found" because Kiosk Mode is not a HA
> integration. It is a Lovelace frontend plugin configured via dashboard YAML.

---

## Step 7 — Set the HA URL in mark2-assist

Since the `mark2` user has the Mark II dashboard as their default, the base
URL is sufficient — HA redirects automatically after login:

```
HA_URL=http://192.168.1.x:8123
```

Set this during install or afterwards in `~/.config/mark2/config`,
or re-run the satellite setup:

```bash
cd ~/mark2-assist
./mark2-satellite-setup.sh
```

---

## Dashboard entity customisation

After pasting the dashboard YAML, update these placeholders to match your setup:

| Placeholder | Replace with |
|-------------|-------------|
| `weather.forecast_home` | Your weather entity |
| `light.your_light` | Main light in the room where Mark II lives |
| `media_player.mark2` | Mark II media player (MPD or Music Assistant) |
| `climate.your_room` | Thermostat in the room where Mark II lives |
| `person.your_name` | Your person entity |
| `scene.good_night` | Your good night scene (or remove the card) |
| `scene.good_morning` | Your good morning scene (or remove the card) |
| `input_boolean.mark2_dnd` | Create as Helper (see below) or remove the card |

**To create `input_boolean.mark2_dnd`:**
Settings → Helpers → Add Helper → Toggle
Name: `Mark2 Do Not Disturb`, Entity ID: `input_boolean.mark2_dnd`

---

## Verifying auto-login works

After reboot, the Mark II touchscreen should open directly to the dashboard
without showing a login screen. If it still shows login:

1. Verify the IP in `trusted_networks` matches `hostname -I` on Mark II
2. Verify the user ID in `trusted_users` is the `mark2` user (not admin)
3. Verify HA was restarted after editing configuration.yaml
4. Check HA logs: Settings → System → Logs → search `trusted`
