```
      - USER_ID_FOR_MARK2
  allow_bypass_login: true
- type: homeassistant
```

```

**Restart HA** after saving configuration.yaml.

> **Security note:** `allow_bypass_login: true` grants passwordless access from those exact IPs only. Using specific device IPs (not a whole subnet like `192.168.1.0/24`) limits exposure to Mark II devices only. Always keep `- type: homeassistant` as the first provider so all other devices still require a password.
```
