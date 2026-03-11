#!/bin/bash
# ota-watchdog.sh – runs early in boot to confirm or revert an OTA update
#
# Logic:
#   1. Read /data/ota/state.json.
#   2. If confirmed=false AND pending_slot matches current active slot:
#      – This is the *first* boot after an OTA write.
#      – Wait for systemd to reach multi-user.target (timeout = BOOT_TIMEOUT).
#      – If successful: set confirmed=true ("mark-good").
#      – If timed-out: trigger rollback and reboot.

set -euo pipefail

STATE_FILE="/data/ota/state.json"
BOOT_TIMEOUT="${OTA_BOOT_TIMEOUT:-120}"
LOG_TAG="ota-watchdog"

log() { logger -t "${LOG_TAG}" "$*"; echo "[watchdog] $*"; }

active_slot() {
    /usr/sbin/ota-update status 2>/dev/null | grep "Active" | awk '{print $4}'
}

if [[ ! -f "${STATE_FILE}" ]]; then
    # No pending update – nothing to do
    exit 0
fi

confirmed=$(python3 -c "import json,sys; d=json.load(open('${STATE_FILE}')); print(d.get('confirmed','false'))" 2>/dev/null || echo "true")
pending=$(python3   -c "import json,sys; d=json.load(open('${STATE_FILE}')); print(d.get('pending_slot',''))"    2>/dev/null || echo "")

if [[ "${confirmed}" == "True" ]] || [[ "${confirmed}" == "true" ]]; then
    exit 0   # Already confirmed – nothing to do
fi

current="$(active_slot)"

if [[ "${current}" != "${pending}" ]]; then
    # We're not actually running the pending slot – stale state file
    exit 0
fi

log "First boot after OTA update (slot ${current}). Waiting for system ready…"

# Wait for multi-user.target using a polling loop for broad systemd compatibility
elapsed=0
system_ok=false
while [[ ${elapsed} -lt ${BOOT_TIMEOUT} ]]; do
    state="$(systemctl is-system-running 2>/dev/null || true)"
    if [[ "${state}" == "running" || "${state}" == "degraded" ]]; then
        system_ok=true
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if ${system_ok}; then
    log "System reached running state – marking slot ${current} as good."
    /usr/sbin/ota-update mark-good
else
    log "System did NOT reach running state in ${BOOT_TIMEOUT}s – rolling back!"
    /usr/sbin/ota-update rollback
    sleep 2
    reboot
fi
