SUMMARY = "A/B OTA update service for Raspberry Pi 5"
DESCRIPTION = "Provides an HTTP server endpoint and shell helper scripts \
for over-the-air A/B root-filesystem updates.  On receiving a new \
rootfs image the server writes it to the inactive partition, updates \
cmdline.txt on the boot partition, and reboots into the new slot.  A \
watchdog service rolls back to the previous slot if the first boot \
after an update fails to reach multi-user.target."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://ota-server.py \
    file://ota-update.sh \
    file://ota-watchdog.sh \
    file://ota-update.service \
    file://ota-watchdog.service \
"

SYSTEMD_SERVICE:${PN} = "ota-update.service ota-watchdog.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = " \
    python3-core \
    bash \
    coreutils \
    util-linux \
    e2fsprogs \
    bzip2 \
"

do_install() {
    # OTA server Python script
    install -d ${D}${datadir}/ota-update
    install -m 0755 ${WORKDIR}/ota-server.py  ${D}${datadir}/ota-update/ota-server.py

    # Shell helpers
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/ota-update.sh   ${D}${sbindir}/ota-update
    install -m 0755 ${WORKDIR}/ota-watchdog.sh ${D}${sbindir}/ota-watchdog.sh

    # Systemd service units
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ota-update.service   ${D}${systemd_system_unitdir}/ota-update.service
    install -m 0644 ${WORKDIR}/ota-watchdog.service ${D}${systemd_system_unitdir}/ota-watchdog.service

    # Persistent data directory placeholder
    install -d ${D}/data/ota
}

FILES:${PN} = " \
    ${datadir}/ota-update \
    ${sbindir}/ota-update \
    ${sbindir}/ota-watchdog.sh \
    ${systemd_system_unitdir}/ota-update.service \
    ${systemd_system_unitdir}/ota-watchdog.service \
    /data/ota \
"
