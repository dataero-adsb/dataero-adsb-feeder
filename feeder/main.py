# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.

import os
import subprocess
import time

import requests
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Daemon version, reported in every heartbeat (ADSB-29/30). The server records
# it on adsb.receivers so shard_drain can tell which feeders are reconfig-capable.
# 1.1.0 = heartbeat-driven reconfig (this file applies config changes itself).
# 1.2.0 = dual-mode (ADSB-34): applies EITHER a direct-Beast assignment (no
#         wireguard block — readsb forwards straight to the public hub over plain
#         TCP) OR a legacy WireGuard assignment, whichever the server sends.
FEEDER_VERSION = "1.2.0"

# Configuration
#
# The feeder runs readsb as a net-only forwarder of a reduced Beast stream (with
# in-band UUID) to its assigned Dataero ingest hub. Two transports coexist during
# the WireGuard -> direct migration (ADSB-34), selected by the server's config:
#   * DIRECT (ADSBexchange model): readsb dials the PUBLIC hub endpoint over plain
#     TCP. No tunnel. Identity is the in-band beast_id only.
#   * LEGACY: readsb sends Beast to the hub's overlay address over a WireGuard
#     tunnel set up at install. Kept working until the fleet has migrated.
# Identity is bound to the account at registration (api_key -> owner). This process
# does NOT POST aircraft data; its only job is the registrar heartbeat (liveness /
# last_seen_at) and applying any reassignment the heartbeat announces.
REGISTRAR_URL = os.getenv("REGISTRAR_URL", "https://adsb.dataero.eu").rstrip("/")
RECEIVER_UUID = os.getenv("RECEIVER_UUID", "").strip()
# Optional self-reported position (the hub records the public IP regardless).
FEEDER_LAT = os.getenv("FEEDER_LAT", "").strip()
FEEDER_LON = os.getenv("FEEDER_LON", "").strip()
FEEDER_ALT_M = os.getenv("FEEDER_ALT_M", "").strip()
REGISTRAR_HEARTBEAT_URL = f"{REGISTRAR_URL}/receivers/heartbeat"

DEBUG = os.getenv("DEBUG", "FALSE").upper() == "TRUE"
DEBUG_LOG = "/var/log/dataero-adsb-feeder.log" if DEBUG else None

# ── Heartbeat-driven reconfig (ADSB-30) ──────────────────────────────────────
# The heartbeat response carries the receiver's CURRENT assignment (config +
# config_epoch). When the epoch changes — shard reassignment after a drain, hub
# key rotation, endpoint move — this daemon re-applies the WireGuard tunnel and
# the dataero-readsb forwarder itself, so destroying/redeploying a ctr hub never
# strands a feeder. BUBBLE RULE: only OUR units are touched (wg-adsb +
# dataero-readsb.service via the existing idempotent scripts); the shared
# decoder and other feeds are never involved.
INSTALL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV_FILE = os.path.join(INSTALL_DIR, ".env")
WG_CONF = "/etc/wireguard/wg-adsb.conf"
# After a FAILED reconfigure, wait this long before retrying (a failing
# wg-quick bounce every heartbeat would itself disturb the feed).
RECONFIG_RETRY_SECONDS = 300
RECONFIG_TIMEOUT_SECONDS = 120

# Epoch of the config this install has applied. Empty on pre-ADSB-30 installs:
# the first heartbeat then compares VALUES against the applied state and adopts
# the epoch silently when they already match (no pointless tunnel bounce).
_applied_epoch = os.getenv("CONFIG_EPOCH", "").strip()
_last_reconfig_fail_ts = 0.0

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

def _update_env_file(updates):
    """Persist KEY=VALUE pairs into the install's .env (single occurrence per
    key — strips any duplicates an older append-style write left behind) and
    mirror them into os.environ. 0600 like the installer (it holds secrets)."""
    lines = []
    try:
        with open(ENV_FILE) as f:
            lines = f.readlines()
    except FileNotFoundError:
        pass
    kept = [l for l in lines
            if "=" not in l or l.split("=", 1)[0].strip() not in updates]
    if kept and not kept[-1].endswith("\n"):
        kept[-1] += "\n"
    for k, v in updates.items():
        kept.append(f"{k}={v}\n")
    tmp = ENV_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(kept)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ENV_FILE)
    for k, v in updates.items():
        os.environ[k] = str(v)


def _wg_conf_peer():
    """(hub_public_key, hub_endpoint) currently applied in the WireGuard config,
    or (None, None) when unreadable — callers treat that as 'unknown, re-apply'."""
    pub = endpoint = None
    try:
        with open(WG_CONF) as f:
            for line in f:
                k, _, v = line.partition("=")
                key = k.strip().lower()
                if key == "publickey":
                    pub = v.strip()
                elif key == "endpoint":
                    endpoint = v.strip()
    except OSError:
        pass
    return pub, endpoint


def _config_matches_applied(cfg):
    """True when the heartbeat config equals what this install already applied —
    .env for shard/tunnel/beast, and (legacy only) the live WireGuard conf for the
    hub key/endpoint — so a fresh epoch can be adopted without bouncing anything
    (the first heartbeat after upgrading a Pi must be a no-op)."""
    wg = cfg.get("wireguard") or {}
    agg = cfg.get("aggregator") or {}
    beast_matches = (
        str(agg.get("beast_host")) == os.getenv("BEAST_HOST", "").strip()
        and str(agg.get("beast_port")) == os.getenv("BEAST_PORT", "").strip()
    )
    if not wg:
        # DIRECT (ADSB-34): no tunnel — only the public Beast endpoint matters, and
        # the feeder must already have shed any prior shard.
        return beast_matches and os.getenv("SHARD", "").strip() in ("", "None")
    # LEGACY tunnel: also compare shard/tunnel and the live wg conf peer.
    wg_pub, wg_ep = _wg_conf_peer()
    return (
        str(cfg.get("shard")) == os.getenv("SHARD", "").strip()
        and str(cfg.get("tunnel_ip")) == os.getenv("TUNNEL_IP", "").strip()
        and beast_matches
        and wg_pub is not None and wg.get("hub_public_key") == wg_pub
        and wg_ep is not None and wg.get("hub_endpoint") == wg_ep
    )


def _run_feeder_script(script, env_extra):
    """Run one of our idempotent setup scripts (they only touch OUR units)."""
    path = os.path.join(INSTALL_DIR, "feeder", script)
    res = subprocess.run(
        ["bash", path], env={**os.environ, **{k: str(v) for k, v in env_extra.items()}},
        capture_output=True, text=True, timeout=RECONFIG_TIMEOUT_SECONDS)
    if res.returncode != 0:
        raise RuntimeError(
            f"{script} exited {res.returncode}: {res.stderr.strip()[-400:]}")


def _teardown_tunnel():
    """Bring down and remove the legacy wg-adsb tunnel if present (ADSB-34
    migration to direct Beast). Idempotent and scoped to OUR interface only
    (BUBBLE RULE — never touches other WireGuard interfaces)."""
    if not os.path.exists(WG_CONF):
        return
    try:
        subprocess.run(["wg-quick", "down", "wg-adsb"],
                       capture_output=True, text=True, timeout=30)
    except Exception as e:
        log_debug(f"wg-adsb teardown (down) note: {e}")
    try:
        os.remove(WG_CONF)
    except OSError as e:
        log_debug(f"wg-adsb teardown (rm) note: {e}")


def maybe_apply_config(resp):
    """Apply a changed assignment from the heartbeat response (ADSB-30/34).

    No-ops when: no/partial config block, epoch already applied, or a recent
    failed attempt is still inside its retry window. Adopts the epoch silently
    when the values already match the applied state. Otherwise re-applies the
    transport the server dictates and persists the new values (+ CONFIG_EPOCH) to
    .env only after it succeeds:
      * DIRECT (ADSB-34, no wireguard block): tear down any leftover tunnel, then
        point the readsb forwarder at the public hub endpoint.
      * LEGACY (wireguard block present): run wg_setup.sh + the forwarder."""
    global _applied_epoch, _last_reconfig_fail_ts
    cfg = resp.get("config")
    epoch = (resp.get("config_epoch") or "").strip()
    if not cfg or not epoch or epoch == _applied_epoch:
        return
    wg = cfg.get("wireguard") or {}
    agg = cfg.get("aggregator") or {}
    direct = not wg  # ADSB-34: no wireguard block => direct Beast transport

    if direct:
        needed = (agg.get("beast_host"), agg.get("beast_port"))
    else:
        needed = (cfg.get("tunnel_ip"), wg.get("hub_public_key"), wg.get("hub_endpoint"),
                  wg.get("address"), wg.get("allowed_ips"),
                  agg.get("beast_host"), agg.get("beast_port"))
    if any(v in (None, "") for v in needed):
        return  # never act on a partial assignment

    if _config_matches_applied(cfg):
        _update_env_file({"CONFIG_EPOCH": epoch})
        _applied_epoch = epoch
        log_debug(f"config epoch {epoch} adopted (values already applied)")
        return

    if time.time() - _last_reconfig_fail_ts < RECONFIG_RETRY_SECONDS:
        return

    wg_privkey = ""
    if not direct:
        wg_privkey = os.getenv("WG_PRIVKEY", "").strip()
        if not wg_privkey:
            _maybe_print_error("legacy reconfig skipped: WG_PRIVKEY not in .env — "
                               "re-run the installer to migrate this feeder.")
            return

    print(f"assignment changed ({'direct' if direct else 'tunnel'}; epoch {epoch}) "
          "— reconfiguring the Dataero forwarder (our own services only)...",
          flush=True)
    try:
        if direct:
            _teardown_tunnel()  # shed any leftover wg-adsb from a prior legacy install
        else:
            _run_feeder_script("wg_setup.sh", {
                "WG_PRIVKEY": wg_privkey,
                "WG_ADDRESS": wg["address"],
                "WG_HUB_PUBKEY": wg["hub_public_key"],
                "WG_HUB_ENDPOINT": wg["hub_endpoint"],
                "WG_ALLOWED_IPS": wg["allowed_ips"],
                "WG_KEEPALIVE": wg.get("persistent_keepalive", 25),
            })
        _run_feeder_script("configure_readsb_reduce.sh", {
            "UUID": RECEIVER_UUID,
            "HUB_HOST": agg["beast_host"],
            "HUB_PORT": agg["beast_port"],
            "REDUCE_INTERVAL": os.getenv("REDUCE_INTERVAL", "0.25"),
            "LOCAL_BEAST_PORT": os.getenv("LOCAL_BEAST_PORT", "30005"),
        })
    except Exception as e:
        _last_reconfig_fail_ts = time.time()
        log_debug(f"reconfigure failed: {e}")
        print(f"reconfigure failed (will retry in {RECONFIG_RETRY_SECONDS}s): {e}",
              flush=True)
        return
    _update_env_file({
        # Direct feeders carry no shard/tunnel — clear them so a later heartbeat
        # match is a no-op and the drain-to-zero check can complete.
        "SHARD": "" if direct else cfg.get("shard"),
        "TUNNEL_IP": "" if direct else cfg.get("tunnel_ip"),
        "BEAST_HOST": agg["beast_host"],
        "BEAST_PORT": agg["beast_port"],
        "CONFIG_EPOCH": epoch,
    })
    _applied_epoch = epoch
    print(f"reconfigured ({'direct' if direct else 'tunnel'}): "
          f"beast -> {agg['beast_host']}:{agg['beast_port']} (epoch {epoch}).",
          flush=True)


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
    payload = {"receiver_id": RECEIVER_UUID, "feeder_version": FEEDER_VERSION}
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
        else:
            # ADSB-30: follow shard reassignments / hub key rotations announced
            # in the heartbeat response. Never let a reconfig hiccup kill the
            # heartbeat loop — liveness reporting always continues.
            try:
                maybe_apply_config(response.json())
            except Exception as e:
                log_debug(f"config apply error: {e}")
                _maybe_print_error(f"heartbeat config apply error: {e}")
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
