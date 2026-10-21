#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
#
# Build the Dataero forwarder binary: wiedehopf readsb, NET-ONLY.
#
# Used when the host has no readsb binary of its own - e.g. a Flightradar24
# Pi24 image (fr24feed + dump1090) or a PiAware image (dump1090-fa). The binary
# is compiled with RTLSDR=no, so it contains no SDR driver at all: it CANNOT
# open the radio dongle and can never take it away from fr24feed or dump1090.
#
# What this script does - and nothing else:
#   * apt-get installs the build tools if missing (build-essential, git,
#     pkg-config, libzstd-dev, zlib1g-dev, libncurses-dev). Installing packages
#     does not stop, restart or reconfigure any running service.
#   * clones readsb at a pinned tag into a temporary directory, compiles it,
#     copies the binary to $DEST (default /usr/local/dataero-adsb-feeder/bin/readsb).
#   * NO systemd unit, no /etc/default/readsb, nothing under /usr/bin.
#
# readsb is GPL software by wiedehopf: https://github.com/wiedehopf/readsb
#
# Env:
#   READSB_TAG  pinned readsb release        (default: v3.16.17)
#   DEST        where the binary is written  (default: /usr/local/dataero-adsb-feeder/bin/readsb)
#
# Idempotent: skips the build when $DEST already reports the pinned version.
set -euo pipefail

READSB_TAG="${READSB_TAG:-v3.16.17}"
DEST="${DEST:-/usr/local/dataero-adsb-feeder/bin/readsb}"
WANT_VERSION="${READSB_TAG#v}"

if [ -x "$DEST" ] && "$DEST" --version 2>&1 | grep -q "version: ${WANT_VERSION} "; then
    echo "✅ Dataero forwarder binary already built ($DEST, readsb ${WANT_VERSION}, net-only)."
    exit 0
fi

PKGS=(build-essential git pkg-config libzstd-dev zlib1g-dev libncurses-dev)
MISSING=()
for p in "${PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || MISSING+=("$p")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "📦 Installing build tools: ${MISSING[*]} (no running service is touched)..."
    sudo apt-get install -y "${MISSING[@]}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "⬇️  Fetching readsb ${READSB_TAG} (net-only build, no SDR driver)..."
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$READSB_TAG" https://github.com/wiedehopf/readsb.git "$WORK/readsb"
echo "🔨 Compiling (a few minutes on a Raspberry Pi)..."
make -C "$WORK/readsb" -j"$(nproc)" RTLSDR=no >"$WORK/build.log" 2>&1 || {
    echo "❌ readsb build failed. Last lines of the build log:" >&2
    tail -20 "$WORK/build.log" >&2
    exit 1
}
sudo install -D -m 0755 "$WORK/readsb/readsb" "$DEST"
echo "✅ Built $DEST ($("$DEST" --version 2>&1 | grep -m1 'version:'), net-only)."
