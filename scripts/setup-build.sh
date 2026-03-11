#!/bin/bash
# setup-build.sh – Clone all required Yocto layers and initialise the build
# environment for the Raspberry Pi 5 custom image.
#
# Usage:
#   chmod +x scripts/setup-build.sh
#   ./scripts/setup-build.sh [workspace_dir]
#
# The optional workspace_dir defaults to the parent of this repository.
# After this script completes, activate the build environment with:
#   source <workspace>/poky/oe-init-build-env <workspace>/build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORKSPACE="${1:-$(dirname "${REPO_DIR}")}"
BRANCH="scarthgap"

echo "=== Raspberry Pi 5 Yocto build setup ==="
echo "  Workspace : ${WORKSPACE}"
echo "  Branch    : ${BRANCH}"
echo ""

# ---------------------------------------------------------------------------
# Helper: clone or update a git repository
# ---------------------------------------------------------------------------
clone_or_update() {
    local url="$1"
    local dest="$2"
    local branch="${3:-${BRANCH}}"

    if [[ -d "${dest}/.git" ]]; then
        echo "[skip] ${dest} already exists – pulling latest changes"
        git -C "${dest}" pull --ff-only origin "${branch}" 2>/dev/null || true
    else
        echo "[clone] ${url}  →  ${dest}"
        git clone --depth 1 -b "${branch}" "${url}" "${dest}"
    fi
}

mkdir -p "${WORKSPACE}"

# ---------------------------------------------------------------------------
# 1. Poky (OpenEmbedded core + BitBake)
# ---------------------------------------------------------------------------
clone_or_update \
    "https://git.yoctoproject.org/poky" \
    "${WORKSPACE}/poky"

# ---------------------------------------------------------------------------
# 2. meta-openembedded (provides meta-oe, meta-python, meta-multimedia, ...)
# ---------------------------------------------------------------------------
clone_or_update \
    "https://git.openembedded.org/meta-openembedded" \
    "${WORKSPACE}/meta-openembedded"

# ---------------------------------------------------------------------------
# 3. meta-raspberrypi (BSP layer for Raspberry Pi 5)
# ---------------------------------------------------------------------------
clone_or_update \
    "https://github.com/agherzan/meta-raspberrypi" \
    "${WORKSPACE}/meta-raspberrypi"

# ---------------------------------------------------------------------------
# 4. Symlink the repository into the workspace so BitBake can find the layer.
#    The symlink name matches the path used in bblayers.conf.
# ---------------------------------------------------------------------------
CUSTOM_LAYER="${WORKSPACE}/Raspi-custom-yocto"
if [[ ! -e "${CUSTOM_LAYER}" ]]; then
    echo "[link] ${REPO_DIR} → ${CUSTOM_LAYER}"
    ln -sf "${REPO_DIR}" "${CUSTOM_LAYER}"
else
    echo "[skip] ${CUSTOM_LAYER} already exists"
fi

# ---------------------------------------------------------------------------
# 5. Initialise build directory
# ---------------------------------------------------------------------------
BUILD_DIR="${WORKSPACE}/build"
echo ""
echo "[init] Initialising build environment in ${BUILD_DIR}"

# Source oe-init-build-env in a sub-shell so it can set up BUILDDIR
(
    source "${WORKSPACE}/poky/oe-init-build-env" "${BUILD_DIR}" > /dev/null
)

# ---------------------------------------------------------------------------
# 6. Install our bblayers.conf and local.conf
# ---------------------------------------------------------------------------
CONF_DIR="${BUILD_DIR}/conf"
REPO_CONF="${REPO_DIR}/build/conf"

echo "[conf] Copying bblayers.conf and local.conf"

# Replace ##OEROOT## placeholder with the actual poky directory
sed "s|##OEROOT##|${WORKSPACE}/poky|g" \
    "${REPO_CONF}/bblayers.conf" > "${CONF_DIR}/bblayers.conf"

cp "${REPO_CONF}/local.conf" "${CONF_DIR}/local.conf"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup complete ==="
echo ""
echo "To build the image, run:"
echo ""
echo "  source ${WORKSPACE}/poky/oe-init-build-env ${BUILD_DIR}"
echo "  bitbake raspi5-image"
echo ""
echo "The finished image will be in:"
echo "  ${BUILD_DIR}/tmp/deploy/images/raspberrypi5/"
echo ""
echo "Flash to an SD card with:"
echo "  bmaptool copy raspi5-image-raspberrypi5.wic.bz2 /dev/sdX"
echo "  # or"
echo "  bzcat raspi5-image-raspberrypi5.wic.bz2 | dd of=/dev/sdX bs=4M conv=fsync"
echo ""
