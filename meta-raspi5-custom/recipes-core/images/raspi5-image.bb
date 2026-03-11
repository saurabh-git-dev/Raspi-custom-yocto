SUMMARY = "Raspberry Pi 5 custom image with OpenCV, libcamera, HailoRT and OTA support"
DESCRIPTION = "Production-ready Linux image for Raspberry Pi 5. \
Includes computer-vision libraries (OpenCV, libcamera), the Hailo AI \
runtime (HailoRT), and an A/B OTA update service with a built-in HTTP \
upload endpoint."

LICENSE = "MIT"

# ---------------------------------------------------------------------------
# Base image
# ---------------------------------------------------------------------------
inherit core-image

# Start from a minimal console image and add what we need
IMAGE_FEATURES += " \
    ssh-server-openssh \
    package-management \
"

# ---------------------------------------------------------------------------
# Core packages
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append = " \
    packagegroup-core-boot \
    packagegroup-base \
    linux-firmware-rpidistro \
    rpi-config \
    i2c-tools \
    util-linux \
    e2fsprogs \
    e2fsprogs-resize2fs \
    dosfstools \
    parted \
    bash \
    curl \
    wget \
    python3 \
    python3-pip \
    python3-flask \
"

# ---------------------------------------------------------------------------
# Camera – libcamera stack
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append = " \
    libcamera \
    libcamera-tools \
    libcamera-python \
    rpicam-apps \
"

# ---------------------------------------------------------------------------
# Computer vision – OpenCV (built with NEON/FPU acceleration)
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append = " \
    opencv \
    python3-opencv \
"

# ---------------------------------------------------------------------------
# Hailo AI accelerator runtime
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append = " \
    hailort \
"

# ---------------------------------------------------------------------------
# OTA update service
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append = " \
    ota-update \
"

# ---------------------------------------------------------------------------
# Image format – produce a WIC image ready for SD-card flashing
# The WIC image contains:
#   partition 1 – boot  (FAT32,  256 MB)
#   partition 2 – rootA (ext4,  3072 MB)  ← initial active slot
#   partition 3 – rootB (ext4,  3072 MB)  ← standby OTA slot
#   partition 4 – data  (ext4,  remaining) ← persistent storage
# ---------------------------------------------------------------------------
IMAGE_FSTYPES = "wic.bz2 wic.bmap ext4"
WKS_FILE = "raspi5-ab.wks"

# Ensure the WKS file is found inside this layer
WKS_SEARCH_PATH:prepend = "${THISDIR}/../../wic:"

# ---------------------------------------------------------------------------
# Raspberry Pi 5 specific tweaks
# ---------------------------------------------------------------------------
# Enable USB, I2C, SPI interfaces
MACHINE_FEATURES:append = " usbhost i2c spi"

# Pass the active rootfs slot to the kernel via the boot configuration
CMDLINE:append = " rootwait ro systemd.unified_cgroup_hierarchy=1"
