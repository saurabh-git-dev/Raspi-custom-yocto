SUMMARY = "HailoRT – Hailo AI accelerator runtime library"
DESCRIPTION = "HailoRT is the runtime software stack for Hailo-8/Hailo-8L \
AI processors.  It provides a C/C++ API for loading and running neural \
network models on the Hailo NPU."
HOMEPAGE = "https://github.com/hailo-ai/hailort"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=912d9840d25da645fb81a37c77a1b8b3"

# ---------------------------------------------------------------------------
# Source – clone from Hailo's public GitHub repository.
# For reproducible builds, replace AUTOREV with the exact commit SHA of the
# desired release tag (e.g. v4.19.0) once you have confirmed it builds:
#
#   SRCREV = "<40-char SHA from: git ls-remote \
#              https://github.com/hailo-ai/hailort refs/tags/v4.19.0>"
#
# Using AUTOREV is acceptable for development but must be pinned for
# production images to guarantee reproducibility.
# ---------------------------------------------------------------------------
HAILORT_VERSION = "4.19.0"

SRC_URI = "git://github.com/hailo-ai/hailort.git;protocol=https;branch=master"
SRCREV  = "${AUTOREV}"
PV      = "${HAILORT_VERSION}+git${SRCPV}"
S       = "${WORKDIR}/git"

# ---------------------------------------------------------------------------
# Build dependencies
# ---------------------------------------------------------------------------
DEPENDS = " \
    cmake-native \
    ninja-native \
    python3-native \
    python3-pybind11-native \
    libusb1 \
    spdlog \
    nlohmann-json \
    grpc \
    protobuf \
    protobuf-native \
    cli11 \
    eigen \
"

RDEPENDS:${PN} = " \
    libusb1 \
    python3-core \
"

inherit cmake python3native

# ---------------------------------------------------------------------------
# CMake configuration
# ---------------------------------------------------------------------------
EXTRA_OECMAKE = " \
    -DCMAKE_BUILD_TYPE=Release \
    -DHAILO_BUILD_SERVICE=OFF \
    -DHAILO_BUILD_EXAMPLES=OFF \
    -DHAILO_BUILD_TESTS=OFF \
    -DHAILO_COMPILE_WARNING_AS_ERROR=OFF \
    -DPYTHON_EXECUTABLE=${PYTHON} \
"

# Only build the runtime library and hailortcli; skip the driver (kernel module)
OECMAKE_TARGET_COMPILE = "libhailort hailortcli"

# ---------------------------------------------------------------------------
# Packaging
# ---------------------------------------------------------------------------
PACKAGES =+ "${PN}-cli"

FILES:${PN}     = "${libdir}/libhailort.so.* ${sysconfdir}/hailo/*"
FILES:${PN}-cli = "${bindir}/hailortcli"
FILES:${PN}-dev = "${includedir}/hailo ${libdir}/libhailort.so ${libdir}/cmake/HailoRT"

# The shared library SONAME follows the upstream version
SOLIBS = ".so.${HAILORT_VERSION}"
FILES_SOLIBSDEV = ""

# ---------------------------------------------------------------------------
# Post-install: ensure the 'hailo' udev rules are present so that
# non-root users can access the USB device.
# ---------------------------------------------------------------------------
do_install:append() {
    install -d ${D}${sysconfdir}/udev/rules.d
    cat > ${D}${sysconfdir}/udev/rules.d/99-hailo.rules <<'EOF'
# Hailo-8 / Hailo-8L AI accelerator
SUBSYSTEM=="usb", ATTRS{idVendor}=="03e7", MODE="0666", GROUP="hailo"
EOF
}
