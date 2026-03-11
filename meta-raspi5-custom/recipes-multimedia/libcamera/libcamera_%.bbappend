# libcamera bbappend for Raspberry Pi 5
#
# Enables the Raspberry Pi proprietary IPA (Image Processing Algorithm)
# module and GStreamer integration on top of the upstream recipe provided
# by meta-openembedded/meta-multimedia.

# Build with the Raspberry Pi pipeline
PACKAGECONFIG:append = " raspberrypi pipeline-rpi gstreamer"

# Link against the Hailo ISP bridge when HailoRT is present
PACKAGECONFIG:append = "${@bb.utils.contains('IMAGE_INSTALL', 'hailort', ' hailo', '', d)}"

# Additional runtime packages provided by this recipe
RDEPENDS:${PN}:append = " python3-libcamera"
