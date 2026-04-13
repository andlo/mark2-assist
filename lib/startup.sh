#!/bin/bash
# Weston session startup script.
# Called by: weston --shell=kiosk -- ~/startup.sh
# Weston stays alive as long as this script is running.
exec >> /tmp/mark2-startup.log 2>&1
echo "[$(date)] startup.sh starting"
"${HOME}/kiosk.sh" &
# Keep running so Weston does not exit
wait
