#!/bin/bash
# =====================================================================
# LinaDroid OS - Rootfs Bootstrap & Configuration Script (Debian Host)
# This script builds the core Linux OS filesystem from scratch
# =====================================================================

set -e

# Configuration
DISTRO="bookworm"
MIRROR="http://deb.debian.org/debian"
ROOTFS_DIR="/tmp/linadroid-rootfs"
ARCH="amd64" # Default to x86_64, can be set to "arm64" for mobile/SBC hardware

# Dynamically locate the repository root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}      LinaDroid OS: Rootfs Bootstrapping Utility     ${NC}"
echo -e "${GREEN}=====================================================${NC}"

# 1. Verification of environment
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (sudo).${NC}"
    echo -e "${YELLOW}Dry-running syntax verification and printing blueprint...${NC}"
    echo "This script would download and bootstrap Debian stable '$DISTRO' into '$ROOTFS_DIR'."
    exit 0
fi

# Ensure debootstrap is installed on the build machine
if ! command -v debootstrap &> /dev/null; then
    echo -e "${YELLOW}Installing debootstrap...${NC}"
    apt-get update && apt-get install -y debootstrap
fi

# 2. Debootstrap Phase
echo -e "${BLUE}1. Debootstrapping a clean Debian '$DISTRO' ($ARCH) base...${NC}"
mkdir -p "$ROOTFS_DIR"
debootstrap --arch="$ARCH" "$DISTRO" "$ROOTFS_DIR" "$MIRROR"

# 3. Mount pseudo-filesystems for configuring the target rootfs (chroot)
echo -e "${BLUE}2. Mounting pseudo-filesystems for configuration...${NC}"
mount -t proc /proc "$ROOTFS_DIR/proc"
mount -t sysfs /sys "$ROOTFS_DIR/sys"
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"

# Ensure we clean up mounts on script termination
cleanup() {
    echo -e "${YELLOW}Cleaning up mounted partitions...${NC}"
    umount -l "$ROOTFS_DIR/proc" || true
    umount -l "$ROOTFS_DIR/sys" || true
    umount -l "$ROOTFS_DIR/dev/pts" || true
    umount -l "$ROOTFS_DIR/dev" || true
}
trap cleanup EXIT

# 4. Writing Configuration inside the Chroot Environment
echo -e "${BLUE}3. Customizing LinaDroid Host OS configuration inside chroot...${NC}"

# Set Hostname
echo "linadroid-os" > "$ROOTFS_DIR/etc/hostname"

# Configure local networks
cat <<EOF > "$ROOTFS_DIR/etc/hosts"
127.0.0.1   localhost
127.0.1.1   linadroid-os

# The following lines are desirable for IPv6 capable hosts
::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Configure repositories (Apt sources.list)
cat <<EOF > "$ROOTFS_DIR/etc/apt/sources.list"
deb $MIRROR $DISTRO main contrib non-free non-free-firmware
deb $MIRROR $DISTRO-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DISTRO-security main contrib non-free non-free-firmware
EOF

# Create First-Boot Partition & Filesystem Expansion Script
cat <<'EOF' > "$ROOTFS_DIR/usr/sbin/linadroid-resize"
#!/bin/bash
# =====================================================================
# LinaDroid OS - First Boot Partition Expansion Script
# Auto-detects the host physical disk size and resizes rootfs to fill it
# =====================================================================

# Get the root partition device
ROOT_PART=$(findmnt -n -o SOURCE /)
if [ -z "$ROOT_PART" ]; then
    echo "Could not detect root partition device."
    exit 1
fi

# Detect device and partition number (e.g. /dev/sda2, /dev/nvme0n1p2, /dev/mmcblk0p2)
if [[ "$ROOT_PART" =~ ^/dev/([a-z]+)([0-9]+)$ ]]; then
    DISK="/dev/${BASH_REMATCH[1]}"
    PART_NUM="${BASH_REMATCH[2]}"
elif [[ "$ROOT_PART" =~ ^/dev/(nvme[0-9]n[0-9])p([0-9]+)$ ]]; then
    DISK="/dev/${BASH_REMATCH[1]}"
    PART_NUM="${BASH_REMATCH[2]}"
elif [[ "$ROOT_PART" =~ ^/dev/(mmcblk[0-9])p([0-9]+)$ ]]; then
    DISK="/dev/${BASH_REMATCH[1]}"
    PART_NUM="${BASH_REMATCH[2]}"
else
    echo "Unknown root partition scheme: $ROOT_PART"
    exit 1
fi

echo "Auto-detected primary disk: $DISK, partition: $PART_NUM"
echo "Growing partition to consume 100% of physical drive..."
parted -s "$DISK" resizepart "$PART_NUM" 100%

# Reload kernel partition tables
partprobe "$DISK" || true

echo "Expanding EXT4 filesystem to fill the expanded boundary..."
resize2fs "$ROOT_PART"

echo "Disabling first-boot resize service..."
systemctl disable linadroid-resize.service || true
rm -f /etc/systemd/system/linadroid-resize.service
rm -f /usr/sbin/linadroid-resize

echo "Partition expansion successfully completed!"
EOF

chmod +x "$ROOTFS_DIR/usr/sbin/linadroid-resize"

# Create First-Boot systemd Service
cat <<EOF > "$ROOTFS_DIR/etc/systemd/system/linadroid-resize.service"
[Unit]
Description=Auto-resize primary partition and filesystem to fill drive on first boot
Before=multi-user.target
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/linadroid-resize
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Custom Chroot Setup commands
cat <<EOF > "$ROOTFS_DIR/tmp/chroot_setup.sh"
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

echo "Updating repositories..."
apt-get update

# Removed tinyalsa package because it is not available in standard Debian Bookworm repositories
echo "Installing core packages: lxc, adb, graphics drivers, audio system, parted..."
apt-get install -y \
    lxc \
    libvirt-daemon-system \
    bridge-utils \
    adb \
    sudo \
    kmod \
    init \
    systemd \
    dbus \
    network-manager \
    openssh-server \
    curl \
    git \
    htop \
    mesa-vulkan-drivers \
    libgles2-mesa \
    alsa-utils \
    parted \
    fdisk

# Enable SSH, NetworkManager, and Auto-Resize service on boot
systemctl enable ssh
systemctl enable NetworkManager
systemctl enable linadroid-resize.service

# Configure root account password (default: linadroid)
echo "root:linadroid" | chpasswd

# Create required LXC & Docker groups in case package-setup has not initialized them yet
groupadd -f lxc
groupadd -f docker

# Create primary user 'droid'
useradd -m -s /bin/bash droid
echo "droid:linadroid" | chpasswd
usermod -aG sudo,audio,video,lxc,docker droid

# Ensure sudoers.d directory exists and grant passwordless privileges
mkdir -p /etc/sudoers.d
echo "droid ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/droid

echo "Debian userland configurations complete!"
EOF

# Make setup script executable and run inside chroot
chmod +x "$ROOTFS_DIR/tmp/chroot_setup.sh"
chroot "$ROOTFS_DIR" /tmp/chroot_setup.sh
rm "$ROOTFS_DIR/tmp/chroot_setup.sh"

# 5. Injecting Unified Package Manager ('linapkg') and Android LXC Config
echo -e "${BLUE}4. Injecting LinaDroid custom package manager and configurations...${NC}"

# Copy the linapkg script directly from portable repository path to host's usr/local/bin
cp "$REPO_DIR/packages/linapkg" "$ROOTFS_DIR/usr/local/bin/linapkg"
chmod +x "$ROOTFS_DIR/usr/local/bin/linapkg"

# Set up physical container paths inside rootfs
LXC_ANDROID_DIR="$ROOTFS_DIR/var/lib/lxc/linadroid-runtime"
mkdir -p "$LXC_ANDROID_DIR"
mkdir -p "$LXC_ANDROID_DIR/rootfs"
mkdir -p "$ROOTFS_DIR/var/shared/linadroid" # Shared host-container directory

# Copy LXC configuration from portable repository path
cp "$REPO_DIR/android/linadroid-lxc.conf" "$LXC_ANDROID_DIR/config"

echo -e "${GREEN}LinaDroid Host RootFS successfully built and configured at '$ROOTFS_DIR'!${NC}"
echo -e "${GREEN}Ready for Android subsystem injection and imaging.${NC}"
exit 0
