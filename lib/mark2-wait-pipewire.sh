#!/bin/bash
# Wait for PipeWire SJ201 audio nodes to be ready before starting LVA
# Uses pw-cli which works with pro-audio profile (pactl doesn't show these nodes)

TIMEOUT=30
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    if pw-cli list-objects Node 2>/dev/null | grep -q "alsa_output.platform-soc_sound.pro-output-0"; then
        exit 0
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

# Timeout — start LVA anyway, it will handle reconnection
exit 0
