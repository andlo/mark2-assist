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
#   4. Microphone → Speaker — records then plays back so you can verify
#   5. Speaker              — plays a test tone via SJ201 amplifier
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
echo '    __  ___           __      ________     ___              _      __ '
echo '   /  |/  /___ ______/ /__   /  _/  _/    /   |  __________(_)____/ /_'
echo '  / /|_/ / __ `/ ___/ //_/   / / / /     / /| | / ___/ ___/ / ___/ __/'
echo ' / /  / / /_/ / /  / ,<    _/ /_/ /     / ___ |(__  |__  ) (__  ) /_  '
echo '/_/  /_/\__,_/_/  /_/|_|  /___/___/    /_/  |_/____/____/_/____/\__/  '
echo -e "${NC}"
echo -e "${BLUE}  Mark II Hardware Test Suite${NC}"
echo -e "${BLUE}  github.com/andlo/mark2-assist${NC}"
echo ""
if [ "$AUTO" = true ]; then
    echo -e "  ${YELLOW}Running in automatic mode — manual checks skipped${NC}"
    echo ""
fi
echo -e "${CYAN}  What this test covers:${NC}"
echo ""
echo "   1. SJ201 Service      — firmware loaded, XMOS chip ready"
echo "   2. Audio Devices      — ALSA sees microphone and speaker"
echo "   3. Microphone         — speak into mic, check signal level   🎤"
echo "   4. Mic → Speaker      — speak and hear it played back        🔊"
echo "   5. Speaker            — listen for a beep tone               🔔"
echo "   6. LED Ring           — watch ring cycle through colours      💡"
echo "   7. Buttons            — press any hardware button             🔘"
echo "   8. Touchscreen        — look at the display                  🖥"
echo "   9. Backlight          — watch display dim and restore         🌓"
echo "  10. I2C Bus            — scan for SJ201 chip addresses"
echo "  11. SPI Bus            — check XVF3510 firmware interface"
echo ""
echo -e "${YELLOW}  Tests 3–9 require your attention — follow the prompts.${NC}"
echo ""
if [ "$AUTO" = false ]; then
    read -rp "  Press Enter to start the hardware test..." _dummy
    echo ""
fi

# =============================================================================
# TEST 1: SJ201 service
# =============================================================================

section "1. SJ201 Service"

# Wait briefly for XMOS XVF-3510 to fully initialize after boot
# Without this, lsmod may not yet show vocalfusion_soundcard
if systemctl --user is-active sj201.service &>/dev/null; then
    result "sj201.service" PASS "active (firmware loaded)"
elif systemctl --user is-active sj201.service --quiet 2>/dev/null || \
     [ "$(systemctl --user show sj201.service -p ActiveState --value 2>/dev/null)" = "activating" ]; then
    echo "  sj201.service is starting — waiting..."
    for i in $(seq 1 20); do
        sleep 1
        systemctl --user is-active sj201.service &>/dev/null && break
    done
    systemctl --user is-active sj201.service &>/dev/null \
        && result "sj201.service" PASS "active (firmware loaded)" \
        || result "sj201.service" FAIL "did not start in time"
else
    STATUS=$(systemctl --user show sj201.service -p ActiveState --value 2>/dev/null || echo "unknown")
    [ "$STATUS" = "failed" ] \
        && result "sj201.service" FAIL "service failed — run: systemctl --user status sj201" \
        || result "sj201.service" FAIL "not active (status: ${STATUS})"
fi

# Wait for vocalfusion kernel module — poll until loaded (max 15s)
echo "  Waiting for XMOS XVF-3510 and vocalfusion module (up to 15 seconds)..."
VOCAL_OK=false
for i in $(seq 1 15); do
    if lsmod 2>/dev/null | grep -q "vocalfusion"; then
        echo "  Ready after ${i}s."
        VOCAL_OK=true
        break
    fi
    sleep 1
done

# Check XVF3510 firmware file exists
if [ -f "/opt/sj201/app_xvf3510_int_spi_boot_v4_2_0.bin" ]; then
    result "XVF3510 firmware file" PASS
else
    result "XVF3510 firmware file" FAIL "not found in /opt/sj201/"
fi

# Check VocalFusion kernel module loaded (module name uses underscore)
if [ "$VOCAL_OK" = "true" ]; then
    MOD_NAME=$(lsmod | grep vocalfusion | awk '{print $1}')
    result "vocalfusion kernel module" PASS "loaded (${MOD_NAME})"
else
    result "vocalfusion kernel module" FAIL "not loaded after 15s — check dmesg for errors"
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
echo "  Waiting 2 seconds for XMOS XVF-3510 to be ready..."
sleep 2
echo ""
echo "  When you press Enter, recording starts immediately (3 seconds)."
echo "  Speak clearly into the microphone — e.g. 'testing one two three'."
read -rp "  Press Enter when ready to record..." _dummy
echo "  🎤 Recording now..."
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
# TEST 4: Microphone → Speaker roundtrip
# =============================================================================

section "4. Microphone → Speaker Roundtrip"
echo "  Records 4 seconds then plays it back through the speaker."
echo "  NOTE: Audio quality may sound processed/distorted — this is normal!"
echo "  The XMOS XVF-3510 chip processes microphone audio for noise reduction."
echo "  What matters: can you roughly hear what you said? (words recognisable)"
echo ""
echo "  When you press Enter, recording starts immediately (4 seconds)."
echo "  Count slowly: 'one... two... three... four...'"
read -rp "  Press Enter when ready to record..." _dummy
echo "  🎤 Recording now..."
echo ""

ROUNDFILE="/tmp/mark2-roundtrip.wav"
ROUNDFILE_48="/tmp/mark2-roundtrip-48k.wav"
if arecord -D "${MIC_DEV}" -r 16000 -c 1 -f S16_LE -d 4 "$ROUNDFILE" 2>/dev/null; then
    echo "  Converting and playing back..."
    if command -v sox &>/dev/null; then
        sox "$ROUNDFILE" -r 48000 -c 2 "$ROUNDFILE_48" 2>/dev/null
        timeout 6 aplay -D plughw:CARD=sj201,DEV=0 "$ROUNDFILE_48" 2>/dev/null || true
    else
        sudo apt-get install -y --no-install-recommends sox \
            >> "${MARK2_LOG:-/dev/null}" 2>&1 || true
        if command -v sox &>/dev/null; then
            sox "$ROUNDFILE" -r 48000 -c 2 "$ROUNDFILE_48" 2>/dev/null
            timeout 6 aplay -D plughw:CARD=sj201,DEV=0 "$ROUNDFILE_48" 2>/dev/null || true
        fi
    fi
    case $(ask_result "Could you roughly hear what you said? (quality will be poor — that is normal)") in
        0) result "Mic → Speaker roundtrip" PASS ;;
        1) result "Mic → Speaker roundtrip" FAIL "no recognisable audio — check XMOS routing" ;;
        2) result "Mic → Speaker roundtrip" SKIP ;;
    esac
else
    result "Mic → Speaker roundtrip" FAIL "recording failed"
fi

# =============================================================================
# TEST 5: Speaker — play test tone
# =============================================================================

section "5. Speaker"
echo "  Will play a 440 Hz test tone through the speaker (2 seconds)."
echo "  Note: Audio path is Pi I2S → XMOS XVF-3510 → TAS5806 → Speaker"
echo ""
read -rp "  Press Enter to play the test tone — listen for a beep..." _dummy
echo ""

# Generate tone file
TONEFILE="/tmp/mark2-tone-test.wav"
python3 - "$TONEFILE" << 'PYEOF'
import sys, wave, struct, math
rate = 48000  # XMOS XVF-3510 prefers 48kHz
duration = 2.0
freq = 440
samples = [int(32767 * 0.5 * math.sin(2 * math.pi * freq * i / rate))
           for i in range(int(rate * duration))]
fade = int(rate * 0.1)
for i in range(fade):
    samples[i] = int(samples[i] * i / fade)
    samples[-(i+1)] = int(samples[-(i+1)] * i / fade)
with wave.open(sys.argv[1], 'w') as f:
    f.setnchannels(2)   # Stereo — XMOS may require stereo
    f.setsampwidth(2)
    f.setframerate(rate)
    # Duplicate mono to stereo
    stereo = []
    for s in samples:
        stereo.extend([s, s])
    f.writeframes(struct.pack('<' + 'h' * len(stereo), *stereo))
PYEOF

PLAYED=false
# Try formats in order of likelihood for XMOS XVF-3510
for ARGS in \
    "-D plughw:CARD=sj201,DEV=0 -r 48000 -c 2" \
    "-D plughw:CARD=sj201,DEV=0 -r 16000 -c 2" \
    "-D plughw:CARD=sj201,DEV=0" \
    "-D default"; do
    echo "  Trying: aplay ${ARGS}..."
    if timeout 5 aplay $ARGS "$TONEFILE" 2>/dev/null; then
        PLAYED=true
        result "Speaker aplay ($ARGS)" PASS
        break
    fi
done

if [ "$PLAYED" = false ]; then
    result "Speaker playback" FAIL "all formats failed — check XMOS firmware and sj201.service"
else
    case $(ask_result "Did you hear a tone from the speaker?") in
        0) result "Speaker audio output" PASS "tone heard" ;;
        1) result "Speaker audio output" FAIL "aplay ran but no sound — check TAS5806 amp or volume" ;;
        2) result "Speaker audio output" SKIP "manual check skipped" ;;
    esac
fi

# =============================================================================
# TEST 6: LED ring
# =============================================================================

section "6. LED Ring"

if ! command -v python3 &>/dev/null; then
    result "LED ring" SKIP "python3 not available"
else
    echo "  Testing LED ring — NeoPixel WS2812 on GPIO12..."
    echo "  The ring will cycle through red, green, blue and white."
    echo ""
    read -rp "  Press Enter to start — watch the LED ring on the device..." _dummy
    echo ""

    # LED ring is NeoPixel WS2812 on GPIO12 (D12) — NOT I2C
    # Requires adafruit-circuitpython-neopixel + adafruit-blinka (root)
    LED_RESULT=$(sudo python3 - 2>&1 << 'PYEOF'
import sys, time
try:
    import neopixel
    from adafruit_blinka.microcontroller.bcm283x.pin import D12
    pixels = neopixel.NeoPixel(D12, 12, brightness=0.2, auto_write=False, pixel_order=neopixel.GRB)
    print("  Red...")
    pixels.fill((255, 0, 0)); pixels.show(); time.sleep(0.5)
    print("  Green...")
    pixels.fill((0, 255, 0)); pixels.show(); time.sleep(0.5)
    print("  Blue...")
    pixels.fill((0, 0, 255)); pixels.show(); time.sleep(0.5)
    print("  White...")
    pixels.fill((40, 40, 40)); pixels.show(); time.sleep(0.5)
    pixels.fill((0, 0, 0)); pixels.show()
    print("LED_OK")
except ImportError as e:
    print(f"LED_SKIP:{e}")
except Exception as e:
    print(f"LED_FAIL:{e}")
PYEOF
)

    if echo "$LED_RESULT" | grep -q "LED_OK"; then
        case $(ask_result "Did the LED ring cycle through red/green/blue/white?") in
            0) result "LED ring" PASS "NeoPixel GPIO12 OK, colors seen" ;;
            1) result "LED ring" FAIL "NeoPixel write OK but no visible colors" ;;
            2) result "LED ring" SKIP ;;
        esac
    elif echo "$LED_RESULT" | grep -q "LED_SKIP"; then
        SKIP_MSG=$(echo "$LED_RESULT" | grep LED_SKIP | cut -d: -f2-)
        result "LED ring" SKIP "neopixel not installed: ${SKIP_MSG}"
        info "Install with: sudo pip3 install adafruit-circuitpython-neopixel --break-system-packages"
    else
        FAIL_MSG=$(echo "$LED_RESULT" | grep LED_FAIL | cut -d: -f2-)
        result "LED ring" FAIL "${FAIL_MSG}"
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
        echo ""
        echo "  When you press Enter, you have 8 seconds to press any button."
        echo "  Press volume up, volume down, or the action button (center of LED ring)."
        read -rp "  Press Enter when ready..." _dummy
        echo "  Waiting for button press..."
        if timeout 8 bash -c "evtest '$EVDEV_DEV' 2>/dev/null | grep -m1 'type 1'" 2>/dev/null | grep -q "type 1"; then
            result "Button press detected" PASS
        else
            result "Button press detected" FAIL "no event received — did you press a button?"
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
echo "  Checking DSI display connection and touch controller."
echo "  Look at the Mark II screen — it should be on (even if blank/black)."
echo ""
read -rp "  Press Enter to continue..." _dummy
echo ""

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
    case $(ask_result "Is the display lit up and visible on the screen?") in
        0) result "Display visible" PASS ;;
        1) result "Display visible" FAIL "display is off or blank — check DSI ribbon cable" ;;
        2) result "Display visible" SKIP ;;
    esac
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

# Install i2c-tools if missing
if ! command -v i2cdetect &>/dev/null; then
    info "Installing i2c-tools..."
    sudo apt-get install -y --no-install-recommends i2c-tools >> "${MARK2_LOG:-/dev/null}" 2>&1 || true
fi

if command -v i2cdetect &>/dev/null; then
    I2C_RAW=$(sudo i2cdetect -y 1 2>/dev/null)
    I2C_SCAN=$(echo "$I2C_RAW" | grep -oE '\b[0-9a-f]{2}\b' | grep -v '^0[0-7]$' | sort -u | xargs)
    if [ -n "$I2C_SCAN" ]; then
        result "I2C bus scan" PASS "devices found at: ${I2C_SCAN}"
        echo "$I2C_SCAN" | grep -q "2c" \
            && result "LED controller (0x2c)" PASS \
            || result "LED controller (0x2c)" FAIL "not found — check SJ201 power and I2C"
        echo "$I2C_SCAN" | grep -q "2f" \
            && result "TAS5806 amp (0x2f)" PASS \
            || result "TAS5806 amp (0x2f)" FAIL "not found — amp may not be initialized"
    else
        result "I2C bus scan" FAIL "no devices found — check dtparam=i2c_arm=on"
    fi
else
    result "I2C bus scan" SKIP "i2c-tools install failed"
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
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Skipped:${NC} $SKIP"
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
