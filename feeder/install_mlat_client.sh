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

# asyncore was REMOVED from the stdlib in Python 3.12 (PEP 594), but mlat-client
# still `import asyncore` (mlat/client/net.py, output.py, coordinator.py). On 3.12+
# (e.g. Raspberry Pi OS Trixie ships Python 3.13) install the pyasyncore backport,
# which provides an importable `asyncore`, so mlat-client runs. No-op on <3.12.
PYVER=$("$MLAT_VENV/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
if "$MLAT_VENV/bin/python" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 12) else 1)'; then
    echo "🧩 Python $PYVER: installing the pyasyncore backport (stdlib asyncore removed in 3.12)..."
    sudo "$MLAT_VENV/bin/pip" install pyasyncore
fi

echo "⬇️  Building + installing mlat-client from ${MLAT_REPO}@${MLAT_REF} (compiles _modes)..."
sudo "$MLAT_VENV/bin/pip" install "git+${MLAT_REPO}@${MLAT_REF}"

# The package installs the `mlat-client` script into the venv bin (setup.py
# scripts=['mlat-client']). Its shebang is `#!/usr/bin/env python3`, which pip
# does NOT rewrite to the venv python for a scripts= install — so running
# bin/mlat-client directly would use the SYSTEM python3 (no mlat/_modes modules)
# and fail. Always invoke it via the venv python; the systemd unit does the same.
if [ ! -f "$MLAT_VENV/bin/mlat-client" ]; then
    echo "❌ mlat-client script missing from $MLAT_VENV/bin after install." >&2
    exit 1
fi
# Smoke-test via the venv python (the script's shebang isn't rewritten). NON-FATAL:
# a failing --help must not abort the whole feeder install — print the real error
# and let dataero-mlat.service surface runtime problems in its journal instead.
echo "🔎 Verifying mlat-client runs under the venv python..."
if _smoke="$("$MLAT_VENV/bin/python" "$MLAT_VENV/bin/mlat-client" --help 2>&1)"; then
    echo "✅ mlat-client installed (run via $MLAT_VENV/bin/python)."
else
    echo "⚠️  mlat-client installed, but the --help smoke test exited non-zero. Output:" >&2
    printf '%s\n' "$_smoke" | sed 's/^/     /' >&2
    echo "   Not aborting. After install, check: journalctl -u dataero-mlat.service -n 50" >&2
fi
