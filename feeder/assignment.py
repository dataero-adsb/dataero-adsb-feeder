# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.
"""Strict validation of everything the Dataero registrar sends us (ADSB-72).

The registration response (installer.sh via register.py) and the heartbeat
`config` block (feeder/main.py, every 60 s) are the ONLY inputs this feeder
takes from the network, and both end up in privileged places: an `eval` in the
installer, systemd units, a WireGuard config and the .env file - all written as
root. Until ADSB-72 those values were used as-is, so a single quote or a newline
in e.g. `aggregator.beast_host` was arbitrary root execution on every feeder
(reported privately by Daniel, 2026-10-26).

Rule: every server-supplied value is checked against a fixed, narrow format
BEFORE it is used anywhere, and a response with ONE invalid field is rejected as
a whole. Nothing here is lenient on purpose: a legitimate registrar never emits
anything these patterns refuse (see adsb-api/ingestor/src/adsb_backend/
registrar.py: build_registration_response / build_heartbeat_response), so a
rejection means the server is misconfigured or compromised - and in both cases
the right move is to touch nothing.

The accepted character set of every string value is a subset of
    A-Z a-z 0-9 . _ : / @ + = , -
which is exactly what shlex.quote() leaves unquoted, what systemd ExecStart=
takes literally (no `%`, no `$`, no quotes, no backslash, no whitespace), and
what the installer's eval gate (installer.sh) and main._update_env_file accept.
Keep the four in step when extending this module.

Pure stdlib, importable both as `feeder.assignment` and as a sibling module
(`import assignment`) because register.py and main.py run as plain scripts.
"""
import ipaddress
import re

__all__ = [
    "InvalidAssignment",
    "SAFE_VALUE_RE",
    "validate_heartbeat_config",
    "validate_registration",
]


class InvalidAssignment(ValueError):
    """A server-supplied value does not have the format it must have."""


# The whole-value charset shared with installer.sh / main._update_env_file.
SAFE_VALUE_RE = re.compile(r"^[A-Za-z0-9._:/@+=,-]*$")

# RFC 1123 hostname: 1-253 chars, labels 1-63 of [A-Za-z0-9-] not starting or
# ending with '-'. An IPv4 literal matches too (numeric labels), which is what the
# legacy path sends as beast_host (the hub's overlay address).
_HOSTNAME_RE = re.compile(
    r"^(?=.{1,253}$)"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)
_HEX16_RE = re.compile(r"^[0-9a-f]{16}$")
_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
# shard names (ctr-01a), mlat_reason (position_required), ADSB-67 secret status.
_TOKEN_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
# WireGuard key: 32 bytes base64 = 44 chars ending in '='; the last char before
# '=' is restricted by the 2 padding bits.
_WG_KEY_RE = re.compile(r"^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$")
# claim_url: https, hostname, path from a safe charset, no query/fragment/userinfo.
_HTTPS_URL_RE = re.compile(r"^https://([A-Za-z0-9.-]{1,253})(/[A-Za-z0-9._~/-]*)?$")


def _str(value, field):
    """Reject anything that is not a plain str/int/bool, and any control char."""
    if isinstance(value, bool):
        value = "true" if value else "false"
    elif isinstance(value, int):
        value = str(value)
    if not isinstance(value, str):
        raise InvalidAssignment(f"{field}: expected a string, got {type(value).__name__}")
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in value):
        raise InvalidAssignment(f"{field}: control character in value")
    return value


def hostname(value, field):
    v = _str(value, field)
    if not _HOSTNAME_RE.match(v):
        raise InvalidAssignment(f"{field}: not a valid hostname ({v!r})")
    return v


def port(value, field):
    if isinstance(value, bool):
        raise InvalidAssignment(f"{field}: not a port number ({value!r})")
    if isinstance(value, str):
        if not re.fullmatch(r"[0-9]{1,5}", value):
            raise InvalidAssignment(f"{field}: not a port number ({value!r})")
        value = int(value)
    if not isinstance(value, int) or not 1 <= value <= 65535:
        raise InvalidAssignment(f"{field}: port out of range ({value!r})")
    return value


def hex16(value, field):
    v = _str(value, field).lower()
    if not _HEX16_RE.match(v):
        raise InvalidAssignment(f"{field}: expected 16 hex chars ({v!r})")
    return v


def uuid(value, field):
    v = _str(value, field).lower()
    if not _UUID_RE.match(v):
        raise InvalidAssignment(f"{field}: not a UUID ({v!r})")
    return v


def token(value, field):
    v = _str(value, field)
    if not _TOKEN_RE.match(v):
        raise InvalidAssignment(f"{field}: not a plain token ({v!r})")
    return v


def ipv4(value, field):
    v = _str(value, field)
    try:
        return str(ipaddress.IPv4Address(v))
    except ValueError:
        raise InvalidAssignment(f"{field}: not an IPv4 address ({v!r})") from None


def cidr_list(value, field):
    """One or more comma-separated IPv4 networks (10.7.0.1/32), as WireGuard
    takes them in Address= / AllowedIPs=. Re-emitted canonically."""
    v = _str(value, field)
    out = []
    for item in v.split(","):
        if "/" not in item:
            raise InvalidAssignment(f"{field}: missing prefix length ({item!r})")
        try:
            out.append(str(ipaddress.IPv4Network(item, strict=False)))
        except ValueError:
            raise InvalidAssignment(f"{field}: not an IPv4 network ({item!r})") from None
    return ",".join(out)


def wg_key(value, field):
    v = _str(value, field)
    if not _WG_KEY_RE.match(v):
        raise InvalidAssignment(f"{field}: not a WireGuard key")
    return v


def endpoint(value, field):
    """host:port - the WireGuard peer endpoint."""
    v = _str(value, field)
    host, sep, prt = v.rpartition(":")
    if not sep:
        raise InvalidAssignment(f"{field}: expected host:port ({v!r})")
    return f"{hostname(host, field)}:{port(prt, field)}"


def boolean(value, field):
    if isinstance(value, bool):
        return value
    if isinstance(value, str) and value.lower() in ("true", "false", "1", "0", "yes", "no"):
        return value.lower() in ("true", "1", "yes")
    raise InvalidAssignment(f"{field}: not a boolean ({value!r})")


def small_int(value, field, lo=0, hi=65535):
    if isinstance(value, bool):
        raise InvalidAssignment(f"{field}: not an integer ({value!r})")
    if isinstance(value, str):
        if not re.fullmatch(r"[0-9]{1,5}", value):
            raise InvalidAssignment(f"{field}: not an integer ({value!r})")
        value = int(value)
    if not isinstance(value, int) or not lo <= value <= hi:
        raise InvalidAssignment(f"{field}: integer out of range ({value!r})")
    return value


def https_url(value, field):
    v = _str(value, field)
    m = _HTTPS_URL_RE.match(v)
    if not m or len(v) > 512:
        raise InvalidAssignment(f"{field}: not an acceptable https URL")
    hostname(m.group(1), field)
    return v


def _optional(fn, value, field):
    """None / '' are accepted (the field is absent) and come back as ''."""
    if value is None or value == "":
        return ""
    return fn(value, field)


def _safe(out):
    """Last line of defence: every emitted string must be in the shared charset."""
    for k, v in out.items():
        if isinstance(v, str) and not SAFE_VALUE_RE.match(v):
            raise InvalidAssignment(f"{k}: value outside the safe character set")
    return out


def _wireguard(wg):
    """Validate a wireguard block; all five fields must be present together."""
    return {
        "WG_ADDRESS": cidr_list(wg.get("address"), "wireguard.address"),
        "WG_HUB_PUBKEY": wg_key(wg.get("hub_public_key"), "wireguard.hub_public_key"),
        "WG_HUB_ENDPOINT": endpoint(wg.get("hub_endpoint"), "wireguard.hub_endpoint"),
        "WG_ALLOWED_IPS": cidr_list(wg.get("allowed_ips"), "wireguard.allowed_ips"),
        "WG_KEEPALIVE": small_int(wg.get("persistent_keepalive", 25),
                                  "wireguard.persistent_keepalive", 0, 65535),
    }


def validate_registration(reg):
    """Validate a /receivers/register response and return the flat KEY -> value
    mapping register.py emits for installer.sh (strings, ints and bools only).

    Raises InvalidAssignment naming the first offending field."""
    if not isinstance(reg, dict):
        raise InvalidAssignment("response is not a JSON object")
    wg = reg.get("wireguard") or {}
    agg = reg.get("aggregator") or {}
    mlat = reg.get("mlat") or {}
    for name, block in (("wireguard", wg), ("aggregator", agg), ("mlat", mlat)):
        if not isinstance(block, dict):
            raise InvalidAssignment(f"{name}: expected an object")

    out = {
        "BEAST_ID": _optional(hex16, reg.get("beast_id"), "beast_id"),
        "SHARD": _optional(token, reg.get("shard"), "shard"),
        "TUNNEL_IP": _optional(ipv4, reg.get("tunnel_ip"), "tunnel_ip"),
        "ENABLED": "" if reg.get("enabled") in (None, "") else boolean(reg.get("enabled"), "enabled"),
        "WG_ADDRESS": "", "WG_HUB_PUBKEY": "", "WG_HUB_ENDPOINT": "",
        "WG_ALLOWED_IPS": "", "WG_KEEPALIVE": 25,
        "BEAST_HOST": _optional(hostname, agg.get("beast_host"), "aggregator.beast_host"),
        "BEAST_PORT": _optional(port, agg.get("beast_port"), "aggregator.beast_port"),
        "MLAT_ENABLED": boolean(reg.get("mlat_enabled", False), "mlat_enabled"),
        "MLAT_REASON": _optional(token, reg.get("mlat_reason"), "mlat_reason"),
        "MLAT_SERVER_HOST": _optional(hostname, mlat.get("server_host"), "mlat.server_host"),
        "MLAT_SERVER_PORT": _optional(port, mlat.get("server_port"), "mlat.server_port"),
        "CLAIM_URL": _optional(https_url, reg.get("claim_url"), "claim_url"),
        # ADSB-67: legacy | bound | ok | rebound | mismatch (informational).
        "SECRET_STATUS": _optional(token, reg.get("secret"), "secret"),
    }
    if wg:
        out.update(_wireguard(wg))
    # A usable assignment names the Beast endpoint (direct or via the hub).
    if not out["BEAST_HOST"] or not out["BEAST_PORT"]:
        raise InvalidAssignment("aggregator.beast_host/beast_port: missing")
    if out["MLAT_SERVER_HOST"] and not out["MLAT_SERVER_PORT"]:
        raise InvalidAssignment("mlat.server_port: missing")
    return _safe(out)


def validate_heartbeat_config(cfg, epoch):
    """Validate the heartbeat `config` block + `config_epoch` and return the
    normalised values main.maybe_apply_config may act on:
        {"epoch", "direct", "shard", "tunnel_ip", "beast_host", "beast_port",
         "wireguard": None | {address, hub_public_key, hub_endpoint,
                              allowed_ips, persistent_keepalive}}
    Raises InvalidAssignment naming the first offending field."""
    if not isinstance(cfg, dict):
        raise InvalidAssignment("config: expected an object")
    wg = cfg.get("wireguard") or {}
    agg = cfg.get("aggregator") or {}
    if not isinstance(wg, dict) or not isinstance(agg, dict):
        raise InvalidAssignment("config: wireguard/aggregator must be objects")
    out = {
        "epoch": hex16(epoch, "config_epoch"),
        "direct": not wg,
        "shard": _optional(token, cfg.get("shard"), "shard"),
        "tunnel_ip": _optional(ipv4, cfg.get("tunnel_ip"), "tunnel_ip"),
        "beast_host": hostname(agg.get("beast_host"), "aggregator.beast_host"),
        "beast_port": port(agg.get("beast_port"), "aggregator.beast_port"),
        "wireguard": None,
    }
    if wg:
        w = _wireguard(wg)
        out["wireguard"] = {
            "address": w["WG_ADDRESS"],
            "hub_public_key": w["WG_HUB_PUBKEY"],
            "hub_endpoint": w["WG_HUB_ENDPOINT"],
            "allowed_ips": w["WG_ALLOWED_IPS"],
            "persistent_keepalive": w["WG_KEEPALIVE"],
        }
        if not out["shard"] or not out["tunnel_ip"]:
            raise InvalidAssignment("legacy config without shard/tunnel_ip")
        _safe(out["wireguard"])
    return _safe(out)
