# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.
"""Feeder registration client for the Beast + WireGuard ingest path.

This is the identity step for the Beast ingest path. Beast frames carry no
credential, so we register the receiver ONCE here over HTTPS, sending its
receiver_id + beast_id (+ wg_pubkey only for a legacy WireGuard assignment).

Registration is keyless, feed-first / claim-later (the PiAware model): the
registrar creates the receiver UNCLAIMED (owner NULL) and returns a claim_url
the operator opens while logged in to bind it to their account later. Data flows
immediately; nothing about feeding waits on the claim.

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

ADSB-72: the response is VALIDATED (feeder/assignment.py) before anything is
printed, and every printed value is shlex-quoted. installer.sh additionally
refuses to eval any line outside `KEY='safe chars'` - three independent gates
between the network and the root shell.
"""
import json
import os
import shlex
import sys
import time

import requests

try:  # package import (feeder.register) or sibling-module import (plain script)
    from . import assignment
except ImportError:  # pragma: no cover
    import assignment

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
    on a permanent rejection (receiver owned by another, keyless registration not
    enabled, auth not configured) or once retries are exhausted.
    """
    if not receiver_id:
        raise RegistrationError("receiver_id is required")
    beast_id = beast_id or derive_beast_id(receiver_id)
    url = registrar_url.rstrip("/") + "/receivers/register"
    body = {
        "receiver_id": receiver_id,
        "beast_id": beast_id,
    }
    # ADSB-34 (WireGuard -> direct Beast): wg_pubkey is sent ONLY for a legacy
    # WireGuard registration. A direct (tunnel-less) feeder omits it, and the
    # registrar assigns no shard/tunnel and returns the public Beast endpoint.
    if wg_pubkey:
        body["wg_pubkey"] = wg_pubkey
    # No api_key is ever sent: the receiver registers UNCLAIMED and the registrar
    # returns a claim_url to bind it to an account later (feed-first/claim-later).
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
            # Keyless registration is not enabled on this registrar yet.
            raise RegistrationError(
                "this registrar is not accepting keyless registrations yet — "
                "please try again later")
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


def _emit_shell(fields: dict) -> None:
    """Print the VALIDATED registration fields (assignment.validate_registration)
    as shell KEY=VALUE lines for installer.sh to eval: BEAST_ID SHARD TUNNEL_IP
    ENABLED WG_* BEAST_HOST BEAST_PORT MLAT_ENABLED MLAT_REASON MLAT_SERVER_HOST
    MLAT_SERVER_PORT CLAIM_URL SECRET_STATUS.

    ADSB-72: every value goes through shlex.quote(). Before that fix the line
    was f"{k}='{v}'", so a single quote inside e.g. beast_host ended the quoting
    and the rest of the value ran as root in the installer's eval. Quoting here
    is the second gate; validation is the first and the installer's line regex
    the third - none of them relies on the others."""
    for k, v in fields.items():
        print(f"{k}={shlex.quote(str(v))}")


def main() -> int:
    registrar_url = os.getenv("REGISTRAR_URL", DEFAULT_REGISTRAR_URL)
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

    # ADSB-72: nothing from the response reaches the installer's shell before it
    # has passed the strict format checks. A legitimate registrar never fails
    # them, so a failure here means a misconfigured or compromised server - the
    # install stops and changes nothing. (ADSB-34: direct and legacy assignments
    # are both accepted; a response naming no Beast endpoint is unusable.)
    try:
        fields = assignment.validate_registration(reg)
    except assignment.InvalidAssignment as e:
        _stderr(f"❌ registrar response rejected ({e}). The server sent a value in an "
                "unexpected format; nothing was installed. Please report this to Dataero.")
        _stderr(f"   response: {json.dumps(reg)[:600]}")
        return 1
    _emit_shell(fields)
    return 0


if __name__ == "__main__":
    sys.exit(main())
