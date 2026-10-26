#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
#
# Write + (re)start the dataero-mlat.service systemd unit that runs the wiedehopf
# mlat-client (epic ADSB-17 / ADSB-21). It feeds multilateration in parallel with
# the reduce connector — the two are independent consumers of the same readsb:
#
#   * mlat-client reads the LOCAL FULL Beast (127.0.0.1:30005). It MUST be the
#     full stream, NOT the reduced one the feeder sends to the hub — MLAT needs
#     precise per-message timing, which the position-throttled reduce stream
#     destroys. This is a local read; it does not touch readsb's config.
#   * It connects to the central mlat-server (the LB-fronted public endpoint the
#     registrar returned), sending the receiver UUID + surveyed antenna position.
#
# Env / config (all required unless noted):
#   MLAT_VENV          mlat-client venv   (default: /usr/local/dataero-adsb-feeder/.venv-mlat)
#   RECEIVER_UUID      feeder receiver id (sent via --uuid; identity on the server)
#   MLAT_SERVER_HOST   central mlat-server host (from registration)
#   MLAT_SERVER_PORT   central mlat-server port (from registration)
#   FEEDER_LAT/LON     surveyed antenna position, decimal degrees
#   FEEDER_ALT_M       surveyed antenna altitude, metres
#   MLAT_USER          contact label sent to the server (default: RECEIVER_UUID)
#   BEAST_IN           local full Beast (default: 127.0.0.1:30005)
#
# Idempotent: rewrites the unit and restarts the service.
#
# ADSB-72: every value interpolated into the unit is format-checked first
# (feeder/guards.sh), and MLAT_USER - the station name the operator typed - is
# reduced to a plain label and written in double quotes. Unquoted, a name with a
# space ("Daniel Home") was split by systemd into `--user Daniel` + `Home`,
# mlat-client exited 2 ("unrecognized arguments: Home") and Restart=always looped
# every 30 s: MLAT never started for any station name containing a space.
set -euo pipefail
# shellcheck source=guards.sh
source "$(dirname "${BASH_SOURCE[0]}")/guards.sh"

MLAT_VENV="${MLAT_VENV:-/usr/local/dataero-adsb-feeder/.venv-mlat}"
RECEIVER_UUID="${RECEIVER_UUID:?RECEIVER_UUID required}"
MLAT_SERVER_HOST="${MLAT_SERVER_HOST:?MLAT_SERVER_HOST required (from Dataero registration)}"
MLAT_SERVER_PORT="${MLAT_SERVER_PORT:?MLAT_SERVER_PORT required (from Dataero registration)}"
FEEDER_LAT="${FEEDER_LAT:?FEEDER_LAT required for MLAT (accurate antenna position)}"
FEEDER_LON="${FEEDER_LON:?FEEDER_LON required for MLAT (accurate antenna position)}"
FEEDER_ALT_M="${FEEDER_ALT_M:?FEEDER_ALT_M required for MLAT (accurate antenna altitude)}"
MLAT_USER="${MLAT_USER:-$RECEIVER_UUID}"
BEAST_IN="${BEAST_IN:-127.0.0.1:30005}"
SERVICE_FILE="/etc/systemd/system/dataero-mlat.service"

if [ ! -f "$MLAT_VENV/bin/mlat-client" ]; then
    echo "❌ mlat-client not found at $MLAT_VENV/bin/mlat-client — run install_mlat_client.sh first." >&2
    exit 1
fi

# ── ADSB-72: nothing below is written until every input has its expected format.
require_abs_path MLAT_VENV
require_abs_path SERVICE_FILE
require_uuid RECEIVER_UUID
require_host MLAT_SERVER_HOST
require_port MLAT_SERVER_PORT
require_signed_decimal FEEDER_LAT
require_signed_decimal FEEDER_LON
require_signed_decimal FEEDER_ALT_M
require_hostport BEAST_IN
# The contact label is free text from the operator: keep letters, digits, space,
# dot, underscore and dash; fall back to the receiver UUID when nothing is left.
_MLAT_USER_IN="$MLAT_USER"
label_for_systemd MLAT_USER "$RECEIVER_UUID"
if [ "$MLAT_USER" != "$_MLAT_USER_IN" ]; then
    echo "ℹ️  MLAT contact label simplified to \"$MLAT_USER\" (only letters, digits, space, . _ - are kept)."
fi

# Invoke via the venv python explicitly: the mlat-client script's
# `#!/usr/bin/env python3` shebang isn't rewritten to the venv on a scripts=
# install, so running it directly would use the system python3 (no mlat/_modes).
# --alt accepts a 'm'/'ft' suffix; FEEDER_ALT_M is metres, so make it explicit.
sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Dataero MLAT client (multilateration)
# ADSB-71: no Requires= on the decoder - it may be fr24feed's dump1090, readsb
# or anything else, and starting MLAT must never start (or pull in) it.
After=network-online.target readsb.service

[Service]
ExecStart=$MLAT_VENV/bin/python $MLAT_VENV/bin/mlat-client \\
  --input-type dump1090 \\
  --input-connect $BEAST_IN \\
  --server $MLAT_SERVER_HOST:$MLAT_SERVER_PORT \\
  --user "$MLAT_USER" \\
  --uuid $RECEIVER_UUID \\
  --lat $FEEDER_LAT --lon $FEEDER_LON --alt ${FEEDER_ALT_M}m
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOL

echo "🔄 Enabling + starting dataero-mlat.service..."
sudo systemctl daemon-reload
sudo systemctl enable dataero-mlat.service
sudo systemctl restart dataero-mlat.service
echo "✅ mlat-client running: $BEAST_IN -> mlat-server $MLAT_SERVER_HOST:$MLAT_SERVER_PORT (uuid $RECEIVER_UUID, user \"$MLAT_USER\")."
