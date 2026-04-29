#!/bin/bash
# Wait for PipeWire SJ201 virtual devices to appear (max 30s)
# Used as ExecStartPre in lva.service to avoid starting before audio is ready.
# wireplumber is Type=simple and gives no systemd ready notification,
# so we poll wpctl status instead.
for i in $(seq 1 30); do
    ASR=$(wpctl status 2>/dev/null | grep -c 'SJ201 ASR')
    SPK=$(wpctl status 2>/dev/null | grep -c 'SJ201 Speaker')
    if [ "$ASR" -gt 0 ] && [ "$SPK" -gt 0 ]; then
        echo "PipeWire SJ201 devices ready after ${i}s"
        # Set default volume to 60% at boot.
        # Read saved volume from config if available.
        CONFIG="${HOME}/.config/mark2/config"
        DEFAULT_VOL=0.6
        if [ -f "$CONFIG" ]; then
            SAVED=$(grep '^MARK2_VOLUME=' "$CONFIG" 2>/dev/null | cut -d= -f2 | tr -d '"')
            if [ -n "$SAVED" ]; then
                DEFAULT_VOL=$(echo "$SAVED / 100" | bc -l 2>/dev/null || echo "0.6")
            fi
        fi
        wpctl set-volume @DEFAULT_AUDIO_SINK@ "$DEFAULT_VOL" 2>/dev/null && \
            echo "Default volume set to ${DEFAULT_VOL}" || true
        exit 0
    fi
    sleep 1
done
echo "WARNING: PipeWire SJ201 devices not ready after 30s — starting LVA anyway"
exit 0
