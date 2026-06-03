# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.

import time
import requests
import os
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Configuration
#
# The feeder runs in a single mode (Beast + WireGuard): readsb forwards a reduced
# Beast stream (with UUID) to the feeder's assigned Dataero ingest hub OVER A
# WIREGUARD TUNNEL (set up at install from the registration response). Identity is
# bound to the account at registration (api_key -> owner) and re-proven on every
# message by the tunnel source IP + in-band beast_id. This process does NOT POST
# aircraft data; its only job is the registrar heartbeat (liveness / last_seen_at).
# The old json/HTTPS feed mode was removed.
REGISTRAR_URL = os.getenv("REGISTRAR_URL", "https://adsb.dataero.eu").rstrip("/")
RECEIVER_UUID = os.getenv("RECEIVER_UUID", "").strip()
# Optional self-reported position (the hub records the public IP regardless).
FEEDER_LAT = os.getenv("FEEDER_LAT", "").strip()
FEEDER_LON = os.getenv("FEEDER_LON", "").strip()
FEEDER_ALT_M = os.getenv("FEEDER_ALT_M", "").strip()
REGISTRAR_HEARTBEAT_URL = f"{REGISTRAR_URL}/receivers/heartbeat"

DEBUG = os.getenv("DEBUG", "FALSE").upper() == "TRUE"
DEBUG_LOG = "/var/log/dataero-adsb-feeder.log" if DEBUG else None

HEARTBEAT_INTERVAL_SECONDS = 60
# Split connect/read timeouts: fail fast (3s) when the registrar is unreachable,
# but tolerate a slow response on a borderline 4G/LTE link.
REQUEST_TIMEOUT = (3, 10)
# Cap how often a repeated failure is surfaced to stdout, so a multi-hour outage
# doesn't flood journalctl. Lines up with the ~60s heartbeat cadence.
ERROR_PRINT_INTERVAL_SECONDS = 60

# A module-level Session keeps the TLS connection to the registrar alive across
# heartbeats, eliminating the TCP+TLS handshake that requests.post() would
# otherwise do on every send.
session = requests.Session()

# Wall-clock of the last error we printed to stdout. Used purely for the
# rate-limit; not a retry timer.
_last_error_print_ts = 0.0

def log_debug(message):
    """Append a message to the debug log with a timestamp if DEBUG is TRUE."""
    if DEBUG:
        with open(DEBUG_LOG, "a") as log_file:
            timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
            log_file.write(f"[{timestamp}] {message}\n")

def _maybe_print_error(message):
    """Surface a transient failure to stdout, rate-limited so a long outage
    doesn't spam journalctl every cycle."""
    global _last_error_print_ts
    now = time.time()
    if now - _last_error_print_ts >= ERROR_PRINT_INTERVAL_SECONDS:
        print(message, flush=True)
        _last_error_print_ts = now

def send_registrar_heartbeat():
    """POST a heartbeat to the Dataero registrar, keyed on this feeder's
    receiver_id (established at registration). Bumps last_seen_at server side.
    No bearer token — identity is the receiver_id, not the API key. An
    ok=false / 404 means the receiver is unknown or disabled (e.g. removed in the
    portal); surface it so the operator knows to re-run the installer.

    Failures print to stdout (journalctl-visible) regardless of DEBUG."""
    if not RECEIVER_UUID:
        _maybe_print_error("beast heartbeat skipped: RECEIVER_UUID not set "
                           "(re-run the installer to register this feeder)")
        return
    payload = {"receiver_id": RECEIVER_UUID}
    if FEEDER_LAT:
        payload["lat"] = float(FEEDER_LAT)
    if FEEDER_LON:
        payload["lon"] = float(FEEDER_LON)
    if FEEDER_ALT_M:
        payload["altitude_m"] = float(FEEDER_ALT_M)
    try:
        response = session.post(
            REGISTRAR_HEARTBEAT_URL, json=payload, timeout=REQUEST_TIMEOUT)
        log_debug(f"Registrar heartbeat response: {response.status_code} {response.text}")
        if response.status_code == 404 or (response.ok and response.json().get("ok") is False):
            print("registrar heartbeat: receiver unknown or disabled — re-run the "
                  "installer to re-register this feeder.", flush=True)
        elif not response.ok:
            print(f"registrar heartbeat failed: HTTP {response.status_code} {response.text[:200]}", flush=True)
    except Exception as e:
        log_debug(f"Registrar heartbeat error: {e}")
        print(f"registrar heartbeat error: {e}", flush=True)

if __name__ == "__main__":
    print(
        "dataero-adsb-feeder running; readsb forwards a reduced Beast stream "
        "(with UUID) to the assigned Dataero ingest hub over the WireGuard "
        f"tunnel. This process only heartbeats ({REGISTRAR_HEARTBEAT_URL}).",
        flush=True,
    )
    while True:
        send_registrar_heartbeat()
        time.sleep(HEARTBEAT_INTERVAL_SECONDS)
