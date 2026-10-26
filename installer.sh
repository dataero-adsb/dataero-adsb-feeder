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

# ──────────────────────────────────────────────────────────────────────────
# Decoder detection - COEXISTENCE RULE (ADSB-71)
#
# Dataero is added NEXT TO whatever already feeds from this receiver
# (Flightradar24 fr24feed / Pi24 image, PiAware, readsb, ultrafeeder, ...).
# The installer:
#   * never starts, stops, restarts, enables, disables or edits a unit or a
#     config file that is not dataero-*;
#   * never installs a decoder when any decoder or feeder is already present,
#     so the radio dongle is never taken away from fr24feed or dump1090;
#   * reads the existing decoder's TCP output as ONE MORE READER, exactly like
#     every other feeder does. The format (Beast or AVR raw) is decided from the
#     bytes actually received (feeder/detect_local_feed.py), never assumed.
# Only when NOTHING is present (fresh Pi) does it offer to install readsb.
# ──────────────────────────────────────────────────────────────────────────
DATA_SOURCE_UNIT=""
DATA_SOURCE_FILE=""

# Stage 1: known decoder units, in preference order. Path convention is
# /run/<unit-basename>/aircraft.json for every decoder we've seen in the wild.
KNOWN_DECODERS=(readsb dump1090-fa dump1090-mutability dump1090)
for d in "${KNOWN_DECODERS[@]}"; do
    if systemctl cat "${d}.service" &> /dev/null; then
        DATA_SOURCE_UNIT="${d}.service"
        DATA_SOURCE_FILE="/run/${d}/aircraft.json"
        echo "✅ Detected ${d}.service on this receiver."
        break
    fi
done

# Stage 2: any /run/*/aircraft.json producer, even if its unit name is not one
# we recognise (e.g. dump1090-mutability started by fr24feed itself).
if [ -z "$DATA_SOURCE_FILE" ]; then
    for f in /run/*/aircraft.json; do
        [ -e "$f" ] || continue
        candidate_dir=$(basename "$(dirname "$f")")
        DATA_SOURCE_FILE="$f"
        if systemctl cat "${candidate_dir}.service" &> /dev/null; then
            DATA_SOURCE_UNIT="${candidate_dir}.service"
        fi
        echo "✅ Detected an existing decoder at $f."
        break
    done
fi

# Stage 3: every other feeder / decoder unit or process that may own the dongle.
# These are only LOOKED AT (systemctl cat / show, pgrep) - never acted upon.
FOREIGN_CANDIDATES=(readsb dump1090-fa dump1090-mutability dump1090 fr24feed piaware
    adsbexchange-feed adsbexchange-mlat rbfeeder pfclient opensky-feeder
    mlat-client dump978-fa skyaware978 tar1090 rtl_tcp)
FOREIGN_UNITS=()
for u in "${FOREIGN_CANDIDATES[@]}"; do
    systemctl cat "${u}.service" &> /dev/null && FOREIGN_UNITS+=("${u}.service")
done
OUR_FWD_PID=$(systemctl show -p MainPID --value dataero-readsb.service 2>/dev/null || echo 0)
SDR_PROCS=$(pgrep -a -f '(^|/)(fr24feed|dump1090[^ ]*|readsb|rtl_tcp|rtl_adsb|dump978[^ ]*)( |$)' 2>/dev/null \
    | awk -v ours="${OUR_FWD_PID:-0}" -v me="$$" '$1 != ours && $1 != me' \
    | grep -v -e 'dataero-adsb-feeder' -e 'pgrep' || true)

# Before-snapshot of every foreign unit: proves at the end that nothing of
# theirs was restarted by this installer.
_snapshot_foreign() {
    local u
    for u in "${FOREIGN_UNITS[@]}"; do
        echo "$u $(systemctl show -p ActiveState --value "$u" 2>/dev/null) pid=$(systemctl show -p MainPID --value "$u" 2>/dev/null)"
    done
}
FOREIGN_BEFORE="$(_snapshot_foreign)"

echo "🔎 Looking for your decoder's output on 127.0.0.1 (read-only, a few seconds)..."
LOCAL_FEED=$(python3 "$(dirname "$0")/feeder/detect_local_feed.py")

DECODER_PRESENT="no"
if [ -n "$DATA_SOURCE_FILE" ] || [ ${#FOREIGN_UNITS[@]} -gt 0 ] || [ -n "$SDR_PROCS" ] || [ "$LOCAL_FEED" != "none" ]; then
    DECODER_PRESENT="yes"
fi

if [ "$DECODER_PRESENT" = "yes" ]; then
    echo "🤝 Existing ADS-B setup found - Dataero will be added in parallel, nothing of yours is changed:"
    [ ${#FOREIGN_UNITS[@]} -gt 0 ] && echo "     services: ${FOREIGN_UNITS[*]}"
    [ -n "$SDR_PROCS" ] && echo "$SDR_PROCS" | awk '{print "     process:  " $2}' | sort -u
    [ -n "$DATA_SOURCE_FILE" ] && echo "     data:     $DATA_SOURCE_FILE"
    if [ -n "$DATA_SOURCE_UNIT" ] && ! systemctl is-active --quiet "$DATA_SOURCE_UNIT"; then
        echo "⚠️  $DATA_SOURCE_UNIT is not running. The installer does not start it - that is your"
        echo "   decoder. Dataero picks up its output as soon as it runs."
    fi
else
    echo "ℹ️  No ADS-B decoder or feeder found on this device (no service, no process, nothing"
    echo "   on 127.0.0.1:30005 or :30002)."
    read -p "Do you want to install the readsb decoder now? (yes/no): " install_readsb
    if [[ "$install_readsb" == "yes" ]]; then
        echo "🔄 Installing readsb..."
        bash "$(dirname "$0")/feeder/install_readsb.sh"
        if ! systemctl cat readsb.service &> /dev/null; then
            echo "❌ Failed to install readsb.service. Please install it manually."
            exit 1
        fi
        DATA_SOURCE_UNIT="readsb.service"
        DATA_SOURCE_FILE="/run/readsb/aircraft.json"
        echo "✅ readsb.service is now installed."
        LOCAL_FEED=$(python3 "$(dirname "$0")/feeder/detect_local_feed.py")
        [ "$LOCAL_FEED" = "none" ] && LOCAL_FEED="silent-beast 30005"
    else
        echo "❌ A decoder (readsb, dump1090, fr24feed, ...) is required for this feeder to function."
        exit 1
    fi
fi

# What the Dataero forwarder will read.
SRC_KIND="${LOCAL_FEED%% *}"
SRC_PORT="${LOCAL_FEED##* }"
case "$SRC_KIND" in
    beast|silent-beast) SRC_FORMAT="beast" ;;
    raw|silent-raw)     SRC_FORMAT="raw" ;;
    *)
        echo ""
        echo "❌ Your decoder does not offer an output Dataero can read: nothing answers on"
        echo "   127.0.0.1:30005 (Beast) or 127.0.0.1:30002 (raw)."
        echo "   Your decoder and your other feeds were not changed and keep running as before."
        echo "   On a Flightradar24 receiver, turn on its raw data output (port 30002) in the"
        echo "   fr24feed settings, or the Beast output (port 30005) of its decoder, then re-run"
        echo "   this installer. Need help? https://radar.dataero.eu/contribute/connect"
        exit 1
        ;;
esac
case "$SRC_KIND" in
    silent-*)
        echo "⚠️  127.0.0.1:$SRC_PORT is open but sent no aircraft in the last seconds (none in range?)."
        echo "   Continuing: Dataero forwards them as soon as your decoder hears some." ;;
    *)  echo "✅ Reading your decoder's ${SRC_FORMAT} output on 127.0.0.1:$SRC_PORT (one more reader, like every feeder)." ;;
esac
if [ "$SRC_FORMAT" = "raw" ]; then
    echo "   ℹ️  Raw output carries no precise timing: MLAT is not available with this source."
fi

# The forwarder binary: the host's own readsb when it has one, else a net-only
# readsb built for Dataero (no SDR driver - it cannot touch the dongle).
READSB_BIN="$(command -v readsb || true)"
if [ -z "$READSB_BIN" ]; then
    for c in /usr/bin/readsb /usr/local/bin/readsb; do
        [ -x "$c" ] && READSB_BIN="$c" && break
    done
fi
if [ -z "$READSB_BIN" ]; then
    echo "🔧 No readsb binary on this device: building the Dataero forwarder (net-only, no SDR driver)..."
    DEST="$INSTALL_DIR/bin/readsb" bash "$(dirname "$0")/feeder/build_readsb_netonly.sh"
    READSB_BIN="$INSTALL_DIR/bin/readsb"
fi

FEED_MODE="beast"
echo "📡 Direct Beast mode - this device will register with Dataero, and a dedicated"
echo "   net-only forwarder will send a reduced Beast stream (with UUID) to its"
echo "   assigned ingest hub over plain TCP (configured next)."

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

# Reuse an existing receiver UUID across reinstalls so the account binding and
# the registered receiver identity stay stable (read BEFORE .env is rewritten
# below). Regenerating the UUID would orphan the receiver the hub knows.
EXISTING_UUID=""
# MLAT opt-in + surveyed position are also reused across reinstalls (epic ADSB-17)
# so the operator doesn't re-enter the antenna survey every time.
EXISTING_MLAT_ENABLED=""
EXISTING_FEEDER_NAME=""
EXISTING_FEEDER_LAT=""
EXISTING_FEEDER_LON=""
EXISTING_FEEDER_ALT_M=""
if [ -f "$INSTALL_DIR/.env" ]; then
    EXISTING_UUID=$(sudo grep -E '^RECEIVER_UUID=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_MLAT_ENABLED=$(sudo grep -E '^MLAT_ENABLED=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_FEEDER_NAME=$(sudo grep -E '^FEEDER_NAME=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_FEEDER_LAT=$(sudo grep -E '^FEEDER_LAT=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_FEEDER_LON=$(sudo grep -E '^FEEDER_LON=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    EXISTING_FEEDER_ALT_M=$(sudo grep -E '^FEEDER_ALT_M=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
fi

# Persist the detected readsb aircraft.json path. READSB_DATA is written
# explicitly rather than relying on main.py's default; this is the file-creating
# (truncating) write.
echo "READSB_DATA=$DATA_SOURCE_FILE" | sudo tee    "$INSTALL_DIR/.env" > /dev/null
# FEED_MODE tells main.py what to do; the installer only ever sets "beast" =>
# heartbeat only, while readsb pushes reduced Beast directly to the hub.
echo "FEED_MODE=$FEED_MODE"          | sudo tee -a "$INSTALL_DIR/.env" > /dev/null
echo "✅ Configuration saved (data source: $DATA_SOURCE_FILE, feed mode: $FEED_MODE)."

# Direct Beast mode (ADSB-34, ADSBexchange model): register with Dataero,
# then point readsb straight at the PUBLIC hub endpoint over
# plain TCP. The feed runs as a DEDICATED net-only readsb
# instance (dataero-readsb.service) that taps the local decoder read-only — it
# does NOT modify or restart the shared readsb, so other feeders are never
# disturbed (see feeder/configure_readsb_reduce.sh). Identity is the in-band
# beast_id (readsb --uuid); the daemon (main.py) stays able to apply a legacy
# tunnel assignment too if the server ever sends one (dual-mode).
if [ "$FEED_MODE" = "beast" ]; then
    # Migrating a feeder off the retired WireGuard path: tear down the leftover
    # tunnel so it stops dialing the overlay (BUBBLE RULE — only OUR interface,
    # never another feeder's tunnel).
    if [ -f /etc/wireguard/wg-adsb.conf ]; then
        echo "🧹 Removing the legacy Dataero WireGuard tunnel (moving to direct Beast)..."
        sudo wg-quick down wg-adsb 2>/dev/null || true
        sudo rm -f /etc/wireguard/wg-adsb.conf
    fi

    # Stable identity: reuse the receiver UUID across reinstalls so the receiver
    # the hub already knows (by its in-band beast_id) isn't orphaned.
    RECEIVER_UUID="$EXISTING_UUID"
    if [ -z "$RECEIVER_UUID" ]; then
        if command -v uuidgen &>/dev/null; then
            RECEIVER_UUID=$(uuidgen)
        else
            RECEIVER_UUID=$(python3 -c 'import uuid; print(uuid.uuid4())')
        fi
    fi
    RECEIVER_UUID=$(echo "$RECEIVER_UUID" | tr 'A-Z' 'a-z')
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
    if [ "$SRC_FORMAT" = "beast" ]; then
        read -p "    Enable MLAT for this receiver? (y/N) [${_mlat_default}]: " _mlat_ans
        _mlat_ans="${_mlat_ans:-$_mlat_default}"
    else
        # ADSB-71: a raw (AVR) source has no 12 MHz timestamps - MLAT cannot work.
        echo "    Not available here: your decoder offers raw output only (no precise timing)."
        _mlat_ans="n"
    fi
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
    # config as shell KEY=VALUE lines (or exits non-zero with a clear message).
    # No WG_PUBKEY is passed, so register.py omits wg_pubkey and the registrar
    # returns a DIRECT (tunnel-less) assignment with the public Beast endpoint.
    REG_VARS=$(REGISTRAR_URL="$REGISTRAR_URL" \
        RECEIVER_UUID="$RECEIVER_UUID" \
        FEEDER_NAME="$FEEDER_NAME" FEEDER_LAT="$FEEDER_LAT" \
        FEEDER_LON="$FEEDER_LON" FEEDER_ALT_M="$FEEDER_ALT_M" \
        MLAT_ENABLED="$MLAT_ENABLED" \
        "$VENV_DIR/bin/python" "$INSTALL_DIR/feeder/register.py") || {
            echo "❌ Registration failed (see the message above). Fix the cause and re-run."
            exit 1
        }
    # Sets BEAST_ID SHARD TUNNEL_IP ENABLED BEAST_HOST BEAST_PORT, MLAT_ENABLED
    # MLAT_REASON MLAT_SERVER_HOST MLAT_SERVER_PORT (epic ADSB-17), and CLAIM_URL
    # (the link to bind this unclaimed receiver to an account). In direct mode
    # SHARD/TUNNEL_IP are empty.
    # ADSB-72: three gates stand between the registrar and this root shell.
    # register.py (1) validates every field of the response against a fixed
    # format and (2) shlex-quotes what it prints; this loop (3) refuses to eval
    # any line that is not KEY=value or KEY='value' from a plain charset. Before
    # this fix a single quote in e.g. beast_host ended the quoting and the rest of
    # the value ran here as root (reported privately by Daniel, 2026-10-26).
    # Keep the charset in step with feeder/assignment.py SAFE_VALUE_RE.
    _reg_line_re="^[A-Z][A-Z0-9_]*=('[A-Za-z0-9._:/@+=,-]*'|[A-Za-z0-9._:/@+=,-]*)$"
    while IFS= read -r _reg_line; do
        if ! [[ "$_reg_line" =~ $_reg_line_re ]]; then
            echo "❌ Registration response rejected - unexpected line from register.py:"
            echo "     ${_reg_line//[^[:print:]]/?}"
            echo "   Nothing was installed. Please report this to Dataero."
            exit 1
        fi
    done <<< "$REG_VARS"
    unset _reg_line _reg_line_re
    eval "$REG_VARS"
    if [ -z "$BEAST_HOST" ] || [ -z "$BEAST_PORT" ]; then
        echo "❌ Registration response was incomplete (no Beast endpoint):"
        echo "$REG_VARS" | sed 's/^/     /'
        echo "   This is a server-side configuration issue — please report it. Aborting."
        exit 1
    fi
    echo "✅ Registered: receiver $RECEIVER_UUID -> direct Beast $BEAST_HOST:$BEAST_PORT (beast_id $BEAST_ID)."

    # Effective MLAT state from the server (register.py emits the bool as
    # True/False); normalise to lowercase for .env + reinstall reuse.
    MLAT_EFFECTIVE="false"; [[ "${MLAT_ENABLED,,}" =~ ^(1|true|yes)$ ]] && MLAT_EFFECTIVE="true"

    # Persist identity + hub config. .env may hold secrets, so lock it down.
    {
        echo "REGISTRAR_URL=$REGISTRAR_URL"
        echo "RECEIVER_UUID=$RECEIVER_UUID"
        echo "FEEDER_NAME=$FEEDER_NAME"
        echo "FEEDER_LAT=$FEEDER_LAT"
        echo "FEEDER_LON=$FEEDER_LON"
        echo "FEEDER_ALT_M=$FEEDER_ALT_M"
        echo "REDUCE_INTERVAL=$REDUCE_INTERVAL"
        # ADSB-71: what the forwarder reads and which binary runs it.
        echo "LOCAL_SOURCE_FORMAT=$SRC_FORMAT"
        echo "LOCAL_SOURCE_PORT=$SRC_PORT"
        echo "READSB_BIN=$READSB_BIN"
        # Direct mode (ADSB-34): no shard/tunnel. Written empty so the daemon's
        # first-heartbeat no-op check matches and a later legacy assignment (if the
        # server ever sends one) can still populate them.
        echo "SHARD=$SHARD"
        echo "TUNNEL_IP=$TUNNEL_IP"
        echo "BEAST_HOST=$BEAST_HOST"
        echo "BEAST_PORT=$BEAST_PORT"
        # MLAT (epic ADSB-17): effective opt-in + the central mlat-server endpoint.
        echo "MLAT_ENABLED=$MLAT_EFFECTIVE"
        echo "MLAT_SERVER_HOST=$MLAT_SERVER_HOST"
        echo "MLAT_SERVER_PORT=$MLAT_SERVER_PORT"
        # Informational: the claim link for this unclaimed receiver — kept so the
        # operator can find it again to bind the receiver to their account.
        echo "CLAIM_URL=$CLAIM_URL"
    } | sudo tee -a "$INSTALL_DIR/.env" > /dev/null
    sudo chmod 600 "$INSTALL_DIR/.env"

    # Direct mode: readsb dials the public Beast endpoint straight over TCP.
    # (feeder/wg_setup.sh is retained for the daemon's legacy dual-mode path but
    # is not invoked on a direct install.)
    echo "🔧 Setting up the Dataero feed (dedicated net-only forwarder; your decoder and other feeds are NOT modified) -> $BEAST_HOST:$BEAST_PORT ..."
    UUID="$RECEIVER_UUID" HUB_HOST="$BEAST_HOST" HUB_PORT="$BEAST_PORT" REDUCE_INTERVAL="$REDUCE_INTERVAL" \
        LOCAL_SOURCE_PORT="$SRC_PORT" LOCAL_SOURCE_FORMAT="$SRC_FORMAT" READSB_BIN="$READSB_BIN" \
        bash "$(dirname "$0")/feeder/configure_readsb_reduce.sh"

    # MLAT (epic ADSB-17): if the operator opted in AND the server accepted it
    # (honoured only with a full position) AND returned a server endpoint, install
    # + start mlat-client. It reads the LOCAL full Beast (127.0.0.1:30005 — not the
    # reduced hub stream) and dials the central mlat-server, running alongside the
    # reduce connector (two independent consumers of the same readsb).
    if [ "$MLAT_EFFECTIVE" = "true" ] && [ -n "$MLAT_SERVER_HOST" ] && [ "$SRC_FORMAT" = "beast" ]; then
        echo "🛰️  Setting up MLAT (mlat-client -> $MLAT_SERVER_HOST:$MLAT_SERVER_PORT) ..."
        MLAT_VENV="$INSTALL_DIR/.venv-mlat" \
            bash "$(dirname "$0")/feeder/install_mlat_client.sh"
        MLAT_VENV="$INSTALL_DIR/.venv-mlat" RECEIVER_UUID="$RECEIVER_UUID" \
            MLAT_SERVER_HOST="$MLAT_SERVER_HOST" MLAT_SERVER_PORT="$MLAT_SERVER_PORT" \
            FEEDER_LAT="$FEEDER_LAT" FEEDER_LON="$FEEDER_LON" FEEDER_ALT_M="$FEEDER_ALT_M" \
            MLAT_USER="${FEEDER_NAME:-$RECEIVER_UUID}" BEAST_IN="127.0.0.1:$SRC_PORT" \
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

# Create systemd service file. After= is only emitted when we matched a known
# decoder unit; otherwise Restart=always plus main.py's tolerance of a missing
# aircraft.json let the feeder catch up once the decoder is producing.
# ADSB-71: ordering only. Never Requires=/Wants= on a unit that is not ours -
# starting dataero-feeder must never start (or pull in) the user's decoder.
UNIT_DEPS=""
if [ -n "$DATA_SOURCE_UNIT" ]; then
    UNIT_DEPS="After=$DATA_SOURCE_UNIT"
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
#    reduced Beast directly to the hub), so the meaningful client-side check is
#    that the heartbeat is accepted (proving the receiver is registered +
#    enabled).
#    curl exits non-zero only on transport failures; 4xx/5xx come back as the
#    HTTP status code, inspected explicitly below.
if ! command -v curl &> /dev/null; then
    echo "📦 Installing curl for the API test..."
    sudo apt-get install -y curl
fi

RUN_API_TEST="yes"
CURL_DATA=()
if [ "$FEED_MODE" = "beast" ]; then
    TEST_URL="$REGISTRAR_URL/receivers/heartbeat"
    TEST_LABEL="registrar heartbeat (aircraft data flows via the direct Beast stream, not this POST)"
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
            echo "✅ Registrar accepted the heartbeat (HTTP $HTTP_CODE). This receiver is registered + enabled; dataero-readsb.service is forwarding reduced Beast directly to the hub."
            echo "   ℹ️  Confirm the stream is attributed on the Dataero server side (feeder list / message counter)."
            ;;
        401|403)
            echo "❌ Registrar refused the heartbeat (HTTP $HTTP_CODE)."
            echo "   This receiver may have been disabled or claimed by another account."
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

# 4. ADSB-71 proof of non-interference: every foreign decoder/feeder unit must be
#    exactly as it was before this installer ran (same state, same MainPID =
#    never restarted).
FOREIGN_AFTER="$(_snapshot_foreign)"
if [ ${#FOREIGN_UNITS[@]} -gt 0 ]; then
    if [ "$FOREIGN_BEFORE" = "$FOREIGN_AFTER" ]; then
        echo "✅ Your other feeds were not touched (same state and process as before the install):"
        echo "$FOREIGN_AFTER" | sed 's/^/     /'
    else
        echo "⚠️  A service that is not Dataero's changed while the installer ran. This installer"
        echo "   never starts, stops or restarts them, so something else did - please check it:"
        echo "   before:"; echo "$FOREIGN_BEFORE" | sed 's/^/     /'
        echo "   after:";  echo "$FOREIGN_AFTER"  | sed 's/^/     /'
    fi
fi

echo ""
echo "🎉 Installation complete. dataero-readsb.service forwards reduced Beast (uuid $RECEIVER_UUID) directly to hub $BEAST_HOST:$BEAST_PORT — the shared decoder is untouched; the feeder heartbeats $REGISTRAR_URL."
echo ""

# Feed-first, claim-later: every install registers the receiver UNCLAIMED — it
# is feeding but not yet linked to an account. The operator claims it in the web
# UI by pasting the receiver UUID below — claiming lives ONLY in the profile
# "Receiver" tab now (the standalone /claim page was removed). The explicit
# ultrafeeder warning is deliberate: operators from FR24/ADSBx/PiAware reflexively
# paste their ultrafeeder UUID, a DIFFERENT id that yields "receiver not found".
echo "📌 This receiver is feeding, but it is NOT YET LINKED to a Dataero account."
echo ""
echo "   ✅ To claim it: sign in at https://radar.dataero.eu, open your"
echo "      profile → Receiver tab, and paste THIS Dataero receiver UUID into"
echo "      \"Link a receiver\":"
echo ""
echo "          $RECEIVER_UUID"
echo ""
echo "   ⚠️  Use the Dataero UUID above — NOT your ultrafeeder / readsb UUID."
echo "      They are different ids; the ultrafeeder one gives \"receiver not found\"."
echo "      (Lost it? Read it back with: sudo grep RECEIVER_UUID $INSTALL_DIR/.env)"
echo ""
echo "   ✈️  Reminder: the bytes you're now relaying were lovingly decoded by"
echo "      readsb (https://github.com/wiedehopf/readsb). If you ever bump"
echo "      into wiedehopf or a readsb maintainer in the wild, buy them a"
echo "      coffee. We owe them the entire upper half of this stack."
echo ""
