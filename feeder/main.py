# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.

import time
import json
import requests
import os
import socket
import threading
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Configuration
API_KEY = os.getenv("API_KEY", "")
API_URL = "https://radar.dataero.eu/api/v1/messages"
HEARTBEAT_URL = "https://radar.dataero.eu/api/v1/heartbeat"
READSB_DATA = os.getenv("READSB_DATA", "/run/readsb/aircraft.json")
# Feed mode. In "beast" mode this process does NOT POST aircraft.json — instead
# a background thread forwards the decoder's local Beast output straight to the
# Dataero Beast server, and the main loop's only other job is the heartbeat. The
# raw Beast protocol carries no API key, so the server attributes the stream by
# matching its public source IP to the account; the heartbeat (bearer token ->
# public IP) is what maintains that mapping. Hence the heartbeat must keep firing
# in Beast mode. Any other value keeps the JSON-POST behaviour, which works
# everywhere.
FEED_MODE = os.getenv("FEED_MODE", "json").strip().lower()
BEAST_MODE = FEED_MODE == "beast"
# "reduce" mode (FR24 hard rule): readsb itself forwards a *reduced* Beast
# stream (with UUID) to the aggregator via its native beast_reduce_plus_out
# connector — configured by feeder/configure_readsb_reduce.sh. This process then
# does NOT byte-pump and does NOT POST; its only job is the heartbeat. Unlike
# the raw byte-pump "beast" mode, the UUID is carried in-band, so provenance no
# longer depends on the public-IP binding (the heartbeat is kept for liveness).
REDUCE_MODE = FEED_MODE == "reduce"
# Beast-mode forwarding endpoints. In Beast mode this process is a plain TCP byte
# pump: it connects to the decoder's LOCAL Beast output port as just another
# read-only consumer (exactly like the FlightAware / FR24 / ADSBExchange feed
# clients) and forwards the raw stream to the Dataero Beast server. Because we
# never touch the decoder's own config, any other feeder reading the same port
# is unaffected. The destination mirrors the constants in installer.sh and is
# intentionally not env-overridable (same policy as API_URL); 30005 is the
# near-universal readsb/dump1090 beast_out port.
BEAST_SERVER = "adsb.dataero.eu"
BEAST_PORT = 30005
BEAST_SRC_HOST = "127.0.0.1"
BEAST_SRC_PORT = 30005
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

HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
    "X-Target-Host": "radar.dataero.eu"
}

# A module-level Session keeps the TLS connection to the API alive across
# calls, eliminating the TCP+TLS handshake that requests.post() would do
# on every send (~30 handshakes/min for messages + heartbeat otherwise).
session = requests.Session()
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
    """POST a heartbeat so the API knows this feeder is online even when
    readsb has no aircraft to report. The feeder is identified by the bearer
    token in the header; the API records the public source IP from the TCP
    connection itself, which is more reliable than anything the Pi could
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

def beast_forward_loop():
    """Beast mode only: pipe the decoder's local Beast output to the Dataero
    Beast server, reconnecting with backoff whenever either side drops.

    We connect to the decoder's beast_out port purely as a read-only consumer —
    the same way every other feed client (FlightAware, FR24, ADSBExchange) does —
    so we never modify the decoder's configuration and never disturb any other
    feeder already reading that port. Runs in its own daemon thread; the
    heartbeat keeps firing from the main loop because the raw Beast protocol
    carries no API key (the server binds our account to this device's public IP
    via the heartbeat)."""
    backoff = 1
    while True:
        try:
            src = socket.create_connection(
                (BEAST_SRC_HOST, BEAST_SRC_PORT), timeout=REQUEST_TIMEOUT[0]
            )
            try:
                dst = socket.create_connection(
                    (BEAST_SERVER, BEAST_PORT), timeout=REQUEST_TIMEOUT[0]
                )
            except Exception:
                src.close()
                raise
            log_debug(
                f"Beast forward connected: {BEAST_SRC_HOST}:{BEAST_SRC_PORT} "
                f"-> {BEAST_SERVER}:{BEAST_PORT}"
            )
            backoff = 1
            with src, dst:
                # Block on the decoder side — a short timeout would just churn
                # CPU in quiet airspace. A dead remote surfaces on sendall().
                src.settimeout(None)
                while True:
                    chunk = src.recv(65536)
                    if not chunk:
                        log_debug("Beast forward: decoder closed; reconnecting")
                        break
                    dst.sendall(chunk)
        except Exception as e:
            log_debug(f"Beast forward error: {e}")
            print(f"beast forward error: {e}", flush=True)
        # Backoff before reconnecting; capped so a long outage retries calmly.
        time.sleep(backoff)
        backoff = min(backoff * 2, 30)

if __name__ == "__main__":
    if REDUCE_MODE:
        print(
            "dataero-adsb-feeder running in REDUCE mode; readsb forwards a reduced "
            "Beast stream (with UUID) to the Dataero aggregator natively via its "
            f"beast_reduce_plus_out connector. This process only heartbeats ({HEARTBEAT_URL}).",
            flush=True,
        )
    elif BEAST_MODE:
        print(
            f"dataero-adsb-feeder running in BEAST mode; forwarding the decoder's "
            f"Beast stream {BEAST_SRC_HOST}:{BEAST_SRC_PORT} -> {BEAST_SERVER}:{BEAST_PORT}, "
            f"heartbeat={HEARTBEAT_URL}",
            flush=True,
        )
        threading.Thread(target=beast_forward_loop, daemon=True).start()
    else:
        print(f"dataero-adsb-feeder running; messages={API_URL} heartbeat={HEARTBEAT_URL}", flush=True)
    last_heartbeat = 0.0
    while True:
        if not BEAST_MODE and not REDUCE_MODE:
            send_data()
        now = time.time()
        if now - last_heartbeat >= HEARTBEAT_INTERVAL_SECONDS:
            send_heartbeat()
            last_heartbeat = now
        time.sleep(POLL_INTERVAL_SECONDS)
