#!/bin/bash
# =============================================================================
# mark2-hardware-test.sh
# Mycroft Mark II — Interactive hardware test suite
#
# Tests all Mark II hardware components and reports pass/fail for each.
# Run after mark2-hardware-setup.sh and a reboot to verify hardware works
# before proceeding with satellite/kiosk installation.
#
# Components tested:
#   1. SJ201 service        — firmware flashed and amp initialized
#   2. Audio devices        — ALSA sees SJ201 card for capture and playback
#   3. Microphone           — records audio and checks signal level
#   4. Speaker              — plays a test tone via SJ201 amplifier
#   5. Microphone → Speaker — records then plays back so you can verify
#   6. LED ring             — cycles through colors via I2C
#   7. Buttons              — detects volume up/down and action button presses
#   8. Touchscreen          — checks DSI display is detected by DRM
#   9. Backlight            — checks backlight control exists
#  10. I2C bus              — scans I2C bus for known SJ201 addresses
#  11. SPI bus              — checks /dev/spidev0.0 is accessible
#
# Usage:
#   chmod +x mark2-hardware-test.sh
#   ./mark2-hardware-test.sh
#
#   Non-interactive (skip manual checks):
#   ./mark2-hardware-test.sh --auto
# =============================================================================

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

check_not_root
setup_paths

# --- Parse flags ---
AUTO=false
for arg in "$@"; do
    [[ "$arg" == "--auto" ]] && AUTO=true
done

# --- Test result tracking ---
PASS=0
FAIL=0
SKIP=0
RESULTS=()

result() {
    local name="$1"
    local status="$2"   # PASS FAIL SKIP
    local detail="${3:-}"
    RESULTS+=("${status}|${name}|${detail}")
    case "$status" in
        PASS) PASS=$((PASS+1)); echo -e "  ${GREEN}✓ PASS${NC}  ${name}${detail:+ — ${detail}}" ;;
        FAIL) FAIL=$((FAIL+1)); echo -e "  ${RED}✗ FAIL${NC}  ${name}${detail:+ — ${detail}}" ;;
        SKIP) SKIP=$((SKIP+1)); echo -e "  ${YELLOW}· SKIP${NC}  ${name}${detail:+ — ${detail}}" ;;
    esac
}

pause() {
    if [ "$AUTO" = false ]; then
        echo ""
        read -rp "  Press Enter to continue..."
        echo ""
    fi
}

ask_result() {
    # ask_result "Did it work?" → returns 0 for yes, 1 for no
    local prompt="$1"
    if [ "$AUTO" = true ]; then
        echo -e "  ${YELLOW}[AUTO]${NC} Skipping manual check: ${prompt}"
        return 2  # skip
    fi
    echo ""
    read -rp "  ${prompt} [y/n/s=skip]: " ans
    case "${ans,,}" in
        y) return 0 ;;
        n) return 1 ;;
        *) return 2 ;;
    esac
}

# =============================================================================
# BANNER
# =============================================================================

clear
echo -e "${CYAN}"
echo '    __  ___           __      ______  ____  __ '
echo '   /  |/  /___ ______/ /__   /  _/  _/ __ \/ /'
echo '  / /|_/ / __ `/ ___/ //_/   / / / // / / / / '
echo ' / /  / / /_/ / /  / ,<    _/ /_/ // /_/ /_/  '
echo '/_/  /_/\__,_/_/  /_/|_|  /___/___/\____(_)   '
echo -e "${NC}"
echo -e "${BLUE}  Mark II Hardware Test Suite${NC}"
echo ""
echo "  This script tests all Mark II hardware components."
echo "  Some tests require you to listen/look at the device."
echo ""
if [ "$AUTO" = true ]; then
    echo -e "  ${YELLOW}Running in automatic mode — manual checks skipped${NC}"
fi
echo ""
echo -e "${CYAN}  Hardware:${NC}"
echo "  · Mycroft Mark II carrier board"
echo "  · Raspberry Pi 4 Model B"
echo "  · SJ201 (XMOS XVF-3510 mic array + TAS5806 amp)"
echo "  · Waveshare 4.3\" DSI 800×480 touchscreen"
echo ""

if [ "$AUTO" = false ]; then
    if ! ask_yes_no "Start hardware test?"; then
        echo "Cancelled."
        exit 0
    fi
fi

echo ""

# =============================================================================
# TEST 1: SJ201 service
# =============================================================================

section "1. SJ201 Service"

if systemctl --user is-active sj201.service &>/dev/null; then
    result "sj201.service" PASS "active (firmware loaded)"
else
    STATUS=$(systemctl --user show sj201.service -p ActiveState --value 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "failed" ]; then
        result "sj201.service" FAIL "service failed — run: systemctl --user status sj201"
    else
        result "sj201.service" FAIL "not active (status: ${STATUS})"
    fi
fi

# Check XVF3510 firmware file exists
if [ -f "/opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin" ]; then
    result "XVF3510 firmware file" PASS
else
    result "XVF3510 firmware file" FAIL "not found in /opt/sj201/"
fi

# Check VocalFusion kernel module loaded
if lsmod 2>/dev/null | grep -q "vocalfusion"; then
    result "vocalfusion kernel module" PASS "loaded"
else
    result "vocalfusion kernel module" FAIL "not loaded — check dmesg for errors"
fi

# =============================================================================
# TEST 2: Audio devices
# =============================================================================

section "2. Audio Devices (ALSA)"

# Check SJ201 appears as ALSA capture device
if arecord -l 2>/dev/null | grep -qi "sj201"; then
    CARD_INFO=$(arecord -l 2>/dev/null | grep -i "sj201" | head -1 | xargs)
    result "SJ201 capture device" PASS "${CARD_INFO}"
else
    result "SJ201 capture device" FAIL "not found in arecord -l"
fi

# Check SJ201 appears as ALSA playback device
if aplay -l 2>/dev/null | grep -qi "sj201"; then
    CARD_INFO=$(aplay -l 2>/dev/null | grep -i "sj201" | head -1 | xargs)
    result "SJ201 playback device" PASS "${CARD_INFO}"
else
    result "SJ201 playback device" FAIL "not found in aplay -l"
fi

# Find the correct device names
MIC_DEV=$(arecord -L 2>/dev/null | grep -i "plughw.*sj201\|plughw.*CARD=sj201" | head -1)
if [ -z "$MIC_DEV" ]; then
    MIC_DEV="plughw:CARD=sj201,DEV=1"
fi
SPK_DEV=$(aplay -L 2>/dev/null | grep -i "plughw.*sj201\|plughw.*CARD=sj201" | head -1)
if [ -z "$SPK_DEV" ]; then
    SPK_DEV="plughw:CARD=sj201,DEV=0"
fi

result "Mic device" PASS "${MIC_DEV}"
result "Speaker device" PASS "${SPK_DEV}"

# =============================================================================
# TEST 3: Microphone — record and check signal level
# =============================================================================

section "3. Microphone"
echo "  Recording 3 seconds... Say something or clap your hands!"
echo ""

RECFILE="/tmp/mark2-mic-test.wav"
if arecord -D "${MIC_DEV}" -r 16000 -c 1 -f S16_LE -d 3 "$RECFILE" 2>/dev/null; then
    # Check signal level using Python
    LEVEL=$(python3 - "$RECFILE" << 'PYEOF'
import sys, wave, struct, math
try:
    with wave.open(sys.argv[1]) as f:
        data = f.readframes(f.getnframes())
    samples = struct.unpack('<' + 'h' * (len(data)//2), data)
    rms = math.sqrt(sum(s*s for s in samples) / len(samples)) if samples else 0
    peak = max(abs(s) for s in samples) if samples else 0
    print(f"{rms:.0f}/{peak}")
except Exception as e:
    print(f"0/0")
PYEOF
)
    RMS=$(echo "$LEVEL" | cut -d/ -f1)
    PEAK=$(echo "$LEVEL" | cut -d/ -f2)

    if [ "${RMS:-0}" -gt 200 ]; then
        result "Microphone signal" PASS "RMS=${RMS} Peak=${PEAK} (good level)"
    elif [ "${RMS:-0}" -gt 50 ]; then
        result "Microphone signal" PASS "RMS=${RMS} Peak=${PEAK} (low — speak louder)"
    else
        result "Microphone signal" FAIL "RMS=${RMS} Peak=${PEAK} (no signal — check SJ201)"
    fi
else
    result "Microphone record" FAIL "arecord failed — device busy or not available"
fi

# =============================================================================
# TEST 4: Speaker — play test tone
# =============================================================================

section "4. Speaker"
echo "  Playing test tone (440 Hz beep) through SJ201 amplifier..."
echo "  Listen for a beep from the Mark II speaker."
echo ""

# Generate a simple 440Hz test tone using Python and pipe to aplay
TONEFILE="/tmp/mark2-tone-test.wav"
python3 - "$TONEFILE" << 'PYEOF'
import sys, wave, struct, math
rate = 22050
duration = 1.5
freq = 440
samples = [int(32767 * 0.5 * math.sin(2 * math.pi * freq * i / rate))
           for i in range(int(rate * duration))]
fade = int(rate * 0.1)
for i in range(fade):
    samples[i] = int(samples[i] * i / fade)
    samples[-(i+1)] = int(samples[-(i+1)] * i / fade)
with wave.open(sys.argv[1], 'w') as f:
    f.setnchannels(1)
    f.setsampwidth(2)
    f.setframerate(rate)
    f.writeframes(struct.pack('<' + 'h' * len(samples), *samples))
PYEOF

if aplay -D "${SPK_DEV}" "$TONEFILE" 2>/dev/null; then
    case $(ask_result "Did you hear a beep from the speaker?") in
        0) result "Speaker playback" PASS "tone heard" ;;
        1) result "Speaker playback" FAIL "no sound — check TAS5806 amp init" ;;
        2) result "Speaker playback" SKIP "manual check skipped" ;;
    esac
else
    result "Speaker playback" FAIL "aplay failed"
fi

# =============================================================================
# TEST 5: Microphone → Speaker roundtrip
# =============================================================================

section "5. Microphone → Speaker Roundtrip"
echo "  Recording 3 seconds, then playing back."
echo "  Say something clearly (e.g. 'testing testing one two three')"
echo ""

ROUNDFILE="/tmp/mark2-roundtrip.wav"
if arecord -D "${MIC_DEV}" -r 16000 -c 1 -f S16_LE -d 3 "$ROUNDFILE" 2>/dev/null; then
    echo "  Playing back your recording..."
    aplay -D "${SPK_DEV}" "$ROUNDFILE" 2>/dev/null || true
    case $(ask_result "Did you hear your voice played back?") in
        0) result "Mic → Speaker roundtrip" PASS ;;
        1) result "Mic → Speaker roundtrip" FAIL "check mic and speaker separately" ;;
        2) result "Mic → Speaker roundtrip" SKIP ;;
    esac
else
    result "Mic → Speaker roundtrip" FAIL "recording failed"
fi

# =============================================================================
# TEST 6: LED ring
# =============================================================================

section "6. LED Ring"

if ! command -v python3 &>/dev/null; then
    result "LED ring" SKIP "python3 not available"
else
    echo "  Testing LED ring — cycling through colors via I2C..."
    echo "  Watch the LED ring on the Mark II."
    echo ""

    python3 - << 'PYEOF'
import time, sys
try:
    import smbus2
    bus = smbus2.SMBus(1)
    I2C_ADDR = 0x04
    NUM_LEDS = 12

    def set_leds(r, g, b):
        payload = [r, g, b] * NUM_LEDS
        bus.write_i2c_block_data(I2C_ADDR, 0x00, payload[:32])
        if len(payload) > 32:
            bus.write_i2c_block_data(I2C_ADDR, 0x20, payload[32:])

    print("  Red...")
    set_leds(80, 0, 0); time.sleep(0.5)
    print("  Green...")
    set_leds(0, 80, 0); time.sleep(0.5)
    print("  Blue...")
    set_leds(0, 0, 80); time.sleep(0.5)
    print("  White...")
    set_leds(40, 40, 40); time.sleep(0.5)
    print("  Off.")
    set_leds(0, 0, 0)
    bus.close()
    print("LED_OK")
except ImportError:
    print("LED_SKIP:smbus2 not installed")
except Exception as e:
    print(f"LED_FAIL:{e}")
PYEOF

    LED_RESULT=$(python3 - 2>/dev/null << 'PYEOF'
try:
    import smbus2
    bus = smbus2.SMBus(1)
    bus.write_i2c_block_data(0x04, 0x00, [0]*32)
    bus.close()
    print("OK")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)

    if [[ "$LED_RESULT" == "OK" ]]; then
        case $(ask_result "Did the LED ring cycle through red/green/blue/white?") in
            0) result "LED ring" PASS "I2C write OK, colors seen" ;;
            1) result "LED ring" FAIL "I2C write OK but no visible colors" ;;
            2) result "LED ring" SKIP ;;
        esac
    elif [[ "$LED_RESULT" == SKIP* ]]; then
        result "LED ring" SKIP "${LED_RESULT#SKIP:}"
    else
        result "LED ring" FAIL "${LED_RESULT#FAIL:}"
    fi
fi

# =============================================================================
# TEST 7: Hardware buttons
# =============================================================================

section "7. Hardware Buttons"

if [ "$AUTO" = true ]; then
    result "Hardware buttons" SKIP "skipped in auto mode"
else
    echo "  Testing hardware buttons (volume up, volume down, action)."
    echo "  Press each button when prompted."
    echo ""

    # Check if button events are available via evdev
    EVDEV_DEV=$(find /dev/input -name 'event*' 2>/dev/null | while read -r dev; do
        udevadm info "$dev" 2>/dev/null | grep -qi "sj201\|button\|gpio" && echo "$dev" && break
    done)

    if [ -n "$EVDEV_DEV" ]; then
        result "Button input device" PASS "$EVDEV_DEV"
        echo "  Input device found: $EVDEV_DEV"
        echo "  Press the ACTION button (center) within 5 seconds..."
        if timeout 5 bash -c "evtest '$EVDEV_DEV' 2>/dev/null | grep -m1 'KEY_'" 2>/dev/null | grep -q "KEY_"; then
            result "Button press detected" PASS
        else
            result "Button press detected" FAIL "no event received — check sj201-buttons-overlay"
        fi
    else
        # Fallback: check GPIO input events
        if ls /dev/input/event* &>/dev/null; then
            echo "  Input devices found: $(ls /dev/input/event* | xargs)"
            case $(ask_result "Did button presses cause any reaction?") in
                0) result "Hardware buttons" PASS ;;
                1) result "Hardware buttons" FAIL "no button events" ;;
                2) result "Hardware buttons" SKIP ;;
            esac
        else
            result "Hardware buttons" FAIL "no input devices found"
        fi
    fi
fi

# =============================================================================
# TEST 8: Touchscreen / DSI display
# =============================================================================

section "8. Touchscreen & Display"

# Check DRM/KMS sees the display
if ls /sys/class/drm/card*/card*-DSI* &>/dev/null 2>&1; then
    DSI_DEV=$(ls /sys/class/drm/card*/card*-DSI* 2>/dev/null | head -1)
    STATUS=$(cat "${DSI_DEV}/status" 2>/dev/null || echo "unknown")
    result "DSI display" PASS "found: $(basename $DSI_DEV) status=${STATUS}"
elif ls /sys/class/drm/ &>/dev/null; then
    CARDS=$(ls /sys/class/drm/ | grep -v "^renderD\|^version\|^card[0-9]$" | head -5 | xargs)
    result "DSI display" FAIL "DSI not found — DRM devices: ${CARDS:-none}"
else
    result "DSI display" FAIL "no DRM/KMS devices found"
fi

# Check touch input device
TOUCH_DEV=$(find /dev/input -name 'event*' 2>/dev/null | while read -r dev; do
    udevadm info "$dev" 2>/dev/null | grep -qi "touch\|waveshare\|DSI\|ft5" && echo "$dev" && break
done)

if [ -n "$TOUCH_DEV" ]; then
    result "Touch input device" PASS "$TOUCH_DEV"
else
    result "Touch input device" FAIL "no touch input device found — check vc4-kms-dsi-waveshare-800x480 overlay"
fi

# =============================================================================
# TEST 9: Backlight
# =============================================================================

section "9. Backlight"

BACKLIGHT=$(find /sys/class/backlight -name '*rpi*' -o -name '*dsi*' 2>/dev/null | head -1)
if [ -n "$BACKLIGHT" ]; then
    BL_MAX=$(cat "${BACKLIGHT}/max_brightness" 2>/dev/null || echo "?")
    BL_CUR=$(cat "${BACKLIGHT}/brightness" 2>/dev/null || echo "?")
    result "Backlight control" PASS "$(basename $BACKLIGHT) brightness=${BL_CUR}/${BL_MAX}"

    if [ "$AUTO" = false ] && [ "$BL_CUR" != "?" ]; then
        echo "  Dimming display for 2 seconds..."
        echo 10 | sudo tee "${BACKLIGHT}/brightness" > /dev/null 2>/dev/null || true
        sleep 2
        echo "$BL_CUR" | sudo tee "${BACKLIGHT}/brightness" > /dev/null 2>/dev/null || true
        case $(ask_result "Did the display dim and then return to normal?") in
            0) result "Backlight dim/restore" PASS ;;
            1) result "Backlight dim/restore" FAIL ;;
            2) result "Backlight dim/restore" SKIP ;;
        esac
    fi
else
    result "Backlight control" FAIL "no backlight device — check dtoverlay=rpi-backlight"
fi

# =============================================================================
# TEST 10: I2C bus scan
# =============================================================================

section "10. I2C Bus"

if command -v i2cdetect &>/dev/null; then
    I2C_SCAN=$(i2cdetect -y 1 2>/dev/null | grep -oE '[0-9a-f]{2}' | grep -v '^0[0-7]$\|^7[8-f]$' | sort -u | xargs)
    if [ -n "$I2C_SCAN" ]; then
        result "I2C bus scan" PASS "devices found at: ${I2C_SCAN}"
        # Check for known SJ201 addresses
        # 0x04 = LED ring controller
        # 0x1a = TAS5806 amplifier
        echo "$I2C_SCAN" | grep -q "04" && result "LED controller (0x04)" PASS || result "LED controller (0x04)" FAIL "not found"
        echo "$I2C_SCAN" | grep -q "1a" && result "TAS5806 amp (0x1a)" PASS || result "TAS5806 amp (0x1a)" FAIL "not found — amp may not be initialized"
    else
        result "I2C bus scan" FAIL "no devices found — check dtparam=i2c_arm=on"
    fi
else
    result "I2C bus scan" SKIP "i2cdetect not installed (apt install i2c-tools)"
fi

# =============================================================================
# TEST 11: SPI bus
# =============================================================================

section "11. SPI Bus"

if [ -c "/dev/spidev0.0" ]; then
    result "SPI device /dev/spidev0.0" PASS "exists (for XVF3510 firmware flash)"
else
    result "SPI device /dev/spidev0.0" FAIL "not found — check dtparam=spi=on"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Test Summary${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""
printf "  %-8s %s\n" "${GREEN}Passed:${NC}" "$PASS"
printf "  %-8s %s\n" "${RED}Failed:${NC}" "$FAIL"
printf "  %-8s %s\n" "${YELLOW}Skipped:${NC}" "$SKIP"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}✓ All tests passed — hardware looks good!${NC}"
    echo ""
    echo "  You can proceed with:"
    echo "    ./mark2-satellite-setup.sh"
else
    echo -e "  ${RED}✗ ${FAIL} test(s) failed — fix these before proceeding.${NC}"
    echo ""
    echo "  Failed tests:"
    for r in "${RESULTS[@]}"; do
        STATUS=$(echo "$r" | cut -d'|' -f1)
        NAME=$(echo "$r" | cut -d'|' -f2)
        DETAIL=$(echo "$r" | cut -d'|' -f3)
        if [ "$STATUS" = "FAIL" ]; then
            echo -e "    ${RED}✗${NC} ${NAME}${DETAIL:+ — ${DETAIL}}"
        fi
    done
    echo ""
    echo "  Common fixes:"
    echo "    · Re-run: ./mark2-hardware-setup.sh"
    echo "    · Check:  systemctl --user status sj201"
    echo "    · Check:  dmesg | grep -i 'sj201\\|vocalfusion\\|spi\\|i2c'"
fi

echo ""
