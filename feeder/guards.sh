# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.
#
# feeder/guards.sh - format checks for every value that is about to be written
# into a systemd unit, a WireGuard config or .env by one of the feeder scripts
# (ADSB-72). Sourced, not executed:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/guards.sh"
#   require_host HUB_HOST
#   require_port HUB_PORT
#
# Why: the scripts render files with unquoted heredocs and run as root. Their
# inputs come from the Dataero registrar (registration response, 60 s heartbeat)
# and from the operator. Until ADSB-72 a newline in beast_host added its own
# `ExecStartPre=` line to dataero-readsb.service - root execution on every
# feeder from whoever controls the server's answers (reported privately by
# Daniel, 2026-10-26). The Python side (feeder/assignment.py) validates first;
# these guards are the independent second check at the point of use, so a
# future caller that forgets to validate still cannot write a bad unit.
#
# Every guard names the variable, prints a sanitised copy of the offending value
# (control characters shown as '?') and exits 1 BEFORE anything is written. The
# accepted characters never include a newline, a quote, a backslash, whitespace,
# `$` or `%` - the characters systemd ExecStart=, systemd EnvironmentFile=,
# wg-quick and the shell give a meaning to.

# require_match NAME REGEX [WHAT]  - NAME's value must match the ERE entirely.
require_match() {
    local name="$1" re="$2" what="${3:-value}" val
    val="${!name-}"
    if ! [[ "$val" =~ ^(${re})$ ]]; then
        local shown="${val//[^[:print:]]/?}"
        echo "❌ $name is not a valid $what ('${shown:0:80}'); refusing to continue so nothing is written." >&2
        echo "   This value came from the Dataero server or the installer input; please report it to Dataero." >&2
        exit 1
    fi
}

# RFC 1123 hostname (labels 1-63 of [A-Za-z0-9-], no leading/trailing '-'); an
# IPv4 literal matches too. 253 chars max.
require_host() {
    local v="${!1-}"
    [ "${#v}" -le 253 ] || { echo "❌ $1 is too long for a hostname." >&2; exit 1; }
    require_match "$1" '[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*' hostname
}

# TCP/UDP port 1..65535.
require_port() {
    require_match "$1" '[0-9]{1,5}' 'port number'
    local v="${!1}"
    if [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then
        echo "❌ $1 is out of range for a port ($v)." >&2; exit 1
    fi
}

# host:port
require_hostport() {
    local v="${!1-}" h p
    require_match "$1" '[A-Za-z0-9.-]+:[0-9]{1,5}' 'host:port'
    h="${v%:*}"; p="${v##*:}"
    _gh="$h"; _gp="$p"
    require_host _gh
    require_port _gp
    unset _gh _gp
}

# Lower- or upper-case UUID with dashes.
require_uuid() {
    require_match "$1" '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' UUID
}

# IPv4 address.
require_ipv4() {
    require_match "$1" '((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])' 'IPv4 address'
}

# One or more comma-separated IPv4 networks (10.7.0.1/32), as WireGuard takes
# them in Address= / AllowedIPs=.
require_cidr_list() {
    local ip='((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])/(3[0-2]|[12]?[0-9])'
    require_match "$1" "${ip}(,${ip})*" 'IPv4 network list'
}

# WireGuard key: 32 bytes base64 = 44 chars ending in '='.
require_wg_key() {
    require_match "$1" '[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=' 'WireGuard key'
}

# Non-negative integer with at most N digits (default 5).
require_uint() {
    require_match "$1" "[0-9]{1,${2:-5}}" integer
}

# Non-negative decimal (12 or 0.25).
require_decimal() {
    require_match "$1" '[0-9]+([.][0-9]+)?' 'decimal number'
}

# Signed decimal (-4.35, 50.85) - latitude/longitude/altitude.
require_signed_decimal() {
    require_match "$1" '-?[0-9]+([.][0-9]+)?' 'decimal number'
}

# Absolute filesystem path from a plain charset (binaries, venvs, unit files).
require_abs_path() {
    require_match "$1" '/[A-Za-z0-9._/-]+' 'absolute path'
}

# A plain token: shard names, interface names, labels.
require_token() {
    require_match "$1" "[A-Za-z0-9_.-]{1,${2:-64}}" token
}

# label_for_systemd NAME [FALLBACK] - rewrite NAME's value in place so it can be
# put in double quotes inside ExecStart=: keeps letters, digits, space . _ -
# (everything else becomes '_'), collapses runs, trims, caps at 64 chars, and
# falls back to FALLBACK when nothing printable is left. Used for the MLAT
# --user label, which defaults to the station name the operator typed: a name
# with a space ("Daniel Home") used to be split by systemd into two arguments
# and mlat-client exited 2 in a 30 s restart loop (bug 3 of the ADSB-72 report).
label_for_systemd() {
    local name="$1" fallback="${2-}" v
    v="${!name-}"
    v="$(printf '%s' "$v" | LC_ALL=C tr -c 'A-Za-z0-9 ._-' '_')"
    v="$(printf '%s' "$v" | sed -E 's/_+/_/g; s/ +/ /g; s/^[ _]+//; s/[ _]+$//')"
    v="${v:0:64}"
    [ -n "$v" ] || v="$fallback"
    printf -v "$name" '%s' "$v"
}
