#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
# See LICENSE in the project root for full terms.
#
# Surgical uninstaller for the Dataero ADS-B feeder.
#
# It removes ONLY what the Dataero installer created:
#   * our systemd services      : dataero-feeder, dataero-readsb, dataero-mlat
#   * our WireGuard tunnel       : wg-adsb (only if it carries our managed header)
#   * our connector(s)           : any --net-connector to a Dataero endpoint left
#                                  in the shared /etc/default/readsb by an OLD install
#   * our install directory      : /usr/local/dataero-adsb-feeder (.venv, .venv-mlat, .env)
#   * our debug log              : /var/log/dataero-adsb-feeder.log
#
# It NEVER touches anything else. Specifically it will NOT:
#   * stop / disable / restart / reconfigure the shared decoder (readsb) or its SDR,
#   * touch any OTHER feeder (FR24, FlightAware, Adsb-Italia, rbfeeder, ...),
#   * touch any OTHER WireGuard interface,
#   * remove apt packages (wireguard-tools, build-essential, python3-dev, git, curl)
#     — other software may rely on them.
#
# The single place it edits a shared file is removing OUR OWN leftover connector
# from /etc/default/readsb (legacy installs only); even then it does NOT restart
# readsb — it backs the file up and tells you to restart at your convenience, so
# other feeders are never disturbed by this script.
#
# Idempotent + guarded: every step checks existence first and acts only on
# Dataero-owned resources. Safe to run repeatedly or on a partial install.
#
# Usage: sudo bash uninstaller.sh [-y|--yes]
set -euo pipefail

INSTALL_DIR="/usr/local/dataero-adsb-feeder"
WG_IFACE="wg-adsb"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
READSB_DEFAULT="/etc/default/readsb"
DEBUG_LOG="/var/log/dataero-adsb-feeder.log"
OUR_SERVICES=(dataero-feeder dataero-readsb dataero-mlat)

ASSUME_YES=0
[[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && ASSUME_YES=1

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    echo "❌ Run as root, or install sudo." >&2
    exit 1
fi

echo "🧹 Dataero ADS-B feeder — surgical uninstall"
echo "   Removes ONLY: ${OUR_SERVICES[*]}, the ${WG_IFACE} tunnel, our connector in"
echo "   ${READSB_DEFAULT} (legacy only), ${INSTALL_DIR}, and ${DEBUG_LOG}."
echo "   NEVER touches: the main readsb/SDR, other feeders, other WG interfaces, apt packages."
if [ "$ASSUME_YES" -ne 1 ]; then
    read -p "Proceed? (y/N): " _ans
    [[ "${_ans:-}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] || { echo "Aborted — nothing changed."; exit 0; }
fi

removed_any=0
legacy_connector_removed=0

# ── 1) Our systemd services — stop, disable, remove the unit. Guarded per unit;
#       only acts on OUR three service names, never any other unit.
for svc in "${OUR_SERVICES[@]}"; do
    if systemctl cat "${svc}.service" >/dev/null 2>&1; then
        echo "⏹  Stopping + disabling ${svc}.service ..."
        sudo systemctl disable --now "${svc}.service" >/dev/null 2>&1 || true
    fi
    unit="/etc/systemd/system/${svc}.service"
    if [ -f "$unit" ]; then
        sudo rm -f "$unit"
        echo "🗑  Removed ${unit}"
        removed_any=1
    fi
done
sudo systemctl daemon-reload >/dev/null 2>&1 || true

# ── 2) Our WireGuard tunnel — ONLY wg-adsb, and ONLY if the conf is ours (header
#       check), so a same-named interface we didn't create is never removed.
if [ -f "$WG_CONF" ]; then
    if grep -q "Managed by dataero-adsb-feeder" "$WG_CONF" 2>/dev/null; then
        echo "🔻 Bringing down + removing WireGuard ${WG_IFACE} ..."
        sudo wg-quick down "$WG_IFACE" >/dev/null 2>&1 || true
        sudo systemctl disable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
        sudo rm -f "$WG_CONF"
        echo "🗑  Removed ${WG_CONF}"
        removed_any=1
    else
        echo "⚠️  ${WG_CONF} exists but is not Dataero-managed — leaving it untouched."
    fi
fi

# ── 3) Remove OUR connector(s) from the shared readsb config — legacy installs
#       only (the current feeder uses a dedicated instance and never writes here).
#       Strip ONLY connectors to a Dataero endpoint; leave every other token and
#       every other feeder's connector intact. Does NOT restart readsb (a shared
#       process) — backs up the file and asks you to restart when convenient.
if [ -f "$READSB_DEFAULT" ] && grep -qE 'net-connector=(adsb\.dataero\.eu|10\.7\.)' "$READSB_DEFAULT" 2>/dev/null; then
    echo "🧽 Removing Dataero connector(s) from the shared ${READSB_DEFAULT} (other feeders untouched)..."
    sudo cp -a "$READSB_DEFAULT" "${READSB_DEFAULT}.dataero-uninstall.bak" 2>/dev/null || true
    sudo python3 - "$READSB_DEFAULT" <<'PY'
import re, shlex, sys
path = sys.argv[1]
def ours(t):
    if not t.startswith('--net-connector='):
        return False
    host = t.split('=', 1)[1].split(',')[0]
    return host == 'adsb.dataero.eu' or host.startswith('10.7.')
out = []
for line in open(path):
    m = re.match(r'^(\s*NET_OPTIONS\s*=\s*)(["\'])(.*)\2(\s*)$', line)
    if not m:
        out.append(line)
        continue
    toks = [t for t in shlex.split(m.group(3)) if not ours(t)]
    out.append('%s"%s"\n' % (m.group(1), ' '.join(toks)))
open(path, 'w').writelines(out)
PY
    echo "✅ Stripped our connector(s) from ${READSB_DEFAULT} (backup: ${READSB_DEFAULT}.dataero-uninstall.bak)."
    legacy_connector_removed=1
    removed_any=1
fi

# ── 4) Our install directory (feeder/, .venv, .venv-mlat, .env, requirements.txt).
if [ -d "$INSTALL_DIR" ]; then
    sudo rm -rf "$INSTALL_DIR"
    echo "🗑  Removed ${INSTALL_DIR}"
    removed_any=1
fi

# ── 5) Our debug log, if DEBUG mode ever created it.
if [ -f "$DEBUG_LOG" ]; then
    sudo rm -f "$DEBUG_LOG"
    echo "🗑  Removed ${DEBUG_LOG}"
    removed_any=1
fi

echo ""
if [ "$removed_any" -eq 1 ]; then
    echo "✅ Dataero feeder uninstalled."
else
    echo "ℹ️  Nothing to remove — no Dataero feeder components found."
fi
if [ "$legacy_connector_removed" -eq 1 ]; then
    echo ""
    echo "ℹ️  A legacy Dataero connector was removed from ${READSB_DEFAULT}, but the"
    echo "    RUNNING readsb still has it loaded. To fully stop that old feed, restart"
    echo "    the shared decoder when convenient (this briefly blips ALL feeders):"
    echo "        sudo systemctl restart readsb"
fi
echo ""
echo "   Left untouched by design: the main readsb decoder + SDR, all other feeders,"
echo "   other WireGuard interfaces, and apt packages. Remove those manually only if"
echo "   you're sure nothing else needs them."
