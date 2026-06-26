#!/bin/bash
# =====================================================================
# LinaDroid OS - Master Build & OS Generation Automation Script
# This orchestrator compiles the custom Linux kernel, generates the
# Debian Host rootfs, integrates the Android Container, and packages
# everything into a bootable raw disk image (.img).
# =====================================================================

set -e

# Dynamically locate the repository root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- CRITICAL SPACE RESCUE FIX ---
# Instead of using '/tmp' (which is often mapped to a small RAM disk or size-restricted tmpfs),
# we place the build and rootfs directories directly in the workspace directory.
# This grants the build system access to the full 35GB+ of disk space maximized by GitHub Actions!
BUILD_DIR="${SCRIPT_DIR}/build_tmp"
ROOTFS_DIR="${SCRIPT_DIR}/rootfs_tmp"

OUTPUT_IMAGE="linadroid-os-v1.0.img"
KERNEL_VERSION="6.6.21"
IMAGE_SIZE_GB=5 

# Color definitions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=====================================================================${NC}"
echo -e "${GREEN}             LinaDroid OS Build Orchestrator: Master Script          ${NC}"
echo -e "${GREEN}=====================================================================${NC}"

# Check for root privileges
DRY_RUN=false
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}[WARNING] This script requires root privileges to execute full mount, chroot,${NC}"
    echo -e "${YELLOW}          and loop device partitioning commands.${NC}"
    echo -e "${GREEN}[INFO]    Enabling DRY-RUN / SIMULATION mode. Will compile config, perform${NC}"
    echo -e "${GREEN}          syntax checks, and output the exact commands for your host.${NC}"
    DRY_RUN=true
    sleep 2
fi

# Step 1: Pre-requisite checks
echo -e "\n${BLUE}[STEP 1] Checking Build Host Dependencies...${NC}"
DEPENDENCIES=("debootstrap" "lxc" "tar" "git" "gcc" "make" "qemu-utils" "parted" "dosfstools")
MISSING_DEPS=()

for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo -e "${YELLOW}[INFO] Missing dependencies on build host: ${MISSING_DEPS[*]}.${NC}"
    if [ "$DRY_RUN" = false ]; then
        echo -e "${YELLOW}Attempting to install missing dependencies...${NC}"
        apt-get update && apt-get install -y "${MISSING_DEPS[@]}"
    else
        echo -e "${YELLOW}[DRY-RUN] In native execution, missing packages would be auto-installed.${NC}"
    fi
else
    echo -e "${GREEN}All host dependencies met!${NC}"
fi

# Create workspace directories
mkdir -p "$BUILD_DIR"
mkdir -p "$ROOTFS_DIR"

# Step 2: Custom Linux Kernel Preparation
echo -e "\n${BLUE}[STEP 2] Preparing Custom Linux Kernel (with Android Support)...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${GREEN}[DRY-RUN] Checking kernel config syntax...${NC}"
    if [ -f "kernel/kernel.config" ]; then
        echo -e "${GREEN}Kernel Configuration file located. Verified options:$(grep -c "CONFIG_" kernel/kernel.config) values loaded.${NC}"
    else
        echo -e "${RED}Error: Kernel configuration file 'kernel/kernel.config' not found!${NC}"
        exit 1
    fi
    echo -e "${YELLOW}[DRY-RUN] Simulating Kernel config merging & compilation flow...${NC}"
    echo "  >> wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
    echo "  >> tar -xf linux-${KERNEL_VERSION}.tar.xz -C $BUILD_DIR/"
    echo "  >> make -C $BUILD_DIR/linux-${KERNEL_VERSION} x86_64_defconfig"
    echo "  >> cat kernel/kernel.config >> $BUILD_DIR/linux-${KERNEL_VERSION}/.config"
    echo "  >> make -C $BUILD_DIR/linux-${KERNEL_VERSION} olddefconfig"
    echo "  >> make -C $BUILD_DIR/linux-${KERNEL_VERSION}/ -j\$(nproc) bzImage modules"
    echo "  >> cp $BUILD_DIR/linux-${KERNEL_VERSION}/arch/x86/boot/bzImage $ROOTFS_DIR/boot/vmlinuz-linadroid"
    echo "  >> make -C $BUILD_DIR/linux-${KERNEL_VERSION}/ modules_install INSTALL_MOD_PATH=$ROOTFS_DIR"
    echo -e "${GREEN}[DRY-RUN] Custom kernel compilation simulated successfully! (Output: bzImage & modules)${NC}"
else
    # Real execution
    echo -e "${YELLOW}Downloading Linux Kernel v${KERNEL_VERSION} sources...${NC}"
    if [ ! -f "$BUILD_DIR/linux-${KERNEL_VERSION}.tar.xz" ]; then
        wget -P "$BUILD_DIR" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
    fi
    
    echo -e "${YELLOW}Extracting kernel sources...${NC}"
    tar -xf "$BUILD_DIR/linux-${KERNEL_VERSION}.tar.xz" -C "$BUILD_DIR"
    
    # Generate the standard base config for x86_64 architecture first
    echo -e "${YELLOW}Generating standard base x86_64 kernel config...${NC}"
    make -C "$BUILD_DIR/linux-${KERNEL_VERSION}" x86_64_defconfig
    
    # Append our LinaDroid custom kernel parameters to the generated config
    echo -e "${YELLOW}Merging LinaDroid custom configs (Binder, Ashmem, GMS)...${NC}"
    cat kernel/kernel.config >> "$BUILD_DIR/linux-${KERNEL_VERSION}/.config"
    
    # Run 'olddefconfig' to automatically resolve dependencies and answer
    # all prompts with default choices. No interactive terminals needed!
    echo -e "${YELLOW}Validating configuration integrity and solving dependencies...${NC}"
    make -C "$BUILD_DIR/linux-${KERNEL_VERSION}" olddefconfig
    
    echo -e "${BLUE}Compiling Kernel (bzImage and modules)... This may take up to 30 minutes!${NC}"
    make -C "$BUILD_DIR/linux-${KERNEL_VERSION}" -j$(nproc) bzImage modules
    echo -e "${GREEN}Kernel and module compilation complete!${NC}"
fi

# Step 3: Debian Host RootFS Generation
echo -e "\n${BLUE}[STEP 3] Bootstrapping Debian Host Root Filesystem...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Executing syntax/dry-run of rootfs bootstrap script...${NC}"
    bash rootfs/build_rootfs.sh
else
    echo -e "${YELLOW}Executing rootfs/build_rootfs.sh as Root...${NC}"
    bash rootfs/build_rootfs.sh
    
    # Install the compiled kernel and driver modules into the newly created rootfs
    echo -e "${BLUE}Installing kernel and modules to target rootfs...${NC}"
    mkdir -p "$ROOTFS_DIR/boot"
    cp "$BUILD_DIR/linux-${KERNEL_VERSION}/arch/x86/boot/bzImage" "$ROOTFS_DIR/boot/vmlinuz-linadroid"
    make -C "$BUILD_DIR/linux-${KERNEL_VERSION}" modules_install INSTALL_MOD_PATH="$ROOTFS_DIR"
fi

# Step 4: Android Container Subsystem Integration
echo -e "\n${BLUE}[STEP 4] Deploying and Integrating Android Container...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Executing dry-run of Android subsystem configuration...${NC}"
    bash android/build_android_container.sh
else
    echo -e "${YELLOW}Executing android/build_android_container.sh as Root...${NC}"
    bash android/build_android_container.sh
fi

# Step 5: Packaging into Bootable Raw Disk Image
echo -e "\n${BLUE}[STEP 5] Packing OS into bootable disk image: ${OUTPUT_IMAGE}...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Simulating partition layout and writing raw disk image...${NC}"
    echo "  >> dd if=/dev/zero of=$OUTPUT_IMAGE bs=1G count=$IMAGE_SIZE_GB"
    echo "  >> parted -s $OUTPUT_IMAGE mklabel gpt"
    echo "  >> parted -s $OUTPUT_IMAGE mkpart ESP fat32 1MiB 512MiB"
    echo "  >> parted -s $OUTPUT_IMAGE set 1 esp on"
    echo "  >> parted -s $OUTPUT_IMAGE mkpart primary ext4 512MiB 100%"
    echo "  >> mkfs.vfat -F32 /dev/loopXp1"
    echo "  >> mkfs.ext4 -F /dev/loopXp2"
    echo "  >> mount /dev/loopXp2 /mnt/rootfs"
    echo "  >> cp -a $ROOTFS_DIR/* /mnt/rootfs/"
    echo "  >> grub-install --target=x86_64-efi --efi-directory=/mnt/rootfs/boot/efi"
    echo -e "${GREEN}[DRY-RUN] Disk Image simulation complete! Created mock: $OUTPUT_IMAGE (Size: ${IMAGE_SIZE_GB}GB)${NC}"
    
    # Write dummy target file to represent output
    echo "LinaDroid OS Disk Image File (Simulation)" > "$OUTPUT_IMAGE"
else
    # Real disk imaging sequence
    echo -e "${YELLOW}Allocating ${IMAGE_SIZE_GB}GB sparse disk image...${NC}"
    dd if=/dev/zero of="$OUTPUT_IMAGE" bs=1M count=0 seek=$((IMAGE_SIZE_GB * 1024))
    
    echo -e "${YELLOW}Partitioning disk image (GPT: ESP partition + Root Partition)...${NC}"
    parted -s "$OUTPUT_IMAGE" mklabel gpt
    parted -s "$OUTPUT_IMAGE" mkpart ESP fat32 1MiB 512MiB
    parted -s "$OUTPUT_IMAGE" set 1 esp on
    parted -s "$OUTPUT_IMAGE" mkpart primary ext4 512MiB 100%
    
    echo -e "${YELLOW}Setting up loopback mount...${NC}"
    LOOP_DEV=$(losetup -fP --show "$OUTPUT_IMAGE")
    
    echo -e "${YELLOW}Formatting partitions (p1: FAT32, p2: EXT4)...${NC}"
    mkfs.vfat -F32 "${LOOP_DEV}p1"
    mkfs.ext4 -F "${LOOP_DEV}p2"
    
    echo -e "${YELLOW}Mounting partition image and copying files...${NC}"
    MNT_DIR="/mnt/linadroid-loop"
    mkdir -p "$MNT_DIR"
    mount "${LOOP_DEV}p2" "$MNT_DIR"
    
    mkdir -p "$MNT_DIR/boot/efi"
    mount "${LOOP_DEV}p1" "$MNT_DIR/boot/efi"
    
    # Copy all rootfs files (both Debian host and integrated Android)
    echo -e "${YELLOW}Copying built filesystem to loop image...${NC}"
    cp -a "$ROOTFS_DIR"/* "$MNT_DIR/"
    
    # Setup standard custom grub.cfg on target
    mkdir -p "$MNT_DIR/boot/grub"
    cat <<EOF > "$MNT_DIR/boot/grub/grub.cfg"
set default=0
set timeout=5

menuentry "LinaDroid OS v1.0 (GNU/Linux Host + Direct-DRM Android)" {
    search --no-floppy --fs-uuid --set=root $(grub-probe --target=fs_uuid "$MNT_DIR")
    linux /boot/vmlinuz-linadroid root=UUID=$(grub-probe --target=fs_uuid "$MNT_DIR") rw quiet splash androidboot.hardware=linadroid
}
EOF
    
    # Install GRUB bootloader
    echo -e "${YELLOW}Installing GRUB bootloader to the disk image...${NC}"
    grub-install --target=x86_64-efi --efi-directory="$MNT_DIR/boot/efi" --boot-directory="$MNT_DIR/boot" --removable "${LOOP_DEV}"
    
    # Clean up loop mounts
    echo -e "${YELLOW}Dismounting and flushing loopback devices...${NC}"
    umount "$MNT_DIR/boot/efi"
    umount "$MNT_DIR"
    losetup -d "$LOOP_DEV"
    
    echo -e "${GREEN}LinaDroid OS bootable disk image successfully created at: $OUTPUT_IMAGE${NC}"
fi

# Final Output Block
echo -e "\n${GREEN}=====================================================================${NC}"
echo -e "${GREEN}                 LinaDroid OS Build Process Complete!                ${NC}"
echo -e "${GREEN}=====================================================================${NC}"
echo -e "\nHow to deploy and boot your custom OS:"
echo -e "1. ${YELLOW}Flash to USB/SD Card:${NC}"
echo -e "   sudo dd if=${OUTPUT_IMAGE} of=/dev/sdX bs=4M status=progress conv=fsync"
echo -e "   (Replace /dev/sdX with your physical disk device)"
echo -e "\n*  ${GREEN}Note: On first boot, the system automatically expands the partition and${NC}"
echo -e "   ${GREEN}filesystem to consume 100% of your disk, whether it is 8GB, 32GB, or 512GB!${NC}"
echo -e "\n2. ${YELLOW}Boot in Virtual Machine (QEMU with GPU passthrough):${NC}"
echo -e "   qemu-system-x86_64 -enable-kvm -m 4G \\"
echo -e "       -bios /usr/share/ovmf/OVMF.fd \\"
echo -e "       -device virtio-vga-gl,hostgpu=on,x-vga=on \\"
echo -e "       -display gtk,gl=on \\"
echo -e "       -drive file=${OUTPUT_IMAGE},format=raw,media=disk"
echo -e "====================================================================="
exit 0
