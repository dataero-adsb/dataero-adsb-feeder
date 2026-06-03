# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.
"""Feeder registration client for the Beast + WireGuard ingest path.

This is the identity step that replaces the per-POST API key of the HTTPS json
mode. Beast frames carry no credential, so we authenticate ONCE here over HTTPS:

  feeder --(api_key + receiver_id + beast_id + wg_pubkey)--> registrar
  registrar  resolves api_key -> owner, records adsb.receivers, returns the
             WireGuard config of the shard the feeder was assigned.

The api_key is OPTIONAL (feed-first, claim-later — the PiAware model): without
it the registrar creates the receiver UNCLAIMED (owner NULL) and returns a
claim_url the operator can open while logged in to bind it to their account
later. Data flows either way. Re-registering an unclaimed receiver WITH a key
upgrades it in place server-side.

Thereafter the Beast stream is bound to the receiver by the WireGuard tunnel
(source tunnel_ip) AND by the in-band beast_id (readsb --uuid), both of which
the aggregator maps back to this receiver -> its owner (or the unclaimed pool).

beast_id derivation is the easy thing to get wrong: readsb's --uuid is parsed by
read_uuid() (net_io.c) which takes the FIRST 16 hex chars (dashes skipped) as the
64-bit receiverId, and the Beast 0x1a 0xe3 frame on the wire carries only those
8 bytes. So the value we must register is the first 16 hex chars of the UUID, NOT
the full 32-char UUID — registering the full UUID makes attribution silently fail.

Importable (register_feeder / derive_beast_id) and runnable. As __main__ it reads
config from the environment and prints the resulting WireGuard + aggregator config
as shell `KEY=VALUE` lines on stdout (so installer.sh can `eval` it), exiting
non-zero on failure.
"""
import json
import os
import sys
import time

import requests

DEFAULT_REGISTRAR_URL = "https://adsb.dataero.eu"
# Split connect/read timeouts: fail fast when the registrar is unreachable, but
# tolerate a slow response on a borderline 4G/LTE link.
REQUEST_TIMEOUT = (5, 15)


class RegistrationError(Exception):
    """Registration was refused for a reason retrying won't fix."""


def derive_beast_id(receiver_uuid: str) -> str:
    """First 16 hex chars of the UUID (dashes/spaces stripped, lowercased) — the
    64-bit receiverId readsb emits on the Beast wire from --uuid. See module docstring."""
    hex_only = "".join(c for c in receiver_uuid.lower() if c in "0123456789abcdef")
    if len(hex_only) < 16:
        raise ValueError(
            f"receiver UUID {receiver_uuid!r} has fewer than 16 hex chars; "
            "cannot derive a 64-bit beast_id"
        )
    return hex_only[:16]


def register_feeder(
    *,
    registrar_url: str,
    api_key: str,
    receiver_id: str,
    wg_pubkey: str,
    beast_id: str = "",
    name: str = "",
    lat=None,
    lon=None,
    altitude_m=None,
    mlat_enabled: bool = False,
    retries: int = 6,
    backoff: float = 10.0,
) -> dict:
    """POST to <registrar>/receivers/register and return the parsed response.

    Retries while the registrar reports a transient, retryable condition (503 with
    retry=true, e.g. no shard has published itself yet). Raises RegistrationError
    on a permanent rejection (bad key, receiver owned by another, auth not
    configured) or once retries are exhausted.
    """
    if not (receiver_id and wg_pubkey):
        raise RegistrationError("receiver_id and wg_pubkey are required")
    beast_id = beast_id or derive_beast_id(receiver_id)
    url = registrar_url.rstrip("/") + "/receivers/register"
    body = {
        "receiver_id": receiver_id,
        "beast_id": beast_id,
        "wg_pubkey": wg_pubkey,
    }
    # api_key is optional: omitted => the receiver registers UNCLAIMED and the
    # registrar returns a claim_url to bind it to an account later.
    if api_key:
        body["api_key"] = api_key
    if name:
        body["name"] = name
    if lat is not None:
        body["lat"] = lat
    if lon is not None:
        body["lon"] = lon
    if altitude_m is not None:
        body["altitude_m"] = altitude_m
    # MLAT opt-in (epic ADSB-17). The registrar honours it only with a full
    # position (returns mlat_reason='position_required' otherwise) and, when
    # accepted, returns the central mlat-server endpoint to dial.
    if mlat_enabled:
        body["mlat_enabled"] = True

    # HAProxy fronts the Dataero edge; mirror the radar feeder's host-routing hint.
    headers = {"Content-Type": "application/json",
               "X-Target-Host": _host(registrar_url)}

    last_reason = "unknown"
    for attempt in range(1, retries + 1):
        try:
            resp = requests.post(url, json=body, headers=headers, timeout=REQUEST_TIMEOUT)
        except requests.RequestException as e:
            last_reason = f"transport error: {e}"
            _stderr(f"register attempt {attempt}/{retries} failed ({last_reason}); retrying in {backoff:.0f}s")
            time.sleep(backoff)
            continue

        if resp.status_code == 200:
            return resp.json()

        data = _safe_json(resp)
        reason = data.get("error", f"http_{resp.status_code}")
        # Transient: a shard hasn't published itself yet, or auth resolver not up.
        if resp.status_code == 503 and data.get("retry"):
            last_reason = reason
            _stderr(f"register deferred ({reason}); retrying in {backoff:.0f}s "
                    f"[{attempt}/{retries}]")
            time.sleep(backoff)
            continue
        # Permanent rejections — surface a clear, actionable message.
        if resp.status_code == 401:
            if api_key:
                raise RegistrationError(
                    "invalid API key — check it at https://radar.dataero.eu/profile")
            # No key was sent: this registrar doesn't accept anonymous
            # registration (yet) — the operator has to provide a key after all.
            raise RegistrationError(
                "this registrar requires an API key (anonymous registration is "
                "not enabled) — get one at https://radar.dataero.eu/profile and "
                "re-run the installer")
        if resp.status_code == 403:
            raise RegistrationError(
                "this receiver id is already registered to another account")
        if resp.status_code == 503 and reason == "auth_not_configured":
            raise RegistrationError(
                "the Dataero registrar is not accepting registrations yet "
                "(auth not configured server-side) — try again later")
        raise RegistrationError(f"registration failed: HTTP {resp.status_code} {reason}")

    raise RegistrationError(
        f"no ingest shard became available after {retries} attempts (last: {last_reason})")


def _host(url: str) -> str:
    return url.split("://", 1)[-1].split("/", 1)[0]


def _safe_json(resp) -> dict:
    try:
        d = resp.json()
        return d if isinstance(d, dict) else {}
    except ValueError:
        return {}


def _stderr(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _emit_shell(reg: dict) -> None:
    """Print the registration result as shell KEY=VALUE lines for installer.sh to eval.
    Only the fields the installer needs to bring up WireGuard, point readsb at the
    hub, and persist hub config in .env."""
    wg = reg.get("wireguard") or {}
    agg = reg.get("aggregator") or {}
    mlat = reg.get("mlat") or {}
    out = {
        "BEAST_ID": reg.get("beast_id", ""),
        "SHARD": reg.get("shard", ""),
        "TUNNEL_IP": reg.get("tunnel_ip", ""),
        "ENABLED": reg.get("enabled", ""),
        "WG_ADDRESS": wg.get("address", ""),
        "WG_HUB_PUBKEY": wg.get("hub_public_key", ""),
        "WG_HUB_ENDPOINT": wg.get("hub_endpoint", ""),
        "WG_ALLOWED_IPS": wg.get("allowed_ips", ""),
        "WG_KEEPALIVE": wg.get("persistent_keepalive", 25),
        "BEAST_HOST": agg.get("beast_host", ""),
        "BEAST_PORT": agg.get("beast_port", ""),
        # MLAT (epic ADSB-17): whether the opt-in was honoured, why not (if so),
        # and the central mlat-server endpoint to dial when it was. server_host is
        # empty unless MLAT is deployed AND this feeder opted in with a position.
        "MLAT_ENABLED": reg.get("mlat_enabled", False),
        "MLAT_REASON": reg.get("mlat_reason", "") or "",
        "MLAT_SERVER_HOST": mlat.get("server_host", ""),
        "MLAT_SERVER_PORT": mlat.get("server_port", ""),
        # Feed-first, claim-later: set only when the receiver registered without
        # an api_key — the URL the operator opens (logged in) to claim it.
        "CLAIM_URL": reg.get("claim_url", "") or "",
    }
    for k, v in out.items():
        # Values are hex / ip / host / int — safe to single-quote for the shell.
        print(f"{k}='{v}'")


def main() -> int:
    registrar_url = os.getenv("REGISTRAR_URL", DEFAULT_REGISTRAR_URL)
    api_key = os.getenv("API_KEY", "").strip()
    receiver_id = os.getenv("RECEIVER_UUID", "").strip()
    wg_pubkey = os.getenv("WG_PUBKEY", "").strip()
    name = os.getenv("FEEDER_NAME", "").strip()
    lat = os.getenv("FEEDER_LAT", "").strip() or None
    lon = os.getenv("FEEDER_LON", "").strip() or None
    altitude_m = os.getenv("FEEDER_ALT_M", "").strip() or None
    mlat_enabled = os.getenv("MLAT_ENABLED", "").strip().lower() in ("1", "true", "yes")

    try:
        reg = register_feeder(
            registrar_url=registrar_url,
            api_key=api_key,
            receiver_id=receiver_id,
            wg_pubkey=wg_pubkey,
            beast_id=derive_beast_id(receiver_id) if receiver_id else "",
            name=name,
            lat=float(lat) if lat else None,
            lon=float(lon) if lon else None,
            altitude_m=float(altitude_m) if altitude_m else None,
            mlat_enabled=mlat_enabled,
        )
    except (RegistrationError, ValueError) as e:
        _stderr(f"❌ {e}")
        return 1

    if not reg.get("wireguard", {}).get("address"):
        _stderr(f"❌ registrar returned no tunnel config: {json.dumps(reg)}")
        return 1
    _emit_shell(reg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
