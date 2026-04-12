#!/bin/bash
# =============================================================================
# update.sh
# Mark II Assist — Update script
#
# Updates all installed mark2-assist components to their latest versions.
# Safe to run at any time — restarts services after updates.
#
# What this script updates:
#   1. System packages (apt upgrade)
#   2. mark2-assist scripts (git pull)
#   3. Wyoming satellite (git pull + re-setup)
#   4. Wyoming openWakeWord (git pull + re-setup)
#   5. Restarts all mark2 services
#
# What this script does NOT update:
#   - /boot/firmware/config.txt (hardware config — run mark2-hardware-setup.sh)
#   - VocalFusion kernel module (handled by mark2-vocalfusion-watchdog.service)
#   - Optional module configurations
#
# Usage:
#   chmod +x update.sh
#   ./update.sh
#
#   Or with flags:
#   ./update.sh --skip-apt        Skip system package update
#   ./update.sh --skip-lva        Skip Linux Voice Assistant update
#   ./update.sh --skip-restart    Skip service restart
#   ./update.sh --yes             Non-interactive (no confirmation prompts)
# =============================================================================

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

check_not_root
setup_paths
config_load

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LVA_DIR="${USER_HOME}/lva"

# --- Parse flags ---
SKIP_APT=false
SKIP_LVA=false
SKIP_RESTART=false
YES=false

for arg in "$@"; do
    case "$arg" in
        --skip-apt)     SKIP_APT=true ;;
        --skip-lva) SKIP_LVA=true ;;
        --skip-restart) SKIP_RESTART=true ;;
        --yes|-y)       YES=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-apt] [--skip-lva] [--skip-restart] [--yes]"
            exit 0 ;;
    esac
done

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
echo -e "${BLUE}  Mark II Assist — Update${NC}"
echo -e "${BLUE}  github.com/andlo/mark2-assist${NC}"
echo ""
echo -e "  Updates:"
echo -e "  · System packages  (apt upgrade)"
echo -e "  · mark2-assist scripts  (git pull)"
echo -e "  · Linux Voice Assistant (LVA)  (git pull + setup)"
echo -e "  · Restarts all mark2 services"
echo ""

if [ "$YES" = false ]; then
    if ! ask_yes_no "Update Mark II Assist and LVA components?"; then
        echo "Cancelled."
        exit 0
    fi
fi

ERRORS=0

# =============================================================================
# 1. SYSTEM PACKAGES
# =============================================================================

if [ "$SKIP_APT" = false ]; then
    section "Step 1/4 — System packages"
    info "Running apt update + upgrade..."
    if sudo apt-get update -qq >> "${MARK2_LOG}" 2>&1; then
        log "Package lists updated"
    else
        warn "apt update failed — check network connection"
        ERRORS=$((ERRORS + 1))
    fi
    if sudo apt-get upgrade -y --no-install-recommends >> "${MARK2_LOG}" 2>&1; then
        log "System packages upgraded"
    else
        warn "apt upgrade had errors — check ${MARK2_LOG}"
        ERRORS=$((ERRORS + 1))
    fi
else
    info "Skipping system package update (--skip-apt)"
fi

# =============================================================================
# 2. MARK2-ASSIST SCRIPTS
# =============================================================================

section "Step 2/4 — mark2-assist scripts"

CURRENT_BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "unknown")
CURRENT_COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
info "Current branch: ${CURRENT_BRANCH}  commit: ${CURRENT_COMMIT}"

if git -C "$SCRIPT_DIR" pull --quiet >> "${MARK2_LOG}" 2>&1; then
    NEW_COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    if [ "$CURRENT_COMMIT" = "$NEW_COMMIT" ]; then
        log "mark2-assist already up to date (${NEW_COMMIT})"
    else
        log "mark2-assist updated: ${CURRENT_COMMIT} → ${NEW_COMMIT}"
    fi
else
    warn "git pull failed — continuing with current version"
    ERRORS=$((ERRORS + 1))
fi

# =============================================================================
# 3. LVA COMPONENTS
# =============================================================================

if [ "$SKIP_LVA" = false ]; then
    # Linux Voice Assistant
    section "Step 3/4 — Linux Voice Assistant (LVA)"
    LVA_DIR="${USER_HOME}/lva"
    if [ -d "$LVA_DIR" ]; then
        LVA_BEFORE=$(git -C "$LVA_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        if git -C "$LVA_DIR" pull --quiet >> "${MARK2_LOG}" 2>&1; then
            LVA_AFTER=$(git -C "$LVA_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
            if [ "$LVA_BEFORE" != "$LVA_AFTER" ]; then
                info "New version detected — running setup..."
                systemctl --user stop lva.service 2>/dev/null || true
                cd "$LVA_DIR"
                rm -rf .venv
                python3 script/setup >> "${MARK2_LOG}" 2>&1 \
                    && log "LVA updated: ${LVA_BEFORE} → ${LVA_AFTER}" \
                    || { warn "LVA setup failed — check ${MARK2_LOG}"; ERRORS=$((ERRORS + 1)); }
            else
                log "Linux Voice Assistant already up to date (${LVA_AFTER})"
            fi
        else
            warn "LVA git pull failed"
            ERRORS=$((ERRORS + 1))
        fi
    else
        warn "LVA not found at ${LVA_DIR} — skipping (run mark2-satellite-setup.sh)"
    fi
else
    info "Skipping LVA update (--skip-lva)"
fi

# =============================================================================
# 4. RESTART SERVICES
# =============================================================================

if [ "$SKIP_RESTART" = false ]; then
    section "Step 4/4 — Restarting services"

    # Clear LVA ESPHome port before restart
    fuser -k 6053/tcp 2>/dev/null || true
    sleep 1

    systemctl --user daemon-reload

    SERVICES=(
        lva
        mark2-face-events
        mark2-mqtt-bridge
        mark2-leds
        mark2-led-events
        mark2-mpd-watcher
        mark2-volume-monitor
    )

    for svc in "${SERVICES[@]}"; do
        # Only restart services that are enabled
        if systemctl --user is-enabled "${svc}.service" &>/dev/null; then
            if systemctl --user restart "${svc}.service" 2>/dev/null; then
                log "Restarted: ${svc}"
            else
                warn "Could not restart: ${svc}"
            fi
        fi
    done
else
    info "Skipping service restart (--skip-restart)"
fi

# =============================================================================
# DONE
# =============================================================================

echo ""
echo -e "${CYAN}========================================"
if [ "$ERRORS" -eq 0 ]; then
    log "Update complete — no errors"
else
    warn "Update complete — ${ERRORS} warning(s), check ${MARK2_LOG}"
fi
echo -e "${CYAN}========================================${NC}"
echo ""
echo "  Log: ${MARK2_LOG}"
echo ""
