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

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()     { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

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
    SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"
    MARK2_DIR="${USER_HOME}/.config/mark2"
    LABWC_AUTOSTART="${USER_HOME}/.config/labwc/autostart"
    mkdir -p "$SYSTEMD_USER_DIR" "$MARK2_DIR" "$(dirname "$LABWC_AUTOSTART")"
    export SYSTEMD_USER_DIR MARK2_DIR LABWC_AUTOSTART
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
