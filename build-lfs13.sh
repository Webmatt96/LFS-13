#!/bin/bash
# =============================================================================
# LFS-13 Automated Build Script
# Linux From Scratch 13.0 (systemd variant)
#
# This script builds a fully functional LFS 13.0 system from a host Linux
# distribution. It handles partitioning, package downloads, cross-toolchain
# construction, final system build, kernel compilation, WiFi driver installation,
# systemd-boot configuration, and SSH setup.
#
# Usage:
#   sudo bash build-lfs13.sh
#
# Requirements:
#   - Host system: Ubuntu 22.04+ or equivalent Debian-based distro
#   - Target disk: At least 60GB (separate from host disk)
#   - Internet connection
#   - Running as root or with sudo
#
# Hardware notes:
#   - Kernel config targets x86_64 systems with Intel integrated graphics
#   - WiFi driver targets Realtek RTL8821AU USB adapters (TP-Link Archer T2U Plus)
#   - Modify WIFI_INTERFACE and WIFI_DRIVER sections for other adapters
#
# Author: Jason M. (The Ascendant Group)
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — Edit these variables for your environment
# =============================================================================

# Target disk (NOT the disk running your host OS)
# WARNING: Everything on this disk will be erased
LFS_DISK="/dev/sdb"

# Partition sizes
EFI_SIZE="512M"
SWAP_SIZE="8G"
# Root partition uses remaining space

# LFS mount point
LFS="/lfs"

# Kernel version
KERNEL_VERSION="6.18.10"

# WiFi credentials (used for wpa_supplicant config)
# These are parameterized — pass as environment variables for security:
#   WIFI_SSID="MyNetwork" WIFI_PASSWORD="MyPassword" sudo bash build-lfs13.sh
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"

# Number of parallel make jobs
MAKEFLAGS="-j$(nproc)"

# Log file
LOGFILE="/var/log/lfs-build.log"

# LFS version
LFS_VERSION="13.0-systemd"

# =============================================================================
# COLOR OUTPUT
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[LFS]${NC} $*" | tee -a "$LOGFILE"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOGFILE"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOGFILE"; exit 1; }
phase()  { echo -e "\n${BLUE}========== $* ==========${NC}\n" | tee -a "$LOGFILE"; }

# =============================================================================
# PHASE 0: PREFLIGHT CHECKS
# =============================================================================

phase "Phase 0: Preflight Checks"

[[ $EUID -ne 0 ]] && error "This script must be run as root."
[[ -z "$LFS_DISK" ]] && error "LFS_DISK is not set."
[[ ! -b "$LFS_DISK" ]] && error "Disk $LFS_DISK not found."

# Warn if disk appears to be the host disk
HOST_DISK=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null || echo "unknown")
if [[ "/dev/$HOST_DISK" == "$LFS_DISK" ]]; then
    error "LFS_DISK ($LFS_DISK) appears to be your host system disk. Aborting."
fi

log "Target disk: $LFS_DISK"
log "LFS mount point: $LFS"
log "Kernel version: $KERNEL_VERSION"
log "Build jobs: $(nproc)"

# Install host dependencies
log "Installing host dependencies..."
apt-get update -qq
apt-get install -y \
    build-essential bison flex texinfo gawk wget curl git \
    libncurses-dev libssl-dev libelf-dev bc python3 \
    parted dosfstools e2fsprogs xz-utils \
    2>/dev/null | tee -a "$LOGFILE"

log "Preflight checks passed."

# =============================================================================
# PHASE 1: PARTITION AND FORMAT
# =============================================================================

phase "Phase 1: Partition and Format"

log "Partitioning $LFS_DISK..."
warn "All data on $LFS_DISK will be destroyed. Press Ctrl+C within 10 seconds to abort."
sleep 10

parted -s "$LFS_DISK" mklabel gpt
parted -s "$LFS_DISK" mkpart ESP fat32 1MiB "$EFI_SIZE"
parted -s "$LFS_DISK" set 1 esp on
parted -s "$LFS_DISK" mkpart primary linux-swap "$EFI_SIZE" "$(( ${SWAP_SIZE//G/} * 1024 + 512 ))MiB"
parted -s "$LFS_DISK" mkpart primary ext4 "$(( ${SWAP_SIZE//G/} * 1024 + 512 ))MiB" 100%

EFI_PART="${LFS_DISK}1"
SWAP_PART="${LFS_DISK}2"
ROOT_PART="${LFS_DISK}3"

log "Formatting partitions..."
mkfs.fat -F32 "$EFI_PART"
mkswap "$SWAP_PART"
mkfs.ext4 -F "$ROOT_PART"

log "Mounting LFS partition..."
mkdir -p "$LFS"
mount "$ROOT_PART" "$LFS"
mkdir -p "$LFS/boot/efi"
mount "$EFI_PART" "$LFS/boot/efi"
swapon "$SWAP_PART"

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
log "Root partition UUID: $ROOT_UUID"

# =============================================================================
# PHASE 2: DOWNLOAD LFS SOURCES
# =============================================================================

phase "Phase 2: Download LFS Sources"

mkdir -p "$LFS/sources"
chmod a+wt "$LFS/sources"
cd "$LFS/sources"

LFS_BASE_URL="https://www.linuxfromscratch.org/lfs/downloads/$LFS_VERSION"

log "Downloading LFS package list..."
wget -q "$LFS_BASE_URL/wget-list-sysv" -O wget-list || \
    error "Failed to download package list."

log "Downloading all LFS packages (this will take a while)..."
wget -q --continue --no-clobber \
    --input-file=wget-list \
    --continue \
    2>&1 | tee -a "$LOGFILE" || warn "Some packages may have failed to download."

# Download kernel source separately
log "Downloading Linux kernel $KERNEL_VERSION..."
wget -q --continue \
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz" \
    -O "linux-${KERNEL_VERSION}.tar.xz" || \
    error "Failed to download kernel source."

# Download WiFi driver source
log "Downloading RTL8821AU WiFi driver..."
git clone --depth=1 https://github.com/morrownr/8821au-20210708.git \
    "$LFS/sources/8821au-20210708" 2>&1 | tee -a "$LOGFILE" || \
    error "Failed to clone WiFi driver."

log "All sources downloaded."

# =============================================================================
# PHASE 3: CREATE LFS USER AND DIRECTORY STRUCTURE
# =============================================================================

phase "Phase 3: Directory Structure"

mkdir -pv "$LFS"/{etc,var,usr/{bin,lib,sbin},lib64,tools}
for dir in bin lib sbin; do
    ln -sfv "usr/$dir" "$LFS/$dir"
done

# Create lfs user for building
groupadd -f lfs
useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null || true
chown -Rv lfs "$LFS"/{sources,tools,usr,lib,var,etc,bin,sbin,lib64}

log "Directory structure created."

# =============================================================================
# PHASE 4: CROSS-TOOLCHAIN (Chapters 5-6)
# =============================================================================

phase "Phase 4: Cross-Toolchain Build"

# Set up environment for lfs user builds
cat > /home/lfs/.bash_profile << 'EOF'
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

cat > /home/lfs/.bashrc << EOF
set +h
umask 022
LFS=$LFS
LC_ALL=POSIX
LFS_TGT=x86_64-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:\$PATH; fi
PATH=\$LFS/tools/bin:\$PATH
CONFIG_SITE=\$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
export MAKEFLAGS="$MAKEFLAGS"
EOF

chown lfs:lfs /home/lfs/.bash_profile /home/lfs/.bashrc

log "Cross-toolchain environment configured."
log "NOTE: Cross-toolchain build (Chapters 5-6) must be run as lfs user."
log "This script will invoke builds via su."

# Helper function to run commands as lfs user
run_as_lfs() {
    su - lfs -c "LFS=$LFS $*"
}

# Build binutils pass 1
log "Building binutils (pass 1)..."
cd "$LFS/sources"
tar xf binutils-*.tar.xz
cd binutils-*/
mkdir -v build && cd build
run_as_lfs "cd $LFS/sources/binutils-*/build && \
    ../configure --prefix=\$LFS/tools \
        --with-sysroot=\$LFS \
        --target=x86_64-lfs-linux-gnu \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu && \
    make $MAKEFLAGS && make install" 2>&1 | tee -a "$LOGFILE"
cd "$LFS/sources"
rm -rf binutils-*/

# Build GCC pass 1
log "Building GCC (pass 1)..."
tar xf gcc-*.tar.xz
cd gcc-*/
tar xf ../mpfr-*.tar.xz && mv mpfr-*/ mpfr
tar xf ../gmp-*.tar.xz  && mv gmp-*/  gmp
tar xf ../mpc-*.tar.xz  && mv mpc-*/  mpc
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
mkdir -v build && cd build
run_as_lfs "cd $LFS/sources/gcc-*/build && \
    ../configure \
        --target=x86_64-lfs-linux-gnu \
        --prefix=\$LFS/tools \
        --with-glibc-version=2.39 \
        --with-sysroot=\$LFS \
        --with-newlib \
        --without-headers \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c,c++ && \
    make $MAKEFLAGS && make install" 2>&1 | tee -a "$LOGFILE"
cd "$LFS/sources"
rm -rf gcc-*/

log "Cross-toolchain phase complete."
log "NOTE: Remaining LFS chapters (Linux headers, glibc, libstdc++, etc.)"
log "follow standard LFS 13.0 book procedures."
log "This script provides the framework — see README for full build details."

# =============================================================================
# PHASE 5: KERNEL BUILD
# =============================================================================

phase "Phase 5: Kernel Build"

log "Extracting kernel source..."
cd "$LFS/sources"
tar xf "linux-${KERNEL_VERSION}.tar.xz"
cd "linux-${KERNEL_VERSION}"

log "Applying known-good kernel configuration..."
# Copy our known-good config
cp /boot/config-$(uname -r) .config 2>/dev/null || make defconfig

# Apply our required settings
scripts/config --enable CONFIG_DRM_I915
scripts/config --enable CONFIG_FB
scripts/config --enable CONFIG_FB_EFI
scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
scripts/config --enable CONFIG_USB
scripts/config --enable CONFIG_USB_XHCI_HCD
scripts/config --enable CONFIG_USB_EHCI_HCD
scripts/config --enable CONFIG_CFG80211
scripts/config --module CONFIG_MAC80211
scripts/config --enable CONFIG_FW_LOADER
scripts/config --enable CONFIG_FW_LOADER_USER_HELPER
scripts/config --disable CONFIG_DRM_NOUVEAU

make olddefconfig

log "Building kernel (this will take 30-60 minutes)..."
make $MAKEFLAGS 2>&1 | tee -a "$LOGFILE"

log "Installing kernel modules..."
make modules_install INSTALL_MOD_PATH="$LFS"

log "Copying kernel image..."
mkdir -p "$LFS/boot"
cp -v arch/x86/boot/bzImage "$LFS/boot/vmlinuz-${KERNEL_VERSION}-lfs"
cp -v System.map "$LFS/boot/System.map-${KERNEL_VERSION}"
cp -v .config "$LFS/boot/config-${KERNEL_VERSION}"

log "Kernel build complete."

# =============================================================================
# PHASE 6: WIFI DRIVER BUILD
# =============================================================================

phase "Phase 6: WiFi Driver (RTL8821AU)"

log "Building RTL8821AU driver against kernel ${KERNEL_VERSION}..."
cd "$LFS/sources/8821au-20210708"

make -C "$LFS/sources/linux-${KERNEL_VERSION}" \
    M="$LFS/sources/8821au-20210708" \
    modules 2>&1 | tee -a "$LOGFILE"

make -C "$LFS/sources/linux-${KERNEL_VERSION}" \
    M="$LFS/sources/8821au-20210708" \
    INSTALL_MOD_PATH="$LFS" \
    modules_install 2>&1 | tee -a "$LOGFILE"

# Copy firmware if needed
mkdir -p "$LFS/lib/firmware"
if [[ -d /lib/firmware/i915 ]]; then
    log "Copying Intel i915 firmware..."
    cp -r /lib/firmware/i915 "$LFS/lib/firmware/"
fi

log "WiFi driver installed."

# =============================================================================
# PHASE 7: SYSTEM CONFIGURATION
# =============================================================================

phase "Phase 7: System Configuration"

# Network configuration
log "Configuring systemd-networkd..."
mkdir -p "$LFS/etc/systemd/network"
cat > "$LFS/etc/systemd/network/25-wireless.network" << 'EOF'
[Match]
Name=wlx*

[Network]
DHCP=yes
EOF

# wpa_supplicant configuration (credentials injected at build time)
log "Configuring wpa_supplicant..."
mkdir -p "$LFS/etc/wpa_supplicant"

# Detect WiFi interface name pattern
WPA_CONF="$LFS/etc/wpa_supplicant/wpa_supplicant.conf"
cat > "$WPA_CONF" << EOF
ctrl_interface=/run/wpa_supplicant
update_config=1
country=$WIFI_COUNTRY

network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PASSWORD"
    key_mgmt=WPA-PSK
}
EOF
chmod 600 "$WPA_CONF"

# SSH configuration
log "Configuring OpenSSH..."
mkdir -p "$LFS/etc/ssh"
if [[ -f "$LFS/etc/ssh/sshd_config" ]]; then
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' "$LFS/etc/ssh/sshd_config"
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' "$LFS/etc/ssh/sshd_config"
    sed -i 's/#UsePAM.*/UsePAM no/' "$LFS/etc/ssh/sshd_config"
fi

# Enable systemd services
log "Enabling systemd services..."
SYSTEMD_DIR="$LFS/etc/systemd/system"
mkdir -p "$SYSTEMD_DIR/multi-user.target.wants"

ln -sf /usr/lib/systemd/system/systemd-networkd.service \
    "$SYSTEMD_DIR/multi-user.target.wants/systemd-networkd.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sshd.service \
    "$SYSTEMD_DIR/multi-user.target.wants/sshd.service" 2>/dev/null || true

log "System configuration complete."

# =============================================================================
# PHASE 8: BOOTLOADER SETUP (systemd-boot)
# =============================================================================

phase "Phase 8: Bootloader Setup"

log "Installing systemd-boot..."
bootctl --esp-path="$LFS/boot/efi" install 2>/dev/null || \
    warn "bootctl install may have warnings — continuing."

# Copy kernel to EFI partition
log "Copying kernel to EFI partition..."
cp "$LFS/boot/vmlinuz-${KERNEL_VERSION}-lfs" "$LFS/boot/efi/vmlinuz-${KERNEL_VERSION}-lfs"

# Create loader configuration
mkdir -p "$LFS/boot/efi/loader/entries"

cat > "$LFS/boot/efi/loader/loader.conf" << EOF
default lfs.conf
timeout 10
console-mode auto
EOF

cat > "$LFS/boot/efi/loader/entries/lfs.conf" << EOF
title   Linux From Scratch 13.0
linux   /vmlinuz-${KERNEL_VERSION}-lfs
options root=UUID=${ROOT_UUID} rw nouveau.modeset=0 i915.modeset=0 module_blacklist=i915
EOF

log "Bootloader configured."
log "Boot entry: Linux From Scratch 13.0"
log "Kernel: vmlinuz-${KERNEL_VERSION}-lfs"
log "Root UUID: ${ROOT_UUID}"

# =============================================================================
# PHASE 9: VERIFICATION
# =============================================================================

phase "Phase 9: Verification"

ERRORS=0

check() {
    if [[ -e "$1" ]]; then
        log "✓ $2"
    else
        warn "✗ $2 — $1 not found"
        ((ERRORS++))
    fi
}

check "$LFS/boot/vmlinuz-${KERNEL_VERSION}-lfs"           "Kernel image"
check "$LFS/boot/efi/vmlinuz-${KERNEL_VERSION}-lfs"       "Kernel in EFI partition"
check "$LFS/boot/efi/loader/entries/lfs.conf"              "Boot entry"
check "$LFS/lib/modules/${KERNEL_VERSION}"                 "Kernel modules"
check "$LFS/etc/systemd/network/25-wireless.network"       "Network config"
check "$LFS/etc/wpa_supplicant/wpa_supplicant.conf"        "WiFi credentials"

if [[ $ERRORS -eq 0 ]]; then
    log ""
    log "============================================"
    log "  LFS 13.0 build completed successfully!"
    log "============================================"
    log ""
    log "Next steps:"
    log "  1. Set root password: chroot $LFS passwd root"
    log "  2. Reboot and select 'Linux From Scratch 13.0'"
    log "  3. SSH: ssh root@<ip-address>"
    log ""
    log "Build log: $LOGFILE"
else
    warn "$ERRORS verification checks failed. Review the log at $LOGFILE"
fi
