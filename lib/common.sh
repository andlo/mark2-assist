#!/bin/bash
# =============================================================================
# lib/common.sh
# Shared functions and variables for all mark2-assist scripts.
#
# Source this file at the top of each script:
#   # shellcheck source=lib/common.sh
#   source "$(dirname "$0")/lib/common.sh"
#
# Functions provided:
#
#   Output / logging:
#     log "msg"          Print green  [OK]   line + write to MARK2_LOG
#     warn "msg"         Print yellow [WARN] line + write to MARK2_LOG
#     die "msg"          Print red    [FAIL] line + write to MARK2_LOG + exit 1
#     info "msg"         Print blue   [INFO] line + write to MARK2_LOG
#     section "title"    Print cyan   === title === separator
#     show_info "msg"    whiptail infobox (non-blocking) or echo
#     show_msg "msg"     whiptail msgbox (waits for OK) or echo
#
#   User prompts:
#     ask_yes_no "?"     whiptail yesno or read — returns 0/1
#     ask_input "?" def  whiptail inputbox or read — echoes result
#     ask_password "?"   whiptail passwordbox or read -s — echoes result
#     confirm_or_skip "?"  Skip prompt if MARK2_MODULE_CONFIRMED=1
#
#   Environment setup:
#     check_not_root     Exit if running as raw root (not via sudo)
#     resolve_user       Set CURRENT_USER and USER_HOME from SUDO_USER or $USER
#     detect_boot_dir    Set BOOT_DIR, BOOT_CONFIG, BOOT_OVERLAYS
#     detect_pi_model    Set PI_MODEL and PI5_SUFFIX ("-pi5" or "")
#     detect_debian_version  Set DEBIAN_VERSION and KERNEL_HEADERS_PKG
#     setup_paths        Call resolve_user + set all MARK2_* path variables
#                        Creates ~/.config/mark2/, systemd/user/, labwc/ dirs
#
#   Configuration file (~/.config/mark2/config, chmod 600):
#     config_load        Source the config file into current shell
#     config_save k v    Write/update key=value in config file
#     prompt_ha_url      Ask for HA URL if not saved, export HA_URL
#     prompt_ha_token    Ask for HA token if not saved, export HA_TOKEN
#     prompt_ha_weather  Ask for weather entity if not saved
#
#   Progress tracking (~/.config/mark2/install-progress):
#     progress_set mod status   Write module=status (done|skipped|failed)
#     progress_get mod          Echo current status for module
#     progress_is_done mod      Return 0 if module status is "done"
#
#   Package management (output → MARK2_LOG):
#     apt_update         Run apt-get update -qq
#     apt_install pkg…   Run apt-get install -y --no-install-recommends
#     git_clone_or_pull url dir  Clone or pull a git repo
#
#   labwc integration (used by optional face/overlay modules):
#     labwc_autostart_add marker line  Add/replace a line in labwc/autostart
#
#   Systemd:
#     reload_user_systemd   Run systemctl --user daemon-reload
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

# --- Show informational whiptail box (non-blocking display) ---
show_info() {
    local msg="$1"
    local height="${2:-8}"
    local width="${3:-60}"
    if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
        whiptail --title "Mark II Assist" --infobox "$msg" "$height" "$width"
    else
        echo -e "${BLUE}[INFO]${NC} ${msg}"
    fi
}

# --- Section header for modules ---
module_header() {
    local title="$1"
    local desc="${2:-}"
    section "$title"
    [ -n "$desc" ] && echo -e "  ${desc}"
    echo ""
}

# --- Show whiptail message box (waits for OK) ---
show_msg() {
    local msg="$1"
    local height="${2:-10}"
    local width="${3:-60}"
    if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
        whiptail --title "Mark II Assist" --msgbox "$msg" "$height" "$width"
    else
        echo -e "${BLUE}[INFO] ${msg}${NC}"
    fi
}

ask_yes_no() {
    local prompt="$1"
    if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
        whiptail --title "Mark II Assist" --yesno "$prompt" 8 60
        return $?
    else
        local answer
        read -rp "${prompt} [y/N]: " answer
        [[ "${answer,,}" == "y" ]]
    fi
}

ask_input() {
    # ask_input "Prompt text" "default value"
    local prompt="$1"
    local default="${2:-}"
    if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
        local result
        result=$(whiptail --title "Mark II Assist" \
            --inputbox "$prompt" 10 65 "$default" \
            3>&1 1>&2 2>&3) || return 1
        echo "$result"
    else
        local answer
        read -rp "${prompt} [${default}]: " answer
        echo "${answer:-$default}"
    fi
}

ask_password() {
    local prompt="$1"
    if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
        whiptail --title "Mark II Assist" \
            --passwordbox "$prompt" 10 65 \
            3>&1 1>&2 2>&3
    else
        local answer
        read -rsp "${prompt}: " answer; echo
        echo "$answer"
    fi
}

# --- Used by modules to skip their own prompt when called from install.sh ---
# If MARK2_MODULE_CONFIRMED=1 is set, skip the confirmation prompt.
# Usage at top of each module:
#   confirm_or_skip "Install Snapcast client?" || exit 0
confirm_or_skip() {
    local prompt="$1"
    if [ "${MARK2_MODULE_CONFIRMED:-0}" = "1" ]; then
        return 0  # already confirmed by install.sh
    fi
    ask_yes_no "$prompt"
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
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")
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
# Sets all MARK2_* path variables and creates required directories.
# Note: labwc/autostart dir is created even though Weston is the main compositor,
# because the optional face and overlay modules still use labwc window rules.
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
        HA_URL=$(ask_input "Home Assistant URL" "http://192.168.1.100:8123") \
            || die "Home Assistant URL is required"
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
        HA_TOKEN=$(ask_password "HA Long-Lived Access Token") \
            || die "HA token is required"
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
        HA_WEATHER_ENTITY=$(ask_input "HA weather entity" "weather.home") \
            || true
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

# --- Quiet apt install - output goes to log, errors shown on screen ---
apt_install() {
    info "Installing: $*"
    if ! sudo apt-get install -y --no-install-recommends "$@" \
        >> "${MARK2_LOG:-/tmp/mark2-install.log}" 2>&1; then
        warn "apt install failed for: $*"
        warn "Check log for details: ${MARK2_LOG:-/tmp/mark2-install.log}"
        return 1
    fi
}

apt_update() {
    info "Updating package lists..."
    sudo apt-get update -qq >> "${MARK2_LOG:-/tmp/mark2-install.log}" 2>&1 || true
}

# --- Quiet git clone/pull ---
git_clone_or_pull() {
    local url="$1"
    local dir="$2"
    if [ -d "$dir" ]; then
        info "Updating $(basename "$dir")..."
        (cd "$dir" && git pull --quiet >> "${MARK2_LOG:-/tmp/mark2-install.log}" 2>&1)
    else
        info "Cloning $(basename "$dir")..."
        git clone --quiet "$url" "$dir" >> "${MARK2_LOG:-/tmp/mark2-install.log}" 2>&1
    fi
}
labwc_autostart_add() {
    # Add or replace a line in ~/.config/labwc/autostart.
    # Used by optional face and overlay modules to register their
    # Chromium --app windows with labwc window management.
    # marker: unique string to identify the line (used to find and replace it)
    # line:   the full autostart line to write
    local marker="$1"
    local line="$2"
    # Remove ALL existing lines containing this marker
    if [ -f "$LABWC_AUTOSTART" ]; then
        grep -v "$marker" "$LABWC_AUTOSTART" > /tmp/labwc_tmp 2>/dev/null || true
        mv /tmp/labwc_tmp "$LABWC_AUTOSTART"
    fi
    echo "$line" >> "$LABWC_AUTOSTART"
}

# --- Reload systemd user daemon ---
reload_user_systemd() {
    systemctl --user daemon-reload
}
