#!/usr/bin/env python3
"""
OTA HTTP update server for Raspberry Pi 5 A/B root partition scheme.

API
---
GET  /status          – return current active slot and version info
POST /update          – upload a new rootfs image (.ext4 or .ext4.bz2)
GET  /reboot          – reboot into the newly written slot (requires prior /update)

The server listens on port 8080 by default (override with OTA_PORT env var).

Workflow
--------
1.  Client POSTs the new .ext4[.bz2] image to /update.
2.  Server detects the *inactive* slot (rootB if A is active, and vice versa).
3.  Image is streamed directly onto the inactive partition (dd/bz2 pipe).
4.  The boot configuration (cmdline.txt on /boot) is updated to point at the
    new slot.
5.  Client calls /reboot  (or the server can auto-reboot after a delay).
6.  On next boot the device runs from the freshly written slot.

Rollback
--------
If the new slot fails to boot within BOOT_TIMEOUT seconds the watchdog
daemon (ota-watchdog.service) marks the slot bad and reverts cmdline.txt.

Security note
-------------
This server is intentionally simple and is meant to run on a
network-isolated management interface.  Add TLS and token-based
authentication before exposing it to an untrusted network.
"""

import os
import sys
import json
import logging
import subprocess
import threading
import tempfile
import bz2
import hashlib
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PORT          = int(os.environ.get("OTA_PORT", 8080))
BOOT_MOUNT    = "/boot"
CMDLINE_PATH  = os.path.join(BOOT_MOUNT, "cmdline.txt")
SLOT_A_DEV    = os.environ.get("OTA_SLOT_A", "/dev/mmcblk0p2")
SLOT_B_DEV    = os.environ.get("OTA_SLOT_B", "/dev/mmcblk0p3")
SLOT_A_LABEL  = "rootA"
SLOT_B_LABEL  = "rootB"
UPLOAD_DIR    = os.environ.get("OTA_UPLOAD_DIR", "/data/ota")
VERSION_FILE  = "/etc/ota-version"
MAX_UPLOAD_MB = int(os.environ.get("OTA_MAX_MB", 4096))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("ota-server")

# Shared state – protected by _lock
_lock          = threading.Lock()
_update_ready  = False   # True after a successful /update
_pending_slot  = None    # "A" or "B"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _read_cmdline() -> str:
    try:
        with open(CMDLINE_PATH) as fh:
            return fh.read().strip()
    except OSError as exc:
        log.error("Cannot read %s: %s", CMDLINE_PATH, exc)
        return ""


def _write_cmdline(line: str) -> None:
    # Write to a temp file on the boot partition then atomically rename
    tmp = CMDLINE_PATH + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(line + "\n")
    os.replace(tmp, CMDLINE_PATH)
    subprocess.run(["sync"], check=True)


def _active_slot() -> str:
    """Return 'A' or 'B' based on the root= parameter in cmdline.txt."""
    cmdline = _read_cmdline()
    for token in cmdline.split():
        if token.startswith("root="):
            val = token[5:]
            if SLOT_A_DEV in val or SLOT_A_LABEL in val:
                return "A"
            if SLOT_B_DEV in val or SLOT_B_LABEL in val:
                return "B"
    # Default: assume A
    return "A"


def _inactive_slot() -> str:
    return "B" if _active_slot() == "A" else "A"


def _slot_device(slot: str) -> str:
    return SLOT_A_DEV if slot == "A" else SLOT_B_DEV


def _slot_label(slot: str) -> str:
    return SLOT_A_LABEL if slot == "A" else SLOT_B_LABEL


def _read_version() -> str:
    try:
        with open(VERSION_FILE) as fh:
            return fh.read().strip()
    except OSError:
        return "unknown"


def _switch_cmdline(new_slot: str) -> None:
    """Rewrite cmdline.txt to boot from *new_slot* on next boot."""
    cmdline = _read_cmdline()
    tokens = cmdline.split()
    new_root = f"root=PARTLABEL={_slot_label(new_slot)}"
    replaced = False
    for i, tok in enumerate(tokens):
        if tok.startswith("root="):
            tokens[i] = new_root
            replaced = True
            break
    if not replaced:
        tokens.insert(0, new_root)
    _write_cmdline(" ".join(tokens))
    log.info("cmdline.txt updated to boot from slot %s (%s)", new_slot, new_root)


def _stream_image_to_device(src_path: str, device: str, slot: str) -> None:
    """Write *src_path* (raw ext4 or bz2-compressed ext4) onto *device*."""
    log.info("Writing image %s → %s", src_path, device)

    is_bz2 = src_path.endswith(".bz2")

    if is_bz2:
        decompress = subprocess.Popen(
            ["bzip2", "-d", "-c", src_path],
            stdout=subprocess.PIPE,
        )
        dd = subprocess.Popen(
            ["dd", f"of={device}", "bs=4M", "conv=fsync", "status=progress"],
            stdin=decompress.stdout,
        )
        decompress.stdout.close()
        dd.wait()
        decompress.wait()
        if dd.returncode != 0 or decompress.returncode != 0:
            raise RuntimeError("Image write failed (bz2 pipeline)")
    else:
        subprocess.run(
            ["dd", f"if={src_path}", f"of={device}", "bs=4M", "conv=fsync", "status=progress"],
            check=True,
        )

    # Re-label the filesystem so the kernel can find it via PARTLABEL
    subprocess.run(["e2label", device, _slot_label(slot)], check=False)
    log.info("Image written successfully to %s", device)


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class OTAHandler(BaseHTTPRequestHandler):
    server_version = "OTA-Server/1.0"

    # ------------------------------------------------------------------
    def log_message(self, fmt, *args):  # redirect to our logger
        log.info(fmt, *args)

    # ------------------------------------------------------------------
    def _send_json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ------------------------------------------------------------------
    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")

        if path == "/status":
            self._handle_status()
        elif path == "/reboot":
            self._handle_reboot()
        else:
            self._send_json(404, {"error": "not found", "path": path})

    # ------------------------------------------------------------------
    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")

        if path == "/update":
            self._handle_update()
        else:
            self._send_json(404, {"error": "not found", "path": path})

    # ------------------------------------------------------------------
    def _handle_status(self):
        with _lock:
            ready = _update_ready
            pending = _pending_slot
        self._send_json(200, {
            "active_slot":   _active_slot(),
            "inactive_slot": _inactive_slot(),
            "slot_a_device": SLOT_A_DEV,
            "slot_b_device": SLOT_B_DEV,
            "version":       _read_version(),
            "update_ready":  ready,
            "pending_slot":  pending,
        })

    # ------------------------------------------------------------------
    def _handle_update(self):
        global _update_ready, _pending_slot

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length <= 0:
            self._send_json(400, {"error": "Content-Length required"})
            return

        max_bytes = MAX_UPLOAD_MB * 1024 * 1024
        if content_length > max_bytes:
            self._send_json(413, {
                "error": f"Image too large (max {MAX_UPLOAD_MB} MiB)"
            })
            return

        # Determine filename from Content-Disposition or default
        disposition = self.headers.get("Content-Disposition", "")
        filename = "ota-image.ext4"
        for part in disposition.split(";"):
            part = part.strip()
            if part.startswith("filename="):
                filename = part[9:].strip('"')
                break

        os.makedirs(UPLOAD_DIR, exist_ok=True)
        dest_path = os.path.join(UPLOAD_DIR, filename)

        log.info("Receiving OTA image → %s (%d bytes)", dest_path, content_length)

        received = 0
        try:
            with open(dest_path, "wb") as fh:
                remaining = content_length
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    fh.write(chunk)
                    remaining -= len(chunk)
                    received  += len(chunk)
        except OSError as exc:
            self._send_json(500, {"error": f"Failed to save image: {exc}"})
            return

        if received != content_length:
            self._send_json(400, {
                "error": f"Incomplete upload: got {received}/{content_length} bytes"
            })
            return

        checksum = _sha256(dest_path)
        log.info("Image received, SHA-256=%s", checksum)

        # Verify client-supplied checksum if provided
        expected = self.headers.get("X-Image-SHA256", "")
        if expected and expected.lower() != checksum:
            self._send_json(400, {
                "error": "SHA-256 mismatch",
                "expected": expected,
                "actual":   checksum,
            })
            os.unlink(dest_path)
            return

        # Write image to the inactive slot (blocking – may take minutes)
        inactive = _inactive_slot()
        device   = _slot_device(inactive)

        try:
            _stream_image_to_device(dest_path, device, inactive)
        except Exception as exc:
            log.error("Image write failed: %s", exc)
            self._send_json(500, {"error": f"Image write failed: {exc}"})
            return

        # Update cmdline.txt to point at the new slot
        try:
            _switch_cmdline(inactive)
        except Exception as exc:
            log.error("cmdline update failed: %s", exc)
            self._send_json(500, {"error": f"cmdline update failed: {exc}"})
            return

        # Clean up the temporary image file
        try:
            os.unlink(dest_path)
        except OSError:
            pass

        with _lock:
            _update_ready = True
            _pending_slot = inactive

        self._send_json(200, {
            "status":      "success",
            "written_to":  device,
            "slot":        inactive,
            "sha256":      checksum,
            "next_action": "POST /reboot to apply, or reboot manually",
        })

    # ------------------------------------------------------------------
    def _handle_reboot(self):
        with _lock:
            ready = _update_ready

        if not ready:
            self._send_json(400, {"error": "No pending update – call /update first"})
            return

        self._send_json(200, {"status": "rebooting"})

        def _do_reboot():
            import time
            time.sleep(1)
            log.info("Initiating reboot for OTA slot switch…")
            subprocess.run(["reboot"], check=False)

        threading.Thread(target=_do_reboot, daemon=True).start()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    if os.geteuid() != 0:
        log.error("OTA server must run as root (needs raw partition write access)")
        sys.exit(1)

    os.makedirs(UPLOAD_DIR, exist_ok=True)

    server = HTTPServer(("0.0.0.0", PORT), OTAHandler)
    log.info("OTA update server listening on port %d", PORT)
    log.info("  NOTE: Bound to all interfaces. Restrict via firewall or set")
    log.info("  OTA_BIND_ADDR env var and rebuild to bind to a specific interface.")
    log.info("Active slot: %s", _active_slot())
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
