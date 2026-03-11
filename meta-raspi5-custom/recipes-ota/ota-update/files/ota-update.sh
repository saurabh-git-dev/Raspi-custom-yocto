#!/bin/bash
# ota-update.sh – A/B partition OTA helper for Raspberry Pi 5
#
# Usage:
#   ota-update.sh status              Show active/inactive slot information
#   ota-update.sh apply <image>       Write <image> to inactive slot & update boot
#   ota-update.sh switch              Switch active slot without writing an image
#   ota-update.sh rollback            Revert to the previously active slot
#   ota-update.sh mark-good           Mark the current boot slot as confirmed good
#
# Environment variables:
#   OTA_SLOT_A    Block device for slot A  (default: /dev/mmcblk0p2)
#   OTA_SLOT_B    Block device for slot B  (default: /dev/mmcblk0p3)
#   OTA_BOOT      Boot partition mount     (default: /boot)

set -euo pipefail

SLOT_A="${OTA_SLOT_A:-/dev/mmcblk0p2}"
SLOT_B="${OTA_SLOT_B:-/dev/mmcblk0p3}"
BOOT="${OTA_BOOT:-/boot}"
CMDLINE="${BOOT}/cmdline.txt"
STATE_FILE="/data/ota/state.json"
LOG_TAG="ota-update"

# ---------------------------------------------------------------------------
log() { logger -t "${LOG_TAG}" "$*"; echo "[ota] $*"; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "This command must be run as root."
}

# ---------------------------------------------------------------------------
read_cmdline() { cat "${CMDLINE}"; }

active_slot() {
    local cmdline
    cmdline="$(read_cmdline)"
    if echo "${cmdline}" | grep -qE "root=PARTLABEL=rootA|root=${SLOT_A}"; then
        echo "A"
    elif echo "${cmdline}" | grep -qE "root=PARTLABEL=rootB|root=${SLOT_B}"; then
        echo "B"
    else
        echo "A"   # safe default
    fi
}

inactive_slot() {
    [[ "$(active_slot)" == "A" ]] && echo "B" || echo "A"
}

slot_device() {
    [[ "$1" == "A" ]] && echo "${SLOT_A}" || echo "${SLOT_B}"
}

slot_label() {
    [[ "$1" == "A" ]] && echo "rootA" || echo "rootB"
}

# ---------------------------------------------------------------------------
cmd_status() {
    local active inactive
    active="$(active_slot)"
    inactive="$(inactive_slot)"
    echo "=== OTA Slot Status ==="
    echo "  Active   slot : ${active}  ($(slot_device "${active}"))"
    echo "  Inactive slot : ${inactive}  ($(slot_device "${inactive}"))"
    echo "  cmdline.txt   : $(read_cmdline)"
    if [[ -f "${STATE_FILE}" ]]; then
        echo "  State file    : $(cat "${STATE_FILE}")"
    fi
}

# ---------------------------------------------------------------------------
cmd_apply() {
    require_root
    local image="$1"
    [[ -f "${image}" ]] || die "Image file not found: ${image}"

    local inactive
    inactive="$(inactive_slot)"
    local device
    device="$(slot_device "${inactive}")"

    log "Writing image '${image}' to slot ${inactive} (${device})"

    # Ensure the boot partition is mounted read-write
    mount -o remount,rw "${BOOT}" 2>/dev/null || true

    # Write image
    if [[ "${image}" == *.bz2 ]]; then
        bzip2 -d -c "${image}" | dd of="${device}" bs=4M conv=fsync status=progress
    elif [[ "${image}" == *.gz ]]; then
        gzip  -d -c "${image}" | dd of="${device}" bs=4M conv=fsync status=progress
    else
        dd if="${image}" of="${device}" bs=4M conv=fsync status=progress
    fi
    sync

    # Re-label the filesystem
    e2label "${device}" "$(slot_label "${inactive}")" 2>/dev/null || true

    # Switch boot target
    _switch_cmdline "${inactive}"

    # Save state
    _save_state "${inactive}"

    log "Update applied. Reboot to activate slot ${inactive}."
    echo "Run 'reboot' to boot into the new slot."
}

# ---------------------------------------------------------------------------
cmd_switch() {
    require_root
    local inactive
    inactive="$(inactive_slot)"
    mount -o remount,rw "${BOOT}" 2>/dev/null || true
    _switch_cmdline "${inactive}"
    _save_state "${inactive}"
    log "Boot target switched to slot ${inactive}. Reboot to apply."
}

# ---------------------------------------------------------------------------
cmd_rollback() {
    require_root
    local active
    active="$(active_slot)"
    local rollback
    rollback="$(inactive_slot)"   # current inactive = previous active
    mount -o remount,rw "${BOOT}" 2>/dev/null || true
    _switch_cmdline "${rollback}"
    _save_state "${rollback}"
    log "Rollback: boot target reverted from slot ${active} to slot ${rollback}."
    echo "Run 'reboot' to boot into slot ${rollback}."
}

# ---------------------------------------------------------------------------
cmd_mark_good() {
    require_root
    local active
    active="$(active_slot)"
    mkdir -p "$(dirname "${STATE_FILE}")"
    echo "{\"confirmed\":true,\"active_slot\":\"${active}\",\"timestamp\":\"$(date -Iseconds)\"}" \
        > "${STATE_FILE}"
    log "Slot ${active} marked as confirmed good."
}

# ---------------------------------------------------------------------------
_switch_cmdline() {
    local new_slot="$1"
    local new_root="root=PARTLABEL=$(slot_label "${new_slot}")"
    local cmdline
    cmdline="$(read_cmdline)"
    # Replace existing root= token or prepend
    if echo "${cmdline}" | grep -q "root="; then
        cmdline="$(echo "${cmdline}" | sed "s|root=[^ ]*|${new_root}|g")"
    else
        cmdline="${new_root} ${cmdline}"
    fi
    # Write atomically
    printf '%s\n' "${cmdline}" > "${CMDLINE}.tmp"
    mv "${CMDLINE}.tmp" "${CMDLINE}"
    sync
    log "cmdline.txt updated: ${cmdline}"
}

_save_state() {
    local pending_slot="$1"
    mkdir -p "$(dirname "${STATE_FILE}")"
    echo "{\"pending_slot\":\"${pending_slot}\",\"confirmed\":false,\"timestamp\":\"$(date -Iseconds)\"}" \
        > "${STATE_FILE}"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
CMD="${1:-status}"
shift || true

case "${CMD}" in
    status)    cmd_status ;;
    apply)     cmd_apply  "${1:?Usage: ota-update.sh apply <image>}" ;;
    switch)    cmd_switch ;;
    rollback)  cmd_rollback ;;
    mark-good) cmd_mark_good ;;
    *)
        echo "Usage: $(basename "$0") {status|apply <image>|switch|rollback|mark-good}"
        exit 1
        ;;
esac
