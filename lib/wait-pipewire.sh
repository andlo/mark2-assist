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
        exit 0
    fi
    sleep 1
done
echo "WARNING: PipeWire SJ201 devices not ready after 30s — starting LVA anyway"
exit 0
