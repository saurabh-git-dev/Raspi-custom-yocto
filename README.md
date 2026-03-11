# Raspberry Pi 5 – Custom Yocto Linux Image

A complete Yocto Project build system for the **Raspberry Pi 5** that
produces a production-ready Linux image with:

| Feature | Details |
|---------|---------|
| **OpenCV** | With NEON/FPU SIMD acceleration and Python 3 bindings |
| **libcamera** | Full Raspberry Pi IPA pipeline, GStreamer integration |
| **HailoRT** | Runtime library + `hailortcli` for Hailo-8/8L NPU |
| **A/B OTA updates** | HTTP upload endpoint, atomic slot switch, auto-rollback |

---

## Repository layout

```
Raspi-custom-yocto/
├── meta-raspi5-custom/        ← Custom Yocto layer
│   ├── conf/
│   │   └── layer.conf
│   ├── wic/
│   │   └── raspi5-ab.wks      ← A/B partition layout (GPT)
│   ├── recipes-core/images/
│   │   └── raspi5-image.bb    ← Top-level image recipe
│   ├── recipes-multimedia/libcamera/
│   │   └── libcamera_%.bbappend
│   ├── recipes-vision/opencv/
│   │   └── opencv_%.bbappend
│   ├── recipes-hailo/hailort/
│   │   └── hailort.bb         ← HailoRT runtime recipe
│   └── recipes-ota/ota-update/
│       ├── ota-update.bb      ← OTA service recipe
│       └── files/
│           ├── ota-server.py  ← HTTP OTA server
│           ├── ota-update.sh  ← Shell helper (apply/rollback)
│           ├── ota-watchdog.sh← Boot-time watchdog / auto-rollback
│           ├── ota-update.service
│           └── ota-watchdog.service
├── build/conf/
│   ├── local.conf             ← BitBake machine & distro settings
│   └── bblayers.conf          ← Layer paths
└── scripts/
    └── setup-build.sh         ← One-shot environment setup
```

---

## Host requirements

| Requirement | Minimum |
|-------------|---------|
| OS          | Ubuntu 22.04 LTS / Debian 12 (x86-64) |
| RAM         | 16 GB (32 GB recommended) |
| Disk        | 100 GB free |
| Python      | 3.8+ |
| Git         | 2.x |

Install build dependencies:
```bash
sudo apt-get update && sudo apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping python3-git python3-jinja2 \
    libegl1-mesa libsdl1.2-dev xterm python3-subunit mesa-common-dev \
    zstd liblz4-tool file locales libacl1
sudo locale-gen en_US.UTF-8
```

---

## Quick start

```bash
# 1. Clone this repository
git clone https://github.com/saurabh-git-dev/Raspi-custom-yocto
cd Raspi-custom-yocto

# 2. Run the automated setup (clones poky, meta-oe, meta-raspberrypi)
chmod +x scripts/setup-build.sh
./scripts/setup-build.sh ~/yocto-workspace

# 3. Activate the build environment
source ~/yocto-workspace/poky/oe-init-build-env ~/yocto-workspace/build

# 4. Build the image (first build takes 4–8 hours)
bitbake raspi5-image
```

The finished artefacts are written to:
```
~/yocto-workspace/build/tmp/deploy/images/raspberrypi5/
```

---

## Flashing the SD card

```bash
# Using bmaptool (fastest, recommended)
sudo bmaptool copy \
    raspi5-image-raspberrypi5.wic.bz2 \
    /dev/sdX

# Or using dd
bzcat raspi5-image-raspberrypi5.wic.bz2 \
    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

> **Partition layout after flashing**
>
> | # | Label | Type | Size | Purpose |
> |---|-------|------|------|---------|
> | 1 | boot  | FAT32 | 256 MB | Kernel, DTBs, `config.txt`, `cmdline.txt` |
> | 2 | rootA | ext4  | 3 GB   | Active root filesystem (initial boot) |
> | 3 | rootB | ext4  | 3 GB   | Standby slot (OTA target) |
> | 4 | data  | ext4  | rest   | Persistent data (survives OTA swaps) |

---

## OTA update workflow

The image ships with an HTTP OTA server (port **8080**) that is enabled at
boot.  Updates use an A/B slot strategy analogous to OpenWrt's sysupgrade:

```
Client                           Raspberry Pi 5
  │                                    │
  │  POST /update  (new rootfs.ext4)   │
  │ ──────────────────────────────────>│  1. Receive & hash-verify image
  │                                    │  2. Write to inactive slot
  │                                    │  3. Rewrite cmdline.txt → new slot
  │  { "status": "success",            │
  │    "slot": "B", ... }              │
  │ <──────────────────────────────────│
  │                                    │
  │  GET  /reboot                      │
  │ ──────────────────────────────────>│  4. Reboot
  │                                    │
  │                                    │  5. Boot watchdog: if system reaches
  │                                    │     multi-user.target → mark-good
  │                                    │     else → rollback + reboot
```

### Push an update from a Linux host

```bash
# Build a new rootfs image (bitbake produces an .ext4 file)
NEW_IMAGE=raspi5-image-raspberrypi5.ext4

# Optional: compute SHA-256 for integrity check
SHA=$(sha256sum "${NEW_IMAGE}" | awk '{print $1}')

# Upload to the device (replace <device-ip> with the Pi's IP address)
curl -X POST http://<device-ip>:8080/update \
     -H "Content-Type: application/octet-stream" \
     -H "X-Image-SHA256: ${SHA}" \
     -H "Content-Disposition: filename=\"${NEW_IMAGE}\"" \
     --data-binary @"${NEW_IMAGE}"

# Reboot into the new slot
curl http://<device-ip>:8080/reboot
```

### Check update status

```bash
curl http://<device-ip>:8080/status
```

Sample response:
```json
{
  "active_slot":   "A",
  "inactive_slot": "B",
  "slot_a_device": "/dev/mmcblk0p2",
  "slot_b_device": "/dev/mmcblk0p3",
  "version":       "1.0.0",
  "update_ready":  false,
  "pending_slot":  null
}
```

### Manual rollback (on the device)

```bash
ota-update rollback
reboot
```

---

## HailoRT usage

After boot, verify the Hailo NPU is detected:

```bash
hailortcli scan        # lists connected Hailo devices
hailortcli fw-control identify   # firmware version
```

Python example:
```python
import hailo

target = hailo.Device()
print(target.get_info())
```

---

## libcamera usage

```bash
# List cameras
libcamera-hello --list-cameras

# Capture a JPEG
libcamera-still -o photo.jpg

# Stream via GStreamer
gst-launch-1.0 libcamerasrc ! \
    video/x-raw,width=1920,height=1080,framerate=30/1 ! \
    videoconvert ! autovideosink
```

---

## OpenCV Python example

```python
import cv2

cap = cv2.VideoCapture(0, cv2.CAP_V4L2)
ret, frame = cap.read()
cv2.imwrite("frame.jpg", frame)
cap.release()
```

---

## Customisation

| Task | Where to edit |
|------|--------------|
| Add packages to the image | `meta-raspi5-custom/recipes-core/images/raspi5-image.bb` |
| Change partition sizes | `meta-raspi5-custom/wic/raspi5-ab.wks` |
| Adjust OTA server port | `build/conf/local.conf` → `OTA_PORT`, or edit `ota-update.service` |
| Enable/disable GPU | `build/conf/local.conf` → `GPU_MEM` |
| Add device-tree overlays | `build/conf/local.conf` → `RPI_EXTRA_CONFIG` |

---

## Security notes

* The OTA HTTP server listens on all interfaces on port 8080.  It is
  recommended to firewall this port and add token-based authentication
  before deploying in production.
* The server validates the SHA-256 digest of the image when the client
  supplies an `X-Image-SHA256` header.
* The root password is empty by default (`debug-tweaks`).  Remove the
  `allow-empty-password` feature from `raspi5-image.bb` before
  production deployment.

---

## Yocto layer dependencies

| Layer | Source |
|-------|--------|
| `meta` / `meta-poky` / `meta-yocto-bsp` | https://git.yoctoproject.org/poky |
| `meta-oe` / `meta-python` / `meta-multimedia` / `meta-networking` | https://git.openembedded.org/meta-openembedded |
| `meta-raspberrypi` | https://github.com/agherzan/meta-raspberrypi |
| `meta-raspi5-custom` | This repository |

All layers must be checked out on the **scarthgap** (Yocto 5.0) branch.

---

## License

MIT — see individual recipe files for third-party component licences.
