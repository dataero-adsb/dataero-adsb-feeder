#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.

set -e

INSTALL_DIR="/usr/local/dataero-adsb-feeder"
VENV_DIR="$INSTALL_DIR/.venv"
SERVICE_FILE="/etc/systemd/system/dataero-feeder.service"

echo "🚀 Starting Dataero ADS-B Feeder Installer..."
echo ""
echo "   ✈️  Before we begin: a tip of the hat to the readsb project"
echo "      (https://github.com/wiedehopf/readsb). They turn 1090 MHz radio"
echo "      noise into clean JSON. We just POST it. Massive respect."
echo ""

# Ensure apt-get is available (required to install any missing Python packages)
if ! command -v apt-get &> /dev/null; then
    echo "❌ apt-get not found. This installer supports Debian-based systems only (Raspberry Pi OS, Debian, Ubuntu)."
    echo "   Please install python3, python3-pip, and python3-venv manually, then rerun this script."
    exit 1
fi

# Phase 1: ensure python3 itself is present so we can inspect its version.
if ! command -v python3 &> /dev/null; then
    echo "⚠️  python3 not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y python3
    command -v python3 &> /dev/null || { echo "❌ python3 still unavailable after install."; exit 1; }
fi

# Detect the running Python version so we request the matching venv package
# (e.g. python3.11-venv on Bookworm, python3.12-venv on Trixie/Ubuntu 24.04).
# On current Debian/Ubuntu the meta-package python3-venv does NOT reliably
# pull in the versioned one, which is why `python3 -m venv` later fails with
# "ensurepip is not available" when only the meta-package is installed.
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
VENV_PKG="python${PY_VER}-venv"

# Floor at Python 3.7 — that's the oldest version for which our pinned deps
# (requests, python-dotenv) still publish wheels. Anything older is on a
# long-EOL OS (Stretch / Buster pre-3.7) and would only fail later inside
# pip with an opaque "no matching distribution" message; better to tell the
# operator clearly here.
PY_MAJOR="${PY_VER%.*}"
PY_MINOR="${PY_VER#*.}"
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 7 ]; }; then
    echo "❌ Python $PY_VER is too old. The Dataero feeder needs Python 3.7 or newer."
    echo "   Your OS release is almost certainly past end-of-life. Recommended fix:"
    echo "   reflash with a current image (e.g. PiAware 8 or current Raspberry Pi OS)"
    echo "   which ships Python 3.11+. Manually upgrading Python in place on an EOL"
    echo "   distribution rarely ends well."
    exit 1
fi

# Phase 2: check pip and the versioned venv package. dpkg -s is authoritative;
# `python3 -m venv --help` gives false positives because the stub is part of
# stdlib and succeeds even when ensurepip's wheels are missing.
MISSING_PKGS=()
python3 -m pip --version &> /dev/null || MISSING_PKGS+=("python3-pip")
dpkg -s "$VENV_PKG" &> /dev/null      || MISSING_PKGS+=("$VENV_PKG")

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "⚠️  Missing Python prerequisites: ${MISSING_PKGS[*]}"
    echo "📦 Installing via apt-get..."
    # Tolerate a partial `apt-get update` failure. A single broken or EOL
    # repository (e.g. FlightAware's retired Raspbian Buster mirror) returns
    # non-zero, but apt still refreshes the cache for the working repos. Under
    # `set -e` the bare command would abort the installer even though the
    # packages we need may be perfectly reachable from a healthy mirror.
    if ! sudo apt-get update; then
        echo "⚠️  apt-get update reported errors (likely a stale or end-of-life"
        echo "    repository in /etc/apt/sources.list.d/). Attempting the install"
        echo "    anyway — if our packages are still reachable, this will succeed."
    fi
    if ! sudo apt-get install -y "${MISSING_PKGS[@]}"; then
        echo "❌ Failed to install: ${MISSING_PKGS[*]}"
        echo "   This usually means your apt sources are unhealthy. Common causes:"
        echo "     • The OS release is end-of-life (e.g. Raspbian Buster) and its"
        echo "       repositories have been retired."
        echo "     • A third-party mirror in /etc/apt/sources.list.d/ no longer exists."
        echo "   Fix the apt sources (or upgrade the OS), then re-run this installer."
        exit 1
    fi
    python3 -m pip --version &> /dev/null || { echo "❌ pip still unavailable after install."; exit 1; }
    dpkg -s "$VENV_PKG" &> /dev/null      || { echo "❌ $VENV_PKG still not installed."; exit 1; }
    echo "✅ Python prerequisites installed."
else
    echo "✅ Python 3, pip, and $VENV_PKG are all available."
fi

# If a previous run left a half-built venv behind, remove it so `python3 -m venv`
# can re-bootstrap cleanly instead of tripping over stale files.
if [ -d "$VENV_DIR" ] && [ ! -x "$VENV_DIR/bin/pip" ]; then
    echo "🧹 Removing broken venv at $VENV_DIR from a previous run..."
    sudo rm -rf "$VENV_DIR"
fi

# Detect the ADS-B data source. The feeder is a passive read-only consumer
# of an aircraft.json — readsb and the various dump1090 forks all emit the
# same wiedehopf-format file, so any of them works. The detection has two
# stages:
#
#   1. Probe a known list of decoder systemd units in priority order.
#      `systemctl cat` (rather than `list-units --all`) only succeeds when a
#      real unit file exists on disk, avoiding false positives from orphan
#      unit references left behind by half-removed packages.
#
#   2. Safety net: if no known unit matched but something on the host is
#      already producing /run/<dir>/aircraft.json, consume that instead of
#      offering to install readsb. This is what keeps us from ever causing
#      an SDR collision on a host that already has an unfamiliar decoder
#      (e.g. dump1090-mutability on legacy Raspbian, or a hand-rolled build
#      with a non-standard unit name). Co-existing with FlightAware,
#      Flightradar24, ADSBExchange, etc. is fine — they're all just
#      additional readers of the same file.
#
# Only when both stages find nothing do we offer to install readsb.
DATA_SOURCE_UNIT=""
DATA_SOURCE_FILE=""

# Stage 1: known decoder units, in preference order. Path convention is
# /run/<unit-basename>/aircraft.json for every decoder we've seen in the wild.
KNOWN_DECODERS=(readsb dump1090-fa dump1090-mutability dump1090)
for d in "${KNOWN_DECODERS[@]}"; do
    if systemctl cat "${d}.service" &> /dev/null; then
        DATA_SOURCE_UNIT="${d}.service"
        DATA_SOURCE_FILE="/run/${d}/aircraft.json"
        echo "✅ Detected ${d}.service as the data source."
        break
    fi
done

# Stage 2: any /run/*/aircraft.json producer, even if its unit name is not
# one we recognise. We try to map the directory back to a systemd unit so
# we can still bind Requires=/After=; if the unit name doesn't match the
# directory we just skip the ordering and rely on Restart=always to recover
# if the feeder loses the file briefly.
if [ -z "$DATA_SOURCE_FILE" ]; then
    for f in /run/*/aircraft.json; do
        [ -e "$f" ] || continue
        candidate_dir=$(basename "$(dirname "$f")")
        DATA_SOURCE_FILE="$f"
        if systemctl cat "${candidate_dir}.service" &> /dev/null; then
            DATA_SOURCE_UNIT="${candidate_dir}.service"
            echo "✅ Detected an existing decoder at $f (unit: $DATA_SOURCE_UNIT)."
        else
            echo "✅ Detected an existing decoder at $f."
            echo "   ℹ️  No matching systemd unit named ${candidate_dir}.service —"
            echo "      skipping Requires=/After= ordering for the feeder service."
        fi
        break
    done
fi

# Stage 3: nothing found anywhere. Now it's safe to offer readsb because we
# know we won't be installing it on top of an existing SDR consumer.
if [ -z "$DATA_SOURCE_FILE" ]; then
    echo "❌ No ADS-B decoder service found, and no /run/*/aircraft.json on disk."
    read -p "Do you want to automatically install readsb? (yes/no): " install_readsb
    if [[ "$install_readsb" == "yes" ]]; then
        echo "🔄 Installing readsb..."
        bash "$(dirname "$0")/feeder/install_readsb.sh"

        if systemctl cat readsb.service &> /dev/null; then
            DATA_SOURCE_UNIT="readsb.service"
            DATA_SOURCE_FILE="/run/readsb/aircraft.json"
            echo "✅ readsb.service is now installed."
        else
            echo "❌ Failed to install readsb.service. Please install it manually."
            exit 1
        fi
    else
        echo "❌ A decoder (readsb, dump1090-fa, dump1090-mutability, or compatible)"
        echo "   is required for this feeder to function."
        exit 1
    fi
fi

# Ensure the chosen decoder is running — but only when we know its unit name.
# In the unknown-unit case the producer is already writing aircraft.json by
# the time we got here (Stage 2 confirmed the file exists), so there's
# nothing for us to start.
if [ -n "$DATA_SOURCE_UNIT" ]; then
    if ! systemctl is-active --quiet "$DATA_SOURCE_UNIT"; then
        echo "⚠️ $DATA_SOURCE_UNIT is not running. Attempting to start it..."
        sudo systemctl start "$DATA_SOURCE_UNIT"
        if systemctl is-active --quiet "$DATA_SOURCE_UNIT"; then
            echo "✅ $DATA_SOURCE_UNIT started successfully."
        else
            echo "❌ Failed to start $DATA_SOURCE_UNIT. Please start it manually."
            exit 1
        fi
    else
        echo "✅ $DATA_SOURCE_UNIT is already running."
    fi
fi

# ──────────────────────────────────────────────────────────────────────────
# Feed mode — Beast + WireGuard (readsb only).
#
# The feeder registers with the Dataero registrar (API key -> owner), brings up
# a WireGuard tunnel to its assigned hub (feeder/wg_setup.sh), and runs a
# DEDICATED net-only readsb instance (dataero-readsb.service) that taps the local
# decoder read-only and forwards a reduced Beast stream (with UUID) to that hub
# over the tunnel (feeder/configure_readsb_reduce.sh). main.py then only
# heartbeats the registrar.
#
# BUBBLE RULE: the installer does NOT modify or restart the shared decoder, so it
# can never disturb other feeders (FR24, FlightAware, Adsb-Italia, ...). readsb is
# required only as a Beast source on 127.0.0.1:30005 (its default output) — the
# same port every other feeder taps. The HTTPS/json fallback was removed. The API
# key (prompted below) is OPTIONAL: when given, registration binds the receiver
# UUID + WireGuard peer to the account immediately; when skipped, the receiver
# registers UNCLAIMED (feed-first, claim-later) and the registrar returns a
# claim URL shown at the end of the install. Thereafter the tunnel address +
# in-band UUID re-prove identity either way.
# ──────────────────────────────────────────────────────────────────────────
echo ""
if [ "$DATA_SOURCE_UNIT" != "readsb.service" ]; then
    echo "❌ This feeder requires readsb — it feeds Dataero via Beast + WireGuard,"
    echo "   which relies on readsb's native beast_reduce_plus_out connector."
    echo "   Detected decoder: ${DATA_SOURCE_UNIT:-${DATA_SOURCE_FILE:-none}}."
    echo "   Install readsb (https://github.com/wiedehopf/readsb) and re-run this installer."
    exit 1
fi
FEED_MODE="beast"
echo "📡 Beast + WireGuard mode — this device will register with Dataero, bring up a"
echo "   WireGuard tunnel to its assigned hub, and readsb will forward reduced Beast"
echo "   (with UUID) over that tunnel (configured right after the API key step)."

# Registrar base URL (HTTPS, behind HAProxy). Overridable for staging.
REGISTRAR_URL="${REGISTRAR_URL:-https://adsb.dataero.eu}"

# Create installation directory
if [ ! -d "$INSTALL_DIR" ]; then
    echo "📁 Creating installation directory at $INSTALL_DIR..."
    sudo mkdir -p "$INSTALL_DIR"
    echo "✅ Directory created."
else
    echo "📁 Installation directory already exists."
fi

# Copy Python files to the install directory
echo "📦 Copying Python files to $INSTALL_DIR..."
sudo cp -r feeder "$INSTALL_DIR/"
sudo cp requirements.txt "$INSTALL_DIR/"
echo "✅ Files copied."

# Set up virtual environment
echo "🐍 Setting up Python virtual environment..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install -r "$INSTALL_DIR/requirements.txt"
deactivate
echo "✅ Virtual environment ready."

# Determine API key. On a reinstall, an existing .env may already hold one —
# offer to keep it so the operator doesn't have to dig up the key again. The
# key is shown masked (first 4 + last 4) to avoid exposing the full secret in
# terminal scrollback.
EXISTING_KEY=""
if [ -f "$INSTALL_DIR/.env" ]; then
    EXISTING_KEY=$(sudo grep -E '^API_KEY=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    # Strip surrounding quotes if the file was hand-edited.
    EXISTING_KEY="${EXISTING_KEY%\"}"; EXISTING_KEY="${EXISTING_KEY#\"}"
    EXISTING_KEY="${EXISTING_KEY%\'}"; EXISTING_KEY="${EXISTING_KEY#\'}"
fi

# Reuse an existing receiver UUID + WireGuard private key across reinstalls so the
# account binding and the registered peer identity stay stable (read BEFORE .env
# is rewritten below). Regenerating the WG key would orphan the peer the hub knows.
EXISTING_UUID=""
EXISTING_WG_PRIVKEY=""
# MLAT opt-in + surveyed position are also reused across reinstalls (epic ADSB-17)
# so the operator doesn't re-enter the antenna survey every time.
EXISTING_MLAT_ENABLED=""
EXISTING_FEEDER_NAME=""
EXISTING_FEEDER_LAT=""
EXISTING_FEEDER_LON=""
EXISTING_FEEDER_ALT_M=""
if [ -f "$INSTALL_DIR/.env" ]; then
    EXISTING_UUID=$(sudo grep -E '^RECEIVER_UUID=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_WG_PRIVKEY=$(sudo grep -E '^WG_PRIVKEY=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_MLAT_ENABLED=$(sudo grep -E '^MLAT_ENABLED=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_FEEDER_NAME=$(sudo grep -E '^FEEDER_NAME=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_FEEDER_LAT=$(sudo grep -E '^FEEDER_LAT=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_FEEDER_LON=$(sudo grep -E '^FEEDER_LON=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_FEEDER_ALT_M=$(sudo grep -E '^FEEDER_ALT_M=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
fi

API_KEY=""
if [ -n "$EXISTING_KEY" ]; then
    KEY_LEN=${#EXISTING_KEY}
    if [ "$KEY_LEN" -gt 8 ]; then
        MASKED_KEY="${EXISTING_KEY:0:4}...${EXISTING_KEY: -4}"
    else
        MASKED_KEY="(short key)"
    fi
    echo "🔑 An existing API key was found in $INSTALL_DIR/.env: $MASKED_KEY ($KEY_LEN chars)"
    # Default to keeping the key on bare Enter. The previous behaviour treated
    # empty input as "no" and then prompted again for a fresh key — a second
    # Enter there silently wrote an empty API_KEY to .env and the feeder
    # failed auth on the very first POST. "(Y/n)" signals the default.
    read -p "🔑 Keep this key? (Y/n): " KEEP_KEY
    if [[ -z "$KEEP_KEY" || "$KEEP_KEY" =~ ^(y|yes|Y|YES)$ ]]; then
        API_KEY="$EXISTING_KEY"
        echo "✅ Reusing existing API key."
    fi
fi

if [ -z "$API_KEY" ]; then
    echo "🔑 An API key links this receiver to your Dataero account right away"
    echo "   (get one at https://radar.dataero.eu/profile)."
    echo "   Don't have one? Just press Enter — the receiver will feed anyway, and"
    echo "   a link to claim it for your account is shown at the end of the install."
    read -p "🔑 Enter your Dataero API key (or press Enter to skip): " API_KEY
    [ -z "$API_KEY" ] && echo "➡️  No key — registering this receiver as unclaimed (claim it later)."
fi

# Persist API key plus the detected readsb aircraft.json path. READSB_DATA is
# written explicitly rather than relying on main.py's default.
echo "API_KEY=$API_KEY"             | sudo tee    "$INSTALL_DIR/.env" > /dev/null
echo "READSB_DATA=$DATA_SOURCE_FILE" | sudo tee -a "$INSTALL_DIR/.env" > /dev/null
# FEED_MODE tells main.py what to do; the installer only ever sets "beast" =>
# heartbeat only, while readsb pushes reduced Beast over the WireGuard tunnel.
echo "FEED_MODE=$FEED_MODE"          | sudo tee -a "$INSTALL_DIR/.env" > /dev/null
echo "✅ Configuration saved (API key, data source: $DATA_SOURCE_FILE, feed mode: $FEED_MODE)."

# Beast + WireGuard mode: register with Dataero (api_key -> owner), bring up the
# WireGuard tunnel from the registration response, then point readsb at the
# assigned hub over that tunnel. The feed runs as a DEDICATED net-only readsb
# instance (dataero-readsb.service) that taps the local decoder read-only — it
# does NOT modify or restart the shared readsb, so other feeders are never
# disturbed (see feeder/configure_readsb_reduce.sh).
if [ "$FEED_MODE" = "beast" ]; then
    # WireGuard tooling (wg, wg-quick). On Debian 11+/Pi OS the kernel module is
    # built in; wireguard-tools provides the userspace.
    if ! command -v wg &>/dev/null || ! command -v wg-quick &>/dev/null; then
        echo "📦 Installing wireguard-tools..."
        sudo apt-get install -y wireguard-tools || {
            echo "❌ Failed to install wireguard-tools. Install it manually and re-run."
            exit 1
        }
    fi

    # Stable identity: reuse the receiver UUID + WG private key across reinstalls
    # so the peer the hub already knows isn't orphaned.
    RECEIVER_UUID="$EXISTING_UUID"
    if [ -z "$RECEIVER_UUID" ]; then
        if command -v uuidgen &>/dev/null; then
            RECEIVER_UUID=$(uuidgen)
        else
            RECEIVER_UUID=$(python3 -c 'import uuid; print(uuid.uuid4())')
        fi
    fi
    RECEIVER_UUID=$(echo "$RECEIVER_UUID" | tr 'A-Z' 'a-z')
    WG_PRIVKEY="$EXISTING_WG_PRIVKEY"
    if [ -z "$WG_PRIVKEY" ]; then
        WG_PRIVKEY=$(wg genkey)
    fi
    WG_PUBKEY=$(echo "$WG_PRIVKEY" | wg pubkey)
    REDUCE_INTERVAL="${REDUCE_INTERVAL:-0.25}"

    # Station name (optional; the hub also records the public source IP).
    echo ""
    read -p "📛 Station name (optional, press Enter to skip) [${EXISTING_FEEDER_NAME}]: " FEEDER_NAME
    FEEDER_NAME="${FEEDER_NAME:-$EXISTING_FEEDER_NAME}"

    # MLAT opt-in (epic ADSB-17). MLAT positions Mode-S aircraft that don't
    # broadcast GPS, by time-difference-of-arrival across receivers — so it needs
    # an ACCURATE, surveyed antenna position (error propagates directly into every
    # solution). If you opt in, lat/lon/alt become MANDATORY.
    echo ""
    echo "🛰️  MLAT (multilateration) lets Dataero position non-ADS-B Mode-S aircraft"
    echo "    using your receiver together with others nearby. It requires an accurate"
    echo "    surveyed antenna position (lat/lon/altitude)."
    _mlat_default="n"; [[ "${EXISTING_MLAT_ENABLED,,}" =~ ^(1|true|yes)$ ]] && _mlat_default="y"
    read -p "    Enable MLAT for this receiver? (y/N) [${_mlat_default}]: " _mlat_ans
    _mlat_ans="${_mlat_ans:-$_mlat_default}"
    if [[ "$_mlat_ans" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        MLAT_ENABLED="true"
    else
        MLAT_ENABLED="false"
    fi

    if [ "$MLAT_ENABLED" = "true" ]; then
        echo ""
        echo "📍 MLAT needs your SURVEYED antenna position. Be precise — a position error"
        echo "   of a few metres degrades every multilateration result. Use a GPS reading"
        echo "   at the antenna, or a map tool; altitude is height above sea level in metres."
        # Mandatory, with a tiny validation loop. Pre-fill from any existing value.
        _read_required_num() {  # $1=prompt  $2=existing -> echoes value
            local _p="$1" _ex="$2" _v=""
            while :; do
                read -p "   $_p [${_ex}]: " _v
                _v="${_v:-$_ex}"
                if [[ "$_v" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then echo "$_v"; return; fi
                echo "   ↳ please enter a decimal number." >&2
            done
        }
        FEEDER_LAT=$(_read_required_num "Latitude (decimal, e.g. 50.85)" "$EXISTING_FEEDER_LAT")
        FEEDER_LON=$(_read_required_num "Longitude (decimal, e.g. 4.35)" "$EXISTING_FEEDER_LON")
        FEEDER_ALT_M=$(_read_required_num "Antenna altitude (metres)" "$EXISTING_FEEDER_ALT_M")
    else
        # Position stays optional when MLAT is off (the hub still finds it useful).
        echo ""
        echo "📍 Optional station position (press Enter to skip each):"
        read -p "   Latitude (decimal, e.g. 50.85)  [${EXISTING_FEEDER_LAT}]: " FEEDER_LAT
        FEEDER_LAT="${FEEDER_LAT:-$EXISTING_FEEDER_LAT}"
        read -p "   Longitude (decimal, e.g. 4.35)  [${EXISTING_FEEDER_LON}]: " FEEDER_LON
        FEEDER_LON="${FEEDER_LON:-$EXISTING_FEEDER_LON}"
        read -p "   Antenna altitude (metres)       [${EXISTING_FEEDER_ALT_M}]: " FEEDER_ALT_M
        FEEDER_ALT_M="${FEEDER_ALT_M:-$EXISTING_FEEDER_ALT_M}"
    fi

    # Remember what the operator asked for: `eval "$REG_VARS"` below overwrites
    # MLAT_ENABLED with the server's effective value (honoured only with a position).
    MLAT_ENABLED_REQ="$MLAT_ENABLED"

    echo "🛰️  Registering this feeder with Dataero ($REGISTRAR_URL)..."
    # register.py reads its inputs from the environment and prints the assigned
    # WireGuard + hub config as shell KEY=VALUE lines (or exits non-zero with a
    # clear message). It retries while no ingest shard is available yet.
    REG_VARS=$(REGISTRAR_URL="$REGISTRAR_URL" API_KEY="$API_KEY" \
        RECEIVER_UUID="$RECEIVER_UUID" WG_PUBKEY="$WG_PUBKEY" \
        FEEDER_NAME="$FEEDER_NAME" FEEDER_LAT="$FEEDER_LAT" \
        FEEDER_LON="$FEEDER_LON" FEEDER_ALT_M="$FEEDER_ALT_M" \
        MLAT_ENABLED="$MLAT_ENABLED" \
        "$VENV_DIR/bin/python" "$INSTALL_DIR/feeder/register.py") || {
            echo "❌ Registration failed (see the message above). Fix the cause and re-run."
            exit 1
        }
    # Sets BEAST_ID SHARD TUNNEL_IP ENABLED WG_ADDRESS WG_HUB_PUBKEY
    # WG_HUB_ENDPOINT WG_ALLOWED_IPS WG_KEEPALIVE BEAST_HOST BEAST_PORT,
    # MLAT_ENABLED MLAT_REASON MLAT_SERVER_HOST MLAT_SERVER_PORT (epic ADSB-17),
    # and CLAIM_URL (set only when registering without an API key — the link the
    # operator opens to claim this receiver for their account).
    eval "$REG_VARS"
    if [ -z "$WG_ADDRESS" ] || [ -z "$WG_HUB_PUBKEY" ] || [ -z "$WG_HUB_ENDPOINT" ] \
       || [ -z "$WG_ALLOWED_IPS" ] || [ -z "$BEAST_HOST" ] || [ -z "$BEAST_PORT" ]; then
        echo "❌ Registration response was incomplete (missing tunnel/hub fields):"
        echo "$REG_VARS" | sed 's/^/     /'
        echo "   This is a server-side configuration issue — please report it. Aborting."
        exit 1
    fi
    echo "✅ Registered: receiver $RECEIVER_UUID -> shard $SHARD, tunnel $TUNNEL_IP."

    # Effective MLAT state from the server (register.py emits the bool as
    # True/False); normalise to lowercase for .env + reinstall reuse.
    MLAT_EFFECTIVE="false"; [[ "${MLAT_ENABLED,,}" =~ ^(1|true|yes)$ ]] && MLAT_EFFECTIVE="true"

    # Persist identity + hub config. .env holds secrets (API key, WG private key),
    # so lock it down.
    {
        echo "REGISTRAR_URL=$REGISTRAR_URL"
        echo "RECEIVER_UUID=$RECEIVER_UUID"
        echo "WG_PRIVKEY=$WG_PRIVKEY"
        echo "WG_PUBKEY=$WG_PUBKEY"
        echo "FEEDER_NAME=$FEEDER_NAME"
        echo "FEEDER_LAT=$FEEDER_LAT"
        echo "FEEDER_LON=$FEEDER_LON"
        echo "FEEDER_ALT_M=$FEEDER_ALT_M"
        echo "REDUCE_INTERVAL=$REDUCE_INTERVAL"
        echo "SHARD=$SHARD"
        echo "TUNNEL_IP=$TUNNEL_IP"
        echo "BEAST_HOST=$BEAST_HOST"
        echo "BEAST_PORT=$BEAST_PORT"
        # MLAT (epic ADSB-17): effective opt-in + the central mlat-server endpoint.
        echo "MLAT_ENABLED=$MLAT_EFFECTIVE"
        echo "MLAT_SERVER_HOST=$MLAT_SERVER_HOST"
        echo "MLAT_SERVER_PORT=$MLAT_SERVER_PORT"
        # Informational: non-empty only while the receiver is unclaimed (no API
        # key at registration) — kept so the operator can find the link again.
        echo "CLAIM_URL=$CLAIM_URL"
    } | sudo tee -a "$INSTALL_DIR/.env" > /dev/null
    sudo chmod 600 "$INSTALL_DIR/.env"

    echo "🔐 Bringing up the WireGuard tunnel to the hub..."
    WG_PRIVKEY="$WG_PRIVKEY" WG_ADDRESS="$WG_ADDRESS" WG_HUB_PUBKEY="$WG_HUB_PUBKEY" \
        WG_HUB_ENDPOINT="$WG_HUB_ENDPOINT" WG_ALLOWED_IPS="$WG_ALLOWED_IPS" \
        WG_KEEPALIVE="$WG_KEEPALIVE" \
        bash "$INSTALL_DIR/feeder/wg_setup.sh"

    echo "🔧 Setting up the Dataero feed (dedicated net-only readsb instance; the shared decoder is NOT modified) -> $BEAST_HOST:$BEAST_PORT ..."
    UUID="$RECEIVER_UUID" HUB_HOST="$BEAST_HOST" HUB_PORT="$BEAST_PORT" REDUCE_INTERVAL="$REDUCE_INTERVAL" \
        LOCAL_BEAST_PORT="${LOCAL_BEAST_PORT:-30005}" \
        bash "$(dirname "$0")/feeder/configure_readsb_reduce.sh"

    # MLAT (epic ADSB-17): if the operator opted in AND the server accepted it
    # (honoured only with a full position) AND returned a server endpoint, install
    # + start mlat-client. It reads the LOCAL full Beast (127.0.0.1:30005 — not the
    # reduced hub stream) and dials the central mlat-server, running alongside the
    # reduce connector (two independent consumers of the same readsb).
    if [ "$MLAT_EFFECTIVE" = "true" ] && [ -n "$MLAT_SERVER_HOST" ]; then
        echo "🛰️  Setting up MLAT (mlat-client -> $MLAT_SERVER_HOST:$MLAT_SERVER_PORT) ..."
        MLAT_VENV="$INSTALL_DIR/.venv-mlat" \
            bash "$(dirname "$0")/feeder/install_mlat_client.sh"
        MLAT_VENV="$INSTALL_DIR/.venv-mlat" RECEIVER_UUID="$RECEIVER_UUID" \
            MLAT_SERVER_HOST="$MLAT_SERVER_HOST" MLAT_SERVER_PORT="$MLAT_SERVER_PORT" \
            FEEDER_LAT="$FEEDER_LAT" FEEDER_LON="$FEEDER_LON" FEEDER_ALT_M="$FEEDER_ALT_M" \
            MLAT_USER="${FEEDER_NAME:-$RECEIVER_UUID}" \
            bash "$(dirname "$0")/feeder/configure_mlat_client.sh"
    elif [ "$MLAT_ENABLED_REQ" = "true" ]; then
        # Opted in but not started: either the server declined (no position) or
        # MLAT isn't deployed/reachable yet (no endpoint). Explain, keep feeding.
        if [ "$MLAT_EFFECTIVE" != "true" ]; then
            echo "⚠️  MLAT requested but not enabled by the server${MLAT_REASON:+ ($MLAT_REASON)}."
            echo "    Re-run with an accurate lat/lon/alt to enable it. ADS-B feeding continues."
        else
            echo "⚠️  MLAT enabled, but no mlat-server endpoint is available yet (MLAT not"
            echo "    deployed/reachable for your assignment). mlat-client not started; ADS-B"
            echo "    feeding continues. Re-run the installer later to pick up MLAT."
        fi
    fi
fi

# Create systemd service file. Requires=/After= are only emitted when we
# matched a known systemd unit; in the unknown-unit safety-net case we omit
# them and rely on Restart=always plus main.py's tolerance of a missing
# aircraft.json so the feeder catches up once its decoder is producing.
UNIT_DEPS=""
if [ -n "$DATA_SOURCE_UNIT" ]; then
    UNIT_DEPS="Requires=$DATA_SOURCE_UNIT
After=$DATA_SOURCE_UNIT"
fi

echo "🛠️ Creating systemd service..."
sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Dataero ADS-B Feeder Service
$UNIT_DEPS

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/feeder/main.py
EnvironmentFile=$INSTALL_DIR/.env
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable service
echo "🔄 Reloading systemd daemon..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable dataero-feeder.service
# Use `restart` rather than `start` so re-installs actually bounce the running
# service and pick up the newly-copied feeder/ files. `restart` is equivalent
# to `start` when the unit is inactive, so this also covers a fresh install.
sudo systemctl restart dataero-feeder.service

echo "✅ Service installed and (re)started."

# ──────────────────────────────────────────────────────────────────────────
# Post-install verification
# ──────────────────────────────────────────────────────────────────────────
echo ""
echo "🔍 Running post-install checks..."

# Give the service a moment to attempt its first POST before we inspect it.
sleep 3

# 1. The systemd unit must be active (not crashed during startup).
if ! systemctl is-active --quiet dataero-feeder.service; then
    echo "❌ dataero-feeder.service is not running. View logs with:"
    echo "     sudo journalctl -u dataero-feeder.service -n 50"
    exit 1
fi
echo "✅ Service is active."

# 2. Live API test (beast mode): POST a registrar heartbeat keyed on the
#    receiver_id. Aircraft data does NOT flow through this POST (readsb forwards
#    reduced Beast over the WireGuard tunnel), so the meaningful client-side check
#    is that the heartbeat is accepted (proving the receiver is registered +
#    enabled). The WireGuard handshake is checked separately below.
#    curl exits non-zero only on transport failures; 4xx/5xx come back as the
#    HTTP status code, inspected explicitly below.
if ! command -v curl &> /dev/null; then
    echo "📦 Installing curl for the API test..."
    sudo apt-get install -y curl
fi

RUN_API_TEST="yes"
CURL_DATA=()
if [ "$FEED_MODE" = "beast" ]; then
    # WireGuard handshake check: a fresh tunnel should complete a handshake within
    # a few seconds of coming up. No handshake => endpoint/key/firewall problem.
    echo "🔐 Checking the WireGuard handshake to the hub..."
    WG_HS=$(sudo wg show wg-adsb latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    if [ -n "$WG_HS" ] && [ "$WG_HS" != "0" ]; then
        echo "✅ WireGuard handshake established with the hub."
    else
        echo "⚠️  No WireGuard handshake yet. The tunnel may still be settling; check with:"
        echo "     sudo wg show wg-adsb"
    fi
    TEST_URL="$REGISTRAR_URL/receivers/heartbeat"
    TEST_LABEL="registrar heartbeat (aircraft data flows via Beast over WireGuard, not this POST)"
    CURL_DATA=(--data "{\"receiver_id\": \"$RECEIVER_UUID\"}")
    # The registrar heartbeat is keyed on receiver_id; no bearer token.
fi

if [ "$RUN_API_TEST" = "yes" ]; then
    echo "📡 Sending a test $TEST_LABEL to $TEST_URL ..."
    RESP_BODY=$(mktemp)
    HTTP_CODE=$(curl -sS -o "$RESP_BODY" -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        "${CURL_DATA[@]}" \
        "$TEST_URL" || echo "000")
    case "$HTTP_CODE" in
        2*)
            echo "✅ Registrar accepted the heartbeat (HTTP $HTTP_CODE). This receiver is registered + enabled; dataero-readsb.service is forwarding reduced Beast over the tunnel."
            echo "   ℹ️  Confirm the stream is attributed on the Dataero server side (feeder list / message counter)."
            ;;
        401|403)
            echo "❌ API rejected your credentials (HTTP $HTTP_CODE)."
            echo "   Check your API key on https://radar.dataero.eu/profile and edit $INSTALL_DIR/.env"
            echo "   Response body:"
            sed 's/^/     /' "$RESP_BODY"
            rm -f "$RESP_BODY"
            exit 1
            ;;
        404)
            echo "⚠️  Registrar does not recognise this receiver (HTTP 404) — it may have"
            echo "   been disabled/removed server-side. Re-run this installer to re-register."
            ;;
        000)
            echo "❌ Could not reach ${TEST_URL%%/receivers*}. Check this device's internet connection."
            rm -f "$RESP_BODY"
            exit 1
            ;;
        *)
            echo "⚠️  Unexpected API response (HTTP $HTTP_CODE). Response body:"
            sed 's/^/     /' "$RESP_BODY"
            echo "   The service is running; monitor logs to confirm it continues:"
            echo "     sudo journalctl -u dataero-feeder.service -f"
            ;;
    esac
    rm -f "$RESP_BODY"
fi

# 3. Final sanity check: service still running after the test window.
if ! systemctl is-active --quiet dataero-feeder.service; then
    echo "❌ Service crashed during startup. View logs with:"
    echo "     sudo journalctl -u dataero-feeder.service -n 50"
    exit 1
fi

echo ""
echo "🎉 Installation complete. dataero-readsb.service forwards reduced Beast (uuid $RECEIVER_UUID) over the WireGuard tunnel to hub $BEAST_HOST:$BEAST_PORT (shard $SHARD) — the shared decoder is untouched; the feeder heartbeats $REGISTRAR_URL."
echo ""

# Feed-first, claim-later: registered without an API key => the receiver is
# feeding but not yet linked to an account. Show the claim link prominently —
# this is the operator's one pointer to it (also kept in .env as CLAIM_URL).
if [ -z "$API_KEY" ]; then
    echo "📌 This receiver is feeding, but it is NOT YET LINKED to a Dataero account."
    echo "   Claim it to see your stats and manage it:"
    echo ""
    if [ -n "$CLAIM_URL" ]; then
        echo "       👉 $CLAIM_URL"
        echo ""
        echo "   Open that link in a browser while signed in at radar.dataero.eu."
    else
        echo "       👉 Sign in at https://radar.dataero.eu and claim receiver:"
        echo "          $RECEIVER_UUID"
    fi
    echo ""
    echo "   (Alternatively, re-run this installer later and enter an API key.)"
    echo ""
fi
echo "   ✈️  Reminder: the bytes you're now relaying were lovingly decoded by"
echo "      readsb (https://github.com/wiedehopf/readsb). If you ever bump"
echo "      into wiedehopf or a readsb maintainer in the wild, buy them a"
echo "      coffee. We owe them the entire upper half of this stack."
echo ""
