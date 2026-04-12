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
#   ./update.sh --skip-wyoming    Skip Wyoming satellite/openWakeWord update
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
WYOMING_SAT_DIR="${USER_HOME}/wyoming-satellite"
WYOMING_OWW_DIR="${USER_HOME}/wyoming-openwakeword"

# --- Parse flags ---
SKIP_APT=false
SKIP_WYOMING=false
SKIP_RESTART=false
YES=false

for arg in "$@"; do
    case "$arg" in
        --skip-apt)     SKIP_APT=true ;;
        --skip-wyoming) SKIP_WYOMING=true ;;
        --skip-restart) SKIP_RESTART=true ;;
        --yes|-y)       YES=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-apt] [--skip-wyoming] [--skip-restart] [--yes]"
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
echo -e "  · Wyoming satellite + openWakeWord  (git pull + setup)"
echo -e "  · Restarts all mark2 services"
echo ""

if [ "$YES" = false ]; then
    if ! ask_yes_no "Update Mark II Assist and Wyoming components?"; then
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
# 3. WYOMING COMPONENTS
# =============================================================================

if [ "$SKIP_WYOMING" = false ]; then
    # Wyoming Satellite
    section "Step 3/4 — Wyoming Satellite"
    if [ -d "$WYOMING_SAT_DIR" ]; then
        SAT_BEFORE=$(git -C "$WYOMING_SAT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        if git -C "$WYOMING_SAT_DIR" pull --quiet >> "${MARK2_LOG}" 2>&1; then
            SAT_AFTER=$(git -C "$WYOMING_SAT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
            if [ "$SAT_BEFORE" != "$SAT_AFTER" ]; then
                info "New version detected — running setup..."
                systemctl --user stop wyoming-satellite.service 2>/dev/null || true
                cd "$WYOMING_SAT_DIR"
                python3 script/setup >> "${MARK2_LOG}" 2>&1 \
                    && log "Wyoming Satellite updated: ${SAT_BEFORE} → ${SAT_AFTER}" \
                    || { warn "Wyoming Satellite setup failed — check ${MARK2_LOG}"; ERRORS=$((ERRORS + 1)); }
            else
                log "Wyoming Satellite already up to date (${SAT_AFTER})"
            fi
        else
            warn "Wyoming Satellite git pull failed"
            ERRORS=$((ERRORS + 1))
        fi
    else
        warn "Wyoming Satellite not found at ${WYOMING_SAT_DIR} — skipping"
    fi

    # Wyoming openWakeWord
    if [ -d "$WYOMING_OWW_DIR" ]; then
        OWW_BEFORE=$(git -C "$WYOMING_OWW_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        if git -C "$WYOMING_OWW_DIR" pull --quiet >> "${MARK2_LOG}" 2>&1; then
            OWW_AFTER=$(git -C "$WYOMING_OWW_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
            if [ "$OWW_BEFORE" != "$OWW_AFTER" ]; then
                info "New version detected — running setup..."
                systemctl --user stop wyoming-openwakeword.service 2>/dev/null || true
                cd "$WYOMING_OWW_DIR"
                python3 script/setup >> "${MARK2_LOG}" 2>&1 \
                    && log "openWakeWord updated: ${OWW_BEFORE} → ${OWW_AFTER}" \
                    || { warn "openWakeWord setup failed — check ${MARK2_LOG}"; ERRORS=$((ERRORS + 1)); }
            else
                log "openWakeWord already up to date (${OWW_AFTER})"
            fi
        else
            warn "openWakeWord git pull failed"
            ERRORS=$((ERRORS + 1))
        fi
    else
        warn "openWakeWord not found at ${WYOMING_OWW_DIR} — skipping"
    fi
else
    info "Skipping Wyoming update (--skip-wyoming)"
fi

# =============================================================================
# 4. RESTART SERVICES
# =============================================================================

if [ "$SKIP_RESTART" = false ]; then
    section "Step 4/4 — Restarting services"
    systemctl --user daemon-reload

    SERVICES=(
        wyoming-openwakeword
        wyoming-satellite
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
