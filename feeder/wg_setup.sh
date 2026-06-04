#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.
#
# Bring up the feeder's WireGuard tunnel to its assigned Dataero ingest hub.
# Beast is sent to the hub's overlay address over THIS tunnel, so the hub
# identifies the feeder by its pinned /32 source address (in addition to the
# in-band beast_id). All values come from the registration response (see
# feeder/register.py) — this script just renders the config and (re)starts the
# interface. Must run as root (writes /etc/wireguard, calls wg-quick).
#
# Env (all required unless noted):
#   WG_PRIVKEY        feeder WireGuard private key
#   WG_ADDRESS        assigned tunnel address with mask, e.g. 10.7.0.2/32
#   WG_HUB_PUBKEY     hub (peer) WireGuard public key
#   WG_HUB_ENDPOINT   hub host:port the feeder dials (adsb.dataero.eu:<port>)
#   WG_ALLOWED_IPS    routed via the tunnel, e.g. 10.7.0.1/32 (the hub only)
#   WG_KEEPALIVE      persistent keepalive seconds          (default: 25)
#   WG_IFACE          interface / config name               (default: wg-adsb)
#
# Idempotent: rewrites the config and bounces the interface on every run.
set -euo pipefail

WG_IFACE="${WG_IFACE:-wg-adsb}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"

: "${WG_PRIVKEY:?WG_PRIVKEY required}"
: "${WG_ADDRESS:?WG_ADDRESS required (e.g. 10.7.0.2/32)}"
: "${WG_HUB_PUBKEY:?WG_HUB_PUBKEY required}"
: "${WG_HUB_ENDPOINT:?WG_HUB_ENDPOINT required (host:port)}"
: "${WG_ALLOWED_IPS:?WG_ALLOWED_IPS required (e.g. 10.7.0.1/32)}"

if ! command -v wg-quick &>/dev/null; then
    echo "❌ wg-quick not found. Install with: sudo apt-get install -y wireguard-tools"
    exit 1
fi

echo "🔐 Writing ${WG_CONF} (interface ${WG_IFACE})..."
sudo mkdir -p /etc/wireguard
# Build the config in a private temp file, then install it 0600 — so the private
# key never lands in a world-readable file even for a moment.
TMP_CONF="$(mktemp)"
chmod 600 "$TMP_CONF"
cat > "$TMP_CONF" <<EOF
# Managed by dataero-adsb-feeder (feeder/wg_setup.sh) — do not edit by hand.
# Regenerated from the Dataero registration response on each install.
[Interface]
PrivateKey = ${WG_PRIVKEY}
Address = ${WG_ADDRESS}

[Peer]
PublicKey = ${WG_HUB_PUBKEY}
Endpoint = ${WG_HUB_ENDPOINT}
AllowedIPs = ${WG_ALLOWED_IPS}
PersistentKeepalive = ${WG_KEEPALIVE}
EOF
sudo install -m 600 "$TMP_CONF" "$WG_CONF"
rm -f "$TMP_CONF"

# Bounce the interface: down (ignore "not up") then up to apply the new config.
echo "🔄 (Re)starting WireGuard interface ${WG_IFACE}..."
sudo wg-quick down "$WG_IFACE" 2>/dev/null || true
sudo wg-quick up "$WG_IFACE"

# Persist across reboots.
if command -v systemctl &>/dev/null; then
    sudo systemctl enable "wg-quick@${WG_IFACE}" &>/dev/null || true
fi

echo "✅ WireGuard ${WG_IFACE} up: ${WG_ADDRESS} -> peer ${WG_HUB_ENDPOINT} (allowed-ips ${WG_ALLOWED_IPS})."
