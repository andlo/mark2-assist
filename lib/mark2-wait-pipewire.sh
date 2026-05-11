#!/bin/bash
# Wait for PipeWire to be ready before starting LVA
# Checks for the PipeWire socket and a working audio sink
# Timeout: 30 seconds

RUNTIME_DIR="/run/user/$(id -u)"
TIMEOUT=30
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check PipeWire socket exists
    if [ -S "${RUNTIME_DIR}/pipewire-0" ] && \
       pactl info &>/dev/null && \
       pactl list sinks short 2>/dev/null | grep -q "RUNNING\|IDLE\|SUSPENDED"; then
        exit 0
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

# Timeout — start LVA anyway, it will retry
exit 0
