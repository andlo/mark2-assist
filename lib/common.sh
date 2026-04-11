#!/bin/bash
# =============================================================================
# lib/common.sh
# Shared functions and variables for all mark2-assist scripts
#
# Source this file at the top of each script:
#   # shellcheck source=lib/common.sh
#   source "$(dirname "$0")/lib/common.sh"
# =============================================================================

# --- Output colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1";   _log_write "OK"   "$1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; _log_write "WARN" "$1"; }
die()     { echo -e "${RED}[FAIL]${NC} $1";   _log_write "FAIL" "$1"; exit 1; }
info()    { echo -e "${BLUE}[INFO]${NC} $1";  _log_write "INFO" "$1"; }
section() { echo -e "\n${CYAN}=== $1 ===${NC}"; _log_write "----" "=== $1 ==="; }

_log_write() {
    local level="$1"
    local msg="$2"
    if [ -n "${MARK2_LOG:-}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}" >> "$MARK2_LOG"
    fi
}

ask_yes_no() {
    local answer
    read -rp "${1} [y/N]: " answer
    [[ "${answer,,}" == "y" ]]
}

# --- Verify not running as raw root ---
check_not_root() {
    if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
        die "Do not run as root directly. Run as your normal user (with sudo access)."
    fi
}

# --- Resolve current user and home ---
resolve_user() {
    CURRENT_USER="${SUDO_USER:-$USER}"
    USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
    export CURRENT_USER USER_HOME
}

# --- Detect boot directory ---
detect_boot_dir() {
    if [ -d "/boot/firmware" ]; then
        BOOT_DIR="/boot/firmware"
    else
        BOOT_DIR="/boot"
    fi
    BOOT_CONFIG="${BOOT_DIR}/config.txt"
    BOOT_OVERLAYS="${BOOT_DIR}/overlays"
    export BOOT_DIR BOOT_CONFIG BOOT_OVERLAYS
}

# --- Detect Pi model ---
detect_pi_model() {
    PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "unknown")
    if echo "$PI_MODEL" | grep -q "Raspberry Pi 5"; then
        PI5_SUFFIX="-pi5"
    else
        PI5_SUFFIX=""
    fi
    export PI_MODEL PI5_SUFFIX
}

# --- Detect Debian version ---
detect_debian_version() {
    DEBIAN_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-0}")
    if [ "$DEBIAN_VERSION" = "13" ]; then
        KERNEL_HEADERS_PKG="linux-headers-rpi-v8"
    else
        KERNEL_HEADERS_PKG="raspberrypi-kernel-headers"
    fi
    export DEBIAN_VERSION KERNEL_HEADERS_PKG
}

# --- Common paths ---
setup_paths() {
    resolve_user
    MARK2_DIR="${USER_HOME}/.config/mark2"
    SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"
    LABWC_AUTOSTART="${USER_HOME}/.config/labwc/autostart"
    MARK2_CONFIG="${MARK2_DIR}/config"
    MARK2_LOG="${MARK2_DIR}/install.log"
    MARK2_PROGRESS="${MARK2_DIR}/install-progress"
    mkdir -p "$MARK2_DIR" "$SYSTEMD_USER_DIR" "$(dirname "$LABWC_AUTOSTART")"
    export MARK2_DIR SYSTEMD_USER_DIR LABWC_AUTOSTART MARK2_CONFIG MARK2_LOG MARK2_PROGRESS
}

# --- Config file: load saved values ---
config_load() {
    if [ -f "${MARK2_CONFIG}" ]; then
        # shellcheck source=/dev/null
        source "${MARK2_CONFIG}"
    fi
}

# --- Config file: save a key=value ---
config_save() {
    local key="$1"
    local value="$2"
    touch "${MARK2_CONFIG}"
    # Remove existing line for this key, then append
    grep -v "^${key}=" "${MARK2_CONFIG}" > /tmp/mark2_config_tmp || true
    echo "${key}=\"${value}\"" >> /tmp/mark2_config_tmp
    mv /tmp/mark2_config_tmp "${MARK2_CONFIG}"
    chmod 600 "${MARK2_CONFIG}"   # token is sensitive
}

# --- Prompt for HA URL, reuse saved value ---
prompt_ha_url() {
    config_load
    if [ -z "${HA_URL:-}" ]; then
        read -rp "Home Assistant URL (e.g. http://192.168.1.100:8123): " HA_URL
        [ -z "$HA_URL" ] && die "Home Assistant URL is required"
        config_save "HA_URL" "$HA_URL"
    else
        log "Using saved Home Assistant URL: ${HA_URL}"
    fi
    export HA_URL
}

# --- Prompt for HA token, reuse saved value ---
prompt_ha_token() {
    config_load
    if [ -z "${HA_TOKEN:-}" ]; then
        read -rp "HA Long-Lived Access Token: " HA_TOKEN
        [ -z "$HA_TOKEN" ] && die "HA token is required"
        config_save "HA_TOKEN" "$HA_TOKEN"
    else
        log "Using saved HA token"
    fi
    export HA_TOKEN
}

# --- Prompt for weather entity, reuse saved value ---
prompt_ha_weather() {
    config_load
    if [ -z "${HA_WEATHER_ENTITY:-}" ]; then
        read -rp "HA weather entity [weather.home]: " HA_WEATHER_ENTITY
        HA_WEATHER_ENTITY="${HA_WEATHER_ENTITY:-weather.home}"
        config_save "HA_WEATHER_ENTITY" "$HA_WEATHER_ENTITY"
    else
        log "Using saved weather entity: ${HA_WEATHER_ENTITY}"
    fi
    export HA_WEATHER_ENTITY
}

# --- Progress tracking ---
progress_set() {
    local module="$1"
    local status="$2"   # done | skipped | failed
    touch "${MARK2_PROGRESS}"
    grep -v "^${module}=" "${MARK2_PROGRESS}" > /tmp/mark2_progress_tmp || true
    echo "${module}=${status}" >> /tmp/mark2_progress_tmp
    mv /tmp/mark2_progress_tmp "${MARK2_PROGRESS}"
}

progress_get() {
    local module="$1"
    if [ -f "${MARK2_PROGRESS}" ]; then
        grep "^${module}=" "${MARK2_PROGRESS}" | cut -d= -f2 || echo ""
    else
        echo ""
    fi
}

progress_is_done() {
    local module="$1"
    [ "$(progress_get "$module")" = "done" ]
}

# --- Add line to labwc autostart (idempotent) ---
labwc_autostart_add() {
    local marker="$1"
    local line="$2"
    grep -v "$marker" "$LABWC_AUTOSTART" 2>/dev/null > /tmp/labwc_tmp || true
    mv /tmp/labwc_tmp "$LABWC_AUTOSTART" 2>/dev/null || true
    echo "$line" >> "$LABWC_AUTOSTART"
}

# --- Reload systemd user daemon ---
reload_user_systemd() {
    systemctl --user daemon-reload
}
