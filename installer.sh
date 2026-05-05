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

API_KEY=""
if [ -n "$EXISTING_KEY" ]; then
    KEY_LEN=${#EXISTING_KEY}
    if [ "$KEY_LEN" -gt 8 ]; then
        MASKED_KEY="${EXISTING_KEY:0:4}...${EXISTING_KEY: -4}"
    else
        MASKED_KEY="(short key)"
    fi
    echo "🔑 An existing API key was found in $INSTALL_DIR/.env: $MASKED_KEY ($KEY_LEN chars)"
    read -p "🔑 Keep this key? (yes/no): " KEEP_KEY
    if [[ "$KEEP_KEY" =~ ^(y|yes|Y|YES)$ ]]; then
        API_KEY="$EXISTING_KEY"
        echo "✅ Reusing existing API key."
    fi
fi

if [ -z "$API_KEY" ]; then
    echo "🔑 If you don't have a Dataero API key yet, you can get one at: https://radar.dataero.eu/profile"
    read -p "🔑 Enter your Dataero API key: " API_KEY
fi

# Persist API key plus the detected aircraft.json path. Writing READSB_DATA
# explicitly (rather than relying on main.py's default) is what lets the
# feeder transparently consume dump1090-fa's output on PiAware without any
# user intervention.
echo "API_KEY=$API_KEY"             | sudo tee    "$INSTALL_DIR/.env" > /dev/null
echo "READSB_DATA=$DATA_SOURCE_FILE" | sudo tee -a "$INSTALL_DIR/.env" > /dev/null
echo "✅ Configuration saved (API key + data source: $DATA_SOURCE_FILE)."

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

# 2. Live API test: send one real payload from this installer to validate
#    network reachability, TLS, and the API key in a single round-trip.
#    curl exits non-zero only on transport failures; 4xx/5xx are reported
#    via the HTTP status code, which we inspect explicitly below.
READSB_DATA_FILE="$DATA_SOURCE_FILE"
if [ ! -r "$READSB_DATA_FILE" ]; then
    echo "⚠️  $READSB_DATA_FILE is not readable yet — ${DATA_SOURCE_UNIT:-the decoder} may still be warming up."
    echo "   Skipping live API test. Re-check later with:"
    echo "     sudo journalctl -u dataero-feeder.service -f"
else
    if ! command -v curl &> /dev/null; then
        echo "📦 Installing curl for the API test..."
        sudo apt-get install -y curl
    fi
    echo "📡 Sending a test payload to https://radar.dataero.eu/api/v1/messages ..."
    RESP_BODY=$(mktemp)
    HTTP_CODE=$(curl -sS -o "$RESP_BODY" -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "X-Target-Host: radar.dataero.eu" \
        --data @"$READSB_DATA_FILE" \
        "https://radar.dataero.eu/api/v1/messages" || echo "000")
    case "$HTTP_CODE" in
        2*)
            echo "✅ API accepted the upload (HTTP $HTTP_CODE). Data is flowing to radar.dataero.eu."
            ;;
        401|403)
            echo "❌ API rejected your credentials (HTTP $HTTP_CODE)."
            echo "   Check your API key on https://radar.dataero.eu/profile and edit $INSTALL_DIR/.env"
            echo "   Response body:"
            sed 's/^/     /' "$RESP_BODY"
            rm -f "$RESP_BODY"
            exit 1
            ;;
        000)
            echo "❌ Could not reach https://radar.dataero.eu. Check this device's internet connection."
            rm -f "$RESP_BODY"
            exit 1
            ;;
        *)
            echo "⚠️  Unexpected API response (HTTP $HTTP_CODE). Response body:"
            sed 's/^/     /' "$RESP_BODY"
            echo "   The service is running; monitor logs to confirm uploads continue:"
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
echo "🎉 Installation complete. Your feeder is sending data to radar.dataero.eu."
echo ""
echo "   ✈️  Reminder: the bytes you're now relaying were lovingly decoded by"
echo "      readsb (https://github.com/wiedehopf/readsb). If you ever bump"
echo "      into wiedehopf or a readsb maintainer in the wild, buy them a"
echo "      coffee. We owe them the entire upper half of this stack."
echo ""
