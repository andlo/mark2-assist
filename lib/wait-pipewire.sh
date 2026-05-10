#!/bin/bash
# Wait for SJ201 microphone to be available via PipeWire/PulseAudio.
# With module-alsa-source approach, the source appears as "ALSA Source on hw:sj201,1"
# in wpctl status — not as pro-input-1.
CONFIG="${HOME}/.config/mark2/config"
DEFAULT_VOL=0.6
for i in $(seq 1 60); do
    if wpctl status 2>/dev/null | grep -q 'ALSA Source on hw:sj201'; then
        echo "SJ201 mic ready after ${i}s"
        if [ -f "$CONFIG" ]; then
            SAVED=$(grep '^MARK2_VOLUME=' "$CONFIG" 2>/dev/null | cut -d= -f2 | tr -d '"')
            [ -n "$SAVED" ] && DEFAULT_VOL=$(echo "$SAVED / 100" | bc -l 2>/dev/null || echo "0.6")
        fi
        wpctl set-volume @DEFAULT_AUDIO_SINK@ "$DEFAULT_VOL" 2>/dev/null || true
        exit 0
    fi
    sleep 1
done
echo "WARNING: SJ201 mic not ready after 60s — starting LVA anyway"
exit 0
