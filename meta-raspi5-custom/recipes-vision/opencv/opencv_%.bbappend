# opencv bbappend for Raspberry Pi 5
#
# Enables ARM NEON SIMD acceleration, Python 3 bindings and the
# GStreamer video-capture backend.  Disable unneeded GUI back-ends to
# keep the image footprint small.

PACKAGECONFIG:append = " \
    neon \
    python3 \
    gstreamer \
    libv4l \
    eigen \
"

# Disable heavy/unneeded features
PACKAGECONFIG:remove = " \
    qt5 \
    gtk \
    jasper \
    openexr \
"

# Extra optimisation flags for Cortex-A76 (Raspberry Pi 5)
# Note: -mfpu is not valid on AArch64 (NEON is always available); omit it.
CXXFLAGS:append:raspberrypi5 = " -mcpu=cortex-a76 -O3"
CFLAGS:append:raspberrypi5   = " -mcpu=cortex-a76 -O3"
