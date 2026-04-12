#!/bin/bash

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# =============================================================================
# mark2-hardware-setup.sh
# Mycroft Mark II hardware driver setup for Raspberry Pi OS (Trixie / Debian 13+)
#
# Converted from OpenVoiceOS ovos-installer Ansible roles.
# Source: https://github.com/OpenVoiceOS/ovos-installer
#
# Tested against: Raspberry Pi OS Trixie (Debian 13) - current latest image (Oct 2025+)
# Also supports:  Bookworm (Debian 12) and Bullseye (Debian 11)
#
# What this script does:
#   - Installs kernel headers and EEPROM tools
#   - Clones and builds VocalFusion sound card driver (SJ201/XMOS XVF-3510)
#   - Copies DTBO overlays to boot
#   - Configures /boot/firmware/config.txt (dtoverlay, uart)
#   - Creates Python venv for SJ201 firmware flash
#   - Downloads SJ201 firmware and init scripts
#   - Creates and enables sj201.service (systemd user service)
#   - Configures WirePlumber for SJ201 audio profile
#   - Enables touchscreen backlight overlay
#
# No OVOS/Mycroft software is installed.
#
# Requirements:
#   - Raspberry Pi OS Trixie (Debian 13) on Mark II hardware
#   - Run as the user who should own sj201.service
#   - sudo access
#
# Usage:
#   chmod +x mark2-hardware-setup.sh
#   ./mark2-hardware-setup.sh
# =============================================================================

set -euo pipefail

# --- Output colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()    { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# --- Ensure we are not running as root directly ---
if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    die "Do not run as root directly. Use: ./mark2-hardware-setup.sh (with sudo access)"
fi

CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)

# --- Detect boot directory ---
if [ -d "/boot/firmware" ]; then
    BOOT_DIR="/boot/firmware"
else
    BOOT_DIR="/boot"
fi
BOOT_CONFIG="${BOOT_DIR}/config.txt"
BOOT_OVERLAYS="${BOOT_DIR}/overlays"

log "Boot directory: ${BOOT_DIR}"

# --- Detect Pi model (Pi 4 vs Pi 5) ---
PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "unknown")
if echo "$PI_MODEL" | grep -q "Raspberry Pi 5"; then
    PI5_SUFFIX="-pi5"
    log "Detected: Raspberry Pi 5"
else
    PI5_SUFFIX=""
    log "Detected: ${PI_MODEL:-unknown Pi model}"
fi

# --- Detect Debian version (for correct kernel-headers package) ---
DEBIAN_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-0}")
if [ "$DEBIAN_VERSION" = "13" ]; then
    KERNEL_HEADERS_PKG="linux-headers-rpi-v8"
else
    KERNEL_HEADERS_PKG="raspberrypi-kernel-headers"
fi
log "Kernel headers package: ${KERNEL_HEADERS_PKG}"

# --- Paths ---
WORK_DIR="/opt/sj201"
SJ201_VENV="${USER_HOME}/.venvs/sj201"
SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"
WIREPLUMBER_CONF_DIR="${USER_HOME}/.config/wireplumber/wireplumber.conf.d"
VOCALFUSION_SRC="/usr/src/vocalfusion"
VOCALFUSION_DRIVER_DIR="${VOCALFUSION_SRC}/driver"
VOCALFUSION_MODULE="vocalfusion-soundcard"
KERNEL_VERSION=$(uname -r)
MODULE_PATH="/lib/modules/${KERNEL_VERSION}/${VOCALFUSION_MODULE}.ko"
MODULES_LOAD_CONF="/etc/modules-load.d/vocalfusion.conf"
EEPROM_CONFIG="/etc/default/rpi-eeprom-update"

# --- SJ201 firmware and scripts (vendored in assets/) ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="${SCRIPT_DIR}/assets"

# =============================================================================
# FUNCTIONS
# =============================================================================

check_requirements() {
    log "Checking requirements..."
    [ -f "$BOOT_CONFIG" ]   || die "Cannot find boot config: ${BOOT_CONFIG}"
    [ -d "$BOOT_OVERLAYS" ] || die "Cannot find overlays directory: ${BOOT_OVERLAYS}"
    command -v git    >/dev/null 2>&1 || die "git is not installed"
    command -v make   >/dev/null 2>&1 || warn "make not found - will be installed via apt"
    command -v python3 >/dev/null 2>&1 || die "python3 is not installed"
}

create_directories() {
    log "Creating working directories..."
    sudo mkdir -p "$WORK_DIR"
    sudo chown "${CURRENT_USER}:${CURRENT_USER}" "$WORK_DIR"
    mkdir -p "$SYSTEMD_USER_DIR"
    mkdir -p "$WIREPLUMBER_CONF_DIR"
}

system_upgrade() {
    section "System upgrade"
    # Run apt upgrade BEFORE building the VocalFusion kernel module.
    # This ensures we build against the latest installed kernel.
    # If a new kernel was installed, the subsequent reboot will boot into it
    # and VocalFusion will be built against the correct version.
    info "Running apt upgrade to ensure latest kernel is installed..."
    apt_update
    if sudo apt-get upgrade -y --no-install-recommends >> "${MARK2_LOG}" 2>&1; then
        log "System packages upgraded"
        # Re-detect kernel version after upgrade — it may have changed
        KERNEL_VERSION=$(uname -r)
        MODULE_PATH="/lib/modules/${KERNEL_VERSION}/${VOCALFUSION_MODULE}.ko"
        log "Kernel version: ${KERNEL_VERSION}"
    else
        warn "apt upgrade had errors — check ${MARK2_LOG}"
        warn "Continuing anyway — VocalFusion will be built against current kernel"
    fi
}

install_kernel_headers() {
    log "Installing kernel headers and build tools..."
    sudo chmod 1777 /tmp
    apt_install \
        "${KERNEL_HEADERS_PKG}" build-essential git \
        python3-venv python3-pip python3-dev
}

update_eeprom() {
    log "Setting EEPROM release to 'latest'..."
    if [ -f "$EEPROM_CONFIG" ]; then
        sudo sed -i 's/^FIRMWARE_RELEASE_STATUS=.*/FIRMWARE_RELEASE_STATUS="latest"/' "$EEPROM_CONFIG"
        if ! grep -q "FIRMWARE_RELEASE_STATUS=" "$EEPROM_CONFIG"; then
            echo 'FIRMWARE_RELEASE_STATUS="latest"' | sudo tee -a "$EEPROM_CONFIG" > /dev/null
        fi
    fi
    if command -v rpi-eeprom-update >/dev/null 2>&1; then
        sudo rpi-eeprom-update -a || warn "EEPROM update failed - continuing anyway"
    else
        warn "rpi-eeprom-update not found - skipping"
    fi
}

build_vocalfusion_driver() {
    info "Building VocalFusion audio driver (this may take a few minutes)..."
    info "Cloning VocalFusion driver..."
    sudo git clone --quiet https://github.com/OpenVoiceOS/VocalFusionDriver "$VOCALFUSION_SRC" 2>/dev/null \
        || (cd "$VOCALFUSION_SRC" && sudo git pull --quiet)

    info "Building vocalfusion-soundcard.ko kernel module..."
    CPU_COUNT=$(nproc)
    (cd "$VOCALFUSION_DRIVER_DIR" && sudo make -j"$CPU_COUNT" \
        KDIR="/lib/modules/${KERNEL_VERSION}/build" all \
        >> "${MARK2_LOG}" 2>&1) \
        || die "Kernel module build failed — check ${MARK2_LOG}"

    log "Copying kernel module..."
    sudo cp "${VOCALFUSION_DRIVER_DIR}/${VOCALFUSION_MODULE}.ko" "$MODULE_PATH"
    sudo depmod -a

    log "Copying DTBO overlay files to boot..."
    for overlay in sj201 sj201-buttons-overlay sj201-rev10-pwm-fan-overlay; do
        dtbo_file="${overlay}${PI5_SUFFIX}.dtbo"
        if [ -f "${VOCALFUSION_SRC}/${dtbo_file}" ]; then
            sudo cp "${VOCALFUSION_SRC}/${dtbo_file}" "${BOOT_OVERLAYS}/${dtbo_file}"
            log "  Copied: ${dtbo_file}"
        else
            warn "  DTBO not found: ${dtbo_file} - skipping"
        fi
    done
}

configure_boot_config() {
    log "Configuring ${BOOT_CONFIG}..."

    # Enable UART for SJ201 initialization
    if grep -q "^enable_uart=" "$BOOT_CONFIG"; then
        sudo sed -i 's/^enable_uart=.*/enable_uart=1/' "$BOOT_CONFIG"
    else
        echo "enable_uart=1" | sudo tee -a "$BOOT_CONFIG" > /dev/null
    fi

    # Enable SPI (required for xvf3510-flash to access /dev/spidev0.0)
    if grep -q "^#dtparam=spi=on" "$BOOT_CONFIG"; then
        sudo sed -i 's/^#dtparam=spi=on/dtparam=spi=on/' "$BOOT_CONFIG"
        log "  Enabled: dtparam=spi=on (was commented out)"
    elif ! grep -q "^dtparam=spi=on" "$BOOT_CONFIG"; then
        echo "dtparam=spi=on" | sudo tee -a "$BOOT_CONFIG" > /dev/null
        log "  Added: dtparam=spi=on"
    else
        log "  Already present: dtparam=spi=on"
    fi

    # Enable I2C (required for SJ201 LED and TAS5806 amp init)
    if grep -q "^#dtparam=i2c_arm=on" "$BOOT_CONFIG"; then
        sudo sed -i 's/^#dtparam=i2c_arm=on/dtparam=i2c_arm=on/' "$BOOT_CONFIG"
        log "  Enabled: dtparam=i2c_arm=on (was commented out)"
    elif ! grep -q "^dtparam=i2c_arm=on" "$BOOT_CONFIG"; then
        echo "dtparam=i2c_arm=on" | sudo tee -a "$BOOT_CONFIG" > /dev/null
        log "  Added: dtparam=i2c_arm=on"
    else
        log "  Already present: dtparam=i2c_arm=on"
    fi

    # Add dtoverlay lines for SJ201, buttons and PWM fan
    for overlay in sj201 sj201-buttons-overlay sj201-rev10-pwm-fan-overlay; do
        overlay_line="dtoverlay=${overlay}${PI5_SUFFIX}"
        if ! grep -q "^${overlay_line}$" "$BOOT_CONFIG"; then
            echo "$overlay_line" | sudo tee -a "$BOOT_CONFIG" > /dev/null
            log "  Added: ${overlay_line}"
        else
            log "  Already present: ${overlay_line}"
        fi
    done

    # Touchscreen backlight overlay
    if ! grep -q "^dtoverlay=rpi-backlight$" "$BOOT_CONFIG"; then
        echo "dtoverlay=rpi-backlight" | sudo tee -a "$BOOT_CONFIG" > /dev/null
        log "  Added: dtoverlay=rpi-backlight"
    fi

    # Mark II 4.3" Waveshare 800x480 DSI display
    if ! grep -q "^dtoverlay=vc4-kms-dsi-waveshare-800x480$" "$BOOT_CONFIG"; then
        echo "dtoverlay=vc4-kms-dsi-waveshare-800x480" | sudo tee -a "$BOOT_CONFIG" > /dev/null
        log "  Added: dtoverlay=vc4-kms-dsi-waveshare-800x480 (Mark II touchscreen)"
    fi

    # Remove vc4-fkms-v3d if present (deprecated on Trixie/kernel 6.x)
    sudo sed -i '/^dtoverlay=vc4-fkms-v3d$/d' "$BOOT_CONFIG" 2>/dev/null || true
    sudo sed -i '/^disable_fw_kms_setup/d' "$BOOT_CONFIG" 2>/dev/null || true
    if ! grep -q "^dtoverlay=vc4-kms-v3d$" "$BOOT_CONFIG"; then
        echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$BOOT_CONFIG" > /dev/null
        log "  Added: dtoverlay=vc4-kms-v3d (touchscreen/display)"
    fi
}

configure_modules_load() {
    log "Configuring automatic loading of vocalfusion module..."
    echo "${VOCALFUSION_MODULE}" | sudo tee "$MODULES_LOAD_CONF" > /dev/null
}

setup_sj201_venv() {
    log "Creating Python venv for SJ201..."

    # Trixie (Debian 13) ships Python 3.13 as default.
    # RPi.GPIO is not available for 3.13 yet - use --system-site-packages
    # as a workaround so system-installed GPIO packages are accessible in the venv.
    PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    log "Python version: ${PYTHON_VERSION}"

    if python3 -c "import sys; exit(0 if sys.version_info >= (3,13) else 1)" 2>/dev/null; then
        warn "Python 3.13+ detected (Trixie) - using --system-site-packages for GPIO compatibility"
        apt_install python3-rpi-lgpio python3-smbus2 python3-libgpiod 2>/dev/null || \
            warn "Some system GPIO packages not available - continuing"
        python3 -m venv --system-site-packages "$SJ201_VENV"
    else
        python3 -m venv "$SJ201_VENV"
    fi

    "${SJ201_VENV}/bin/pip" install --quiet --upgrade pip
    "${SJ201_VENV}/bin/pip" install --quiet \
        Adafruit-Blinka \
        smbus2 \
        gpiod || warn "Some pip packages failed - GPIO may work via system-site-packages"
}

download_sj201_firmware() {
    log "Installing SJ201 firmware and scripts from assets/..."

    # xvf3510-flash (vendored Python script)
    sudo cp "${ASSETS_DIR}/xvf3510-flash" "${WORK_DIR}/xvf3510-flash"
    sudo chmod +x "${WORK_DIR}/xvf3510-flash"

    # init_tas5806 (vendored Python script)
    sudo cp "${ASSETS_DIR}/init_tas5806.py" "${WORK_DIR}/init_tas5806"
    sudo chmod +x "${WORK_DIR}/init_tas5806"

    # XVF3510 firmware binary (vendored in assets/)
    sudo cp "${ASSETS_DIR}/app_xvf3510_int_spi_boot_v4_2_0.bin" "${WORK_DIR}/app_xvf3510_int_spi_boot_v4_2_0.bin"
    log "Firmware copied from assets/"

    sudo chown -R "${CURRENT_USER}:${CURRENT_USER}" "$WORK_DIR"
}

create_sj201_service() {
    log "Creating sj201.service systemd unit..."
    cat > "${SYSTEMD_USER_DIR}/sj201.service" << EOF
[Unit]
Documentation=https://github.com/MycroftAI/mark-ii-hardware-testing/blob/main/README.md
Description=SJ201 microphone initialization
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${SJ201_VENV}
ExecStart=/usr/bin/sudo -E env PATH=/usr/local/bin:/usr/sbin:/usr/bin:/bin ${SJ201_VENV}/bin/python ${WORK_DIR}/xvf3510-flash --direct ${WORK_DIR}/app_xvf3510_int_spi_boot_v4_2_0.bin --verbose
ExecStartPost=/usr/bin/env PATH=/usr/local/bin:/usr/sbin:/usr/bin:/bin ${SJ201_VENV}/bin/python ${WORK_DIR}/init_tas5806
Restart=on-failure
RestartSec=5s
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

    log "Enabling sj201.service..."
    systemctl --user daemon-reload
    systemctl --user enable sj201.service
}

configure_wireplumber() {
    log "Configuring WirePlumber SJ201 audio profile..."
    cat > "${WIREPLUMBER_CONF_DIR}/90-sj201-profile.conf" << 'EOF'
monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "alsa_card.platform-soc_sound"
      }
    ]
    actions = {
      update-props = {
        api.acp.auto-profile = false
        api.acp.auto-port = false
        device.profile = "pro-audio"
      }
    }
  }
]
EOF
    # Remove legacy Lua configuration if present
    rm -f "${USER_HOME}/.config/wireplumber/main.lua.d/50-alsa-config.lua"
    rm -f "${USER_HOME}/.config/wireplumber/main.lua.d/50-alsa-config.lua.disabled-0.5"
}

cleanup_vocalfusion_src() {
    log "Cleaning up: removing VocalFusion source..."
    sudo rm -rf "$VOCALFUSION_SRC"
}

install_kernel_watchdog() {
    section "Kernel Update Watchdog"
    log "Installing VocalFusion kernel module watchdog..."

    MARK2_DIR="${USER_HOME}/.config/mark2"
    mkdir -p "$MARK2_DIR"
    REBUILD_SCRIPT="${MARK2_DIR}/rebuild-vocalfusion.sh"

    cat > "$REBUILD_SCRIPT" << 'SHEOF'
#!/bin/bash
# Rebuild VocalFusion kernel module if needed after kernel update
set -euo pipefail
KERNEL=$(uname -r)
MODULE_PATH="/lib/modules/${KERNEL}/vocalfusion-soundcard.ko"
SRC_PATH="/usr/src/vocalfusion-rebuild"
LOG="/var/log/mark2-vocalfusion-rebuild.log"

echo "[$(date)] Checking VocalFusion module for kernel ${KERNEL}" | sudo tee -a "$LOG"
if [ -f "$MODULE_PATH" ]; then
    echo "[$(date)] Module exists for ${KERNEL} - no rebuild needed" | sudo tee -a "$LOG"
    exit 0
fi
echo "[$(date)] Module missing for ${KERNEL} - rebuilding..." | sudo tee -a "$LOG"

DEBIAN_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-0}")
HEADERS_PKG=$( [ "$DEBIAN_VERSION" = "13" ] && echo "linux-headers-rpi-v8" || echo "raspberrypi-kernel-headers" )
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends "$HEADERS_PKG" build-essential >> "$LOG" 2>&1

if [ -d "$SRC_PATH/.git" ]; then
    (cd "$SRC_PATH" && sudo git pull --quiet)
else
    sudo git clone --quiet https://github.com/OpenVoiceOS/VocalFusionDriver "$SRC_PATH"
fi

(cd "${SRC_PATH}/driver" && sudo make -j"$(nproc)" KDIR="/lib/modules/${KERNEL}/build" all) 2>&1 | sudo tee -a "$LOG"
sudo cp "${SRC_PATH}/driver/vocalfusion-soundcard.ko" "$MODULE_PATH"
sudo depmod -a

BOOT_OVERLAYS=$([ -d /boot/firmware/overlays ] && echo /boot/firmware/overlays || echo /boot/overlays)
for f in sj201 sj201-buttons-overlay sj201-rev10-pwm-fan-overlay; do
    for suffix in "" "-pi5"; do
        src="${SRC_PATH}/${f}${suffix}.dtbo"
        [ -f "$src" ] && sudo cp "$src" "${BOOT_OVERLAYS}/${f}${suffix}.dtbo"
    done
done

echo "[$(date)] VocalFusion rebuilt for ${KERNEL}" | sudo tee -a "$LOG"
systemctl --user restart sj201.service 2>/dev/null || true
SHEOF
    chmod +x "$REBUILD_SCRIPT"

    sudo tee /etc/systemd/system/mark2-vocalfusion-watchdog.service > /dev/null << EOF
[Unit]
Description=Mark II VocalFusion kernel module watchdog
DefaultDependencies=no
Before=sj201.service
After=network-online.target

[Service]
Type=oneshot
ExecStart=${REBUILD_SCRIPT}
RemainAfterExit=yes
User=root

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable mark2-vocalfusion-watchdog.service

    # Safe weekly update cron (Sunday 03:00)
    UPDATE_SCRIPT="${MARK2_DIR}/safe-update.sh"
    cat > "$UPDATE_SCRIPT" << 'SHEOF'
#!/bin/bash
LOG="/var/log/mark2-updates.log"
echo "[$(date)] Starting safe update" | tee -a "$LOG"
apt-get update -qq 2>&1 | tee -a "$LOG"
apt-get upgrade -y --no-install-recommends 2>&1 | tee -a "$LOG"
echo "[$(date)] Update complete" | tee -a "$LOG"
SHEOF
    chmod +x "$UPDATE_SCRIPT"

    sudo tee /etc/cron.d/mark2-updates > /dev/null << EOF
# Mark II safe weekly update - Sunday 03:00
0 3 * * 0 root ${UPDATE_SCRIPT}
EOF
    sudo chmod 644 /etc/cron.d/mark2-updates

    log "Kernel watchdog installed - VocalFusion auto-rebuilds after kernel updates"
    log "Safe weekly updates scheduled: Sunday 03:00"
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo "========================================"
echo "  Mycroft Mark II Hardware Setup"
echo "  User:    ${CURRENT_USER}"
echo "  Boot:    ${BOOT_DIR}"
echo "  Pi5 suffix: '${PI5_SUFFIX:-none}'"
echo "========================================"
echo ""

check_requirements
create_directories
system_upgrade
install_kernel_headers
update_eeprom
build_vocalfusion_driver
configure_boot_config
configure_modules_load
setup_sj201_venv
download_sj201_firmware
create_sj201_service
configure_wireplumber
cleanup_vocalfusion_src
install_kernel_watchdog

echo ""
echo "========================================"
log "Hardware setup complete!"
echo ""
if [ "${MARK2_MODULE_CONFIRMED:-0}" = "1" ]; then
    echo "  The device will now reboot automatically."
    echo "  After reboot, SSH back in and run:"
    echo ""
    echo "    ./mark2-assist/install.sh"
    echo ""
    echo "  Installation will continue from where it left off."
else
    echo "  Next steps:"
    echo "  1. Reboot the device:  sudo reboot"
    echo "  2. After reboot:       systemctl --user status sj201.service"
    echo "  3. Test audio:         aplay -l"
    echo "  4. Install whatever you want on top (Wyoming, OVOS, HA, etc.)"
fi
echo "========================================"
echo ""
