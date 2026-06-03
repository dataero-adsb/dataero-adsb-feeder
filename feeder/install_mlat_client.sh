#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
#
# Install the wiedehopf mlat-client into a DEDICATED venv (separate from the
# feeder venv) for MLAT participation (epic ADSB-17 / ADSB-21). mlat-client has a
# compiled C extension (_modes), so build-essential + python3-dev are required.
#
# Env / config:
#   MLAT_VENV   install venv          (default: /usr/local/dataero-adsb-feeder/.venv-mlat)
#   MLAT_REPO   mlat-client git repo  (default: wiedehopf/mlat-client)
#   MLAT_REF    git ref to install    (default: master)
#
# Idempotent: rebuilds the venv from scratch each run.
set -euo pipefail

MLAT_VENV="${MLAT_VENV:-/usr/local/dataero-adsb-feeder/.venv-mlat}"
MLAT_REPO="${MLAT_REPO:-https://github.com/wiedehopf/mlat-client.git}"
MLAT_REF="${MLAT_REF:-master}"

echo "📦 Installing mlat-client build prerequisites (git, build-essential, python3-dev)..."
sudo apt-get install -y --no-install-recommends git build-essential python3-dev python3-venv

echo "🐍 Creating mlat-client venv at $MLAT_VENV..."
sudo rm -rf "$MLAT_VENV"
sudo python3 -m venv "$MLAT_VENV"
sudo "$MLAT_VENV/bin/pip" install --upgrade pip

echo "⬇️  Building + installing mlat-client from ${MLAT_REPO}@${MLAT_REF} (compiles _modes)..."
sudo "$MLAT_VENV/bin/pip" install "git+${MLAT_REPO}@${MLAT_REF}"

# The package installs the `mlat-client` script into the venv bin (setup.py
# scripts=['mlat-client']). Confirm it runs before declaring success.
if "$MLAT_VENV/bin/mlat-client" --help >/dev/null 2>&1; then
    echo "✅ mlat-client installed at $MLAT_VENV/bin/mlat-client."
else
    echo "❌ mlat-client did not install correctly into $MLAT_VENV." >&2
    exit 1
fi
