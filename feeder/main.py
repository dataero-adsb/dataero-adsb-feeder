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
API_KEY = os.getenv("API_KEY", "")
API_URL = "https://radar.dataero.eu/api/v1/messages"
HEARTBEAT_URL = "https://radar.dataero.eu/api/v1/heartbeat"
READSB_DATA = os.getenv("READSB_DATA", "/run/readsb/aircraft.json")
# Feed mode:
#   beast : readsb forwards a reduced Beast stream (with UUID) to the feeder's
#           assigned Dataero ingest hub OVER A WIREGUARD TUNNEL (set up at install
#           from the registration response). Identity is bound to the account at
#           registration (api_key -> owner) and re-proven on every message by the
#           tunnel source IP + in-band beast_id. This process does NOT POST aircraft
#           data; its only job is the registrar heartbeat (liveness / last_seen_at).
#   json  : POST aircraft.json over HTTPS every 2s plus the radar heartbeat. The
#           no-WireGuard fallback for hosts without readsb; works with any decoder.
# "reduce" is the former name of the (pre-WireGuard) beast path; accept it as an
# alias so existing installs keep working.
FEED_MODE = os.getenv("FEED_MODE", "json").strip().lower()
if FEED_MODE == "reduce":
    FEED_MODE = "beast"
BEAST_MODE = FEED_MODE == "beast"

# --- beast mode: registrar heartbeat target + receiver identity --------------
REGISTRAR_URL = os.getenv("REGISTRAR_URL", "https://adsb.dataero.eu").rstrip("/")
RECEIVER_UUID = os.getenv("RECEIVER_UUID", "").strip()
# Optional self-reported position (the hub records the public IP regardless).
FEEDER_LAT = os.getenv("FEEDER_LAT", "").strip()
FEEDER_LON = os.getenv("FEEDER_LON", "").strip()
FEEDER_ALT_M = os.getenv("FEEDER_ALT_M", "").strip()
REGISTRAR_HEARTBEAT_URL = f"{REGISTRAR_URL}/receivers/heartbeat"

DEBUG = os.getenv("DEBUG", "FALSE").upper() == "TRUE"
DEBUG_LOG = "/var/log/dataero-adsb-feeder.log" if DEBUG else None

POLL_INTERVAL_SECONDS = 2
HEARTBEAT_INTERVAL_SECONDS = 60
# Split connect/read timeouts: fail fast (3s) when the API is unreachable,
# but tolerate slow upload/response on a borderline 4G/LTE link.
REQUEST_TIMEOUT = (3, 10)
# Cap how often a repeated messages-POST failure is surfaced to stdout, so a
# multi-hour API outage doesn't flood journalctl. The heartbeat already
# prints every failure on its own ~60s cadence, so once a minute here lines
# up with that.
ERROR_PRINT_INTERVAL_SECONDS = 60

# json-mode auth: the radar messages/heartbeat endpoints authenticate each
# request by the bearer token. beast mode does NOT use these headers — its
# heartbeat is keyed on the receiver_id established at registration.
HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
    "X-Target-Host": "radar.dataero.eu"
}

# A module-level Session keeps the TLS connection to the API alive across
# calls, eliminating the TCP+TLS handshake that requests.post() would do
# on every send (~30 handshakes/min for messages + heartbeat otherwise).
session = requests.Session()
if not BEAST_MODE:
    session.headers.update(HEADERS)

# mtime of the last aircraft.json snapshot we successfully POSTed. Lets us
# short-circuit when the decoder hasn't refreshed the file (quiet airspace,
# decoder paused, etc.). Stays at its previous value when a POST fails so
# the next cycle retries the same snapshot rather than dropping it.
_last_sent_mtime = 0.0
# Wall-clock of the last messages error we printed to stdout. Used purely
# for the rate-limit; not a retry timer.
_last_error_print_ts = 0.0

def log_debug(message):
    """Append a message to the debug log with a timestamp if DEBUG is TRUE."""
    if DEBUG:
        with open(DEBUG_LOG, "a") as log_file:
            timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
            log_file.write(f"[{timestamp}] {message}\n")

def _maybe_print_error(message):
    """Surface a transient messages-POST failure to stdout, rate-limited so
    a long outage doesn't spam journalctl every 2 seconds."""
    global _last_error_print_ts
    now = time.time()
    if now - _last_error_print_ts >= ERROR_PRINT_INTERVAL_SECONDS:
        print(message, flush=True)
        _last_error_print_ts = now

def send_data():
    """POST aircraft.json verbatim, skipping when the decoder hasn't
    refreshed the file since our last successful upload."""
    global _last_sent_mtime
    try:
        mtime = os.path.getmtime(READSB_DATA)
    except OSError:
        # File doesn't exist yet. Staying alive lets the heartbeat keep
        # firing so the API distinguishes "Pi online, decoder warming up /
        # no aircraft in range" from "Pi offline".
        log_debug(f"Skipping messages POST: file not found: {READSB_DATA}")
        return

    if mtime == _last_sent_mtime:
        # Decoder hasn't written since our last successful POST — nothing
        # new to send. The heartbeat fires independently on its own cadence.
        return

    try:
        with open(READSB_DATA, "rb") as f:
            body = f.read()
    except OSError as e:
        log_debug(f"Messages read error: {e}")
        return

    try:
        response = session.post(API_URL, data=body, timeout=REQUEST_TIMEOUT)
        log_debug(f"Messages response: {response.status_code} {response.text}")
        if response.ok:
            _last_sent_mtime = mtime
        else:
            _maybe_print_error(
                f"messages POST failed: HTTP {response.status_code} {response.text[:200]}"
            )
    except Exception as e:
        log_debug(f"Messages error: {e}")
        _maybe_print_error(f"messages POST error: {e}")

def send_heartbeat():
    """json mode: POST a heartbeat to the radar API so it knows this feeder is
    online even when readsb has no aircraft to report. The feeder is identified
    by the bearer token in the header; the API records the public source IP from
    the TCP connection itself, which is more reliable than anything the Pi could
    self-report from behind NAT.

    Failures are printed to stdout (journalctl-visible) regardless of DEBUG
    so an operator can diagnose without toggling the verbose log file."""
    try:
        response = session.post(
            HEARTBEAT_URL,
            json={"timestamp": int(time.time())},
            timeout=REQUEST_TIMEOUT,
        )
        log_debug(f"Heartbeat response: {response.status_code} {response.text}")
        if not response.ok:
            print(f"heartbeat failed: HTTP {response.status_code} {response.text[:200]}", flush=True)
    except Exception as e:
        log_debug(f"Heartbeat error: {e}")
        print(f"heartbeat error: {e}", flush=True)

def send_registrar_heartbeat():
    """beast mode: POST a heartbeat to the Dataero registrar, keyed on this
    feeder's receiver_id (established at registration). Bumps last_seen_at server
    side. No bearer token — identity is the receiver_id, not the API key. An
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
    if BEAST_MODE:
        print(
            "dataero-adsb-feeder running in BEAST mode; readsb forwards a reduced "
            "Beast stream (with UUID) to the assigned Dataero ingest hub over the "
            f"WireGuard tunnel. This process only heartbeats ({REGISTRAR_HEARTBEAT_URL}).",
            flush=True,
        )
    else:
        print(f"dataero-adsb-feeder running; messages={API_URL} heartbeat={HEARTBEAT_URL}", flush=True)
    last_heartbeat = 0.0
    while True:
        if not BEAST_MODE:
            send_data()
        now = time.time()
        if now - last_heartbeat >= HEARTBEAT_INTERVAL_SECONDS:
            if BEAST_MODE:
                send_registrar_heartbeat()
            else:
                send_heartbeat()
            last_heartbeat = now
        time.sleep(POLL_INTERVAL_SECONDS)
