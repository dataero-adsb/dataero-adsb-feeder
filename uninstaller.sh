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
#   * remove apt packages (wireguard-tools, build-essential, python3-dev, git, curl).
#
# The single place it edits a shared file is removing OUR OWN leftover connector
# from /etc/default/readsb (legacy installs only); even then it does NOT restart
# readsb — it backs the file up and tells you to restart at your convenience.
#
# BEST-EFFORT BY DESIGN: this script must ALWAYS run to completion and ALWAYS exit
# 0, even if individual steps fail — it is meant to be run before (re)installing
# another/older version, so a downgrade must never be blocked by a half-failed
# step. There is intentionally NO `set -e`/`pipefail`; every step is guarded and
# continues on error, reporting what it could and couldn't do.
#
# Idempotent + guarded: every step checks existence first and acts only on
# Dataero-owned resources. Safe to run repeatedly or on a partial install.
#
# Usage: sudo bash uninstaller.sh [-y|--yes]    (non-interactive => proceeds)

INSTALL_DIR="/usr/local/dataero-adsb-feeder"
WG_IFACE="wg-adsb"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
READSB_DEFAULT="/etc/default/readsb"
DEBUG_LOG="/var/log/dataero-adsb-feeder.log"
OUR_SERVICES="dataero-feeder dataero-readsb dataero-mlat"

# Privilege helper: run as root directly, else via sudo, else best-effort (each
# step will just fail-and-skip rather than abort the script).
if [ "$(id -u 2>/dev/null)" = "0" ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    SUDO=""
    echo "⚠️  Not root and sudo not found — steps needing privileges will be skipped."
fi

# Proceed without prompting when -y/--yes is given OR when stdin isn't a terminal
# (i.e. invoked from another script, e.g. a reinstall/downgrade flow).
ASSUME_YES=0
case "${1:-}" in -y|--yes) ASSUME_YES=1 ;; esac
[ -t 0 ] || ASSUME_YES=1

echo "🧹 Dataero ADS-B feeder — surgical uninstall (best-effort; never aborts)"
echo "   Removes ONLY: ${OUR_SERVICES}, the ${WG_IFACE} tunnel, our connector in"
echo "   ${READSB_DEFAULT} (legacy only), ${INSTALL_DIR}, and ${DEBUG_LOG}."
echo "   NEVER touches: the main readsb/SDR, other feeders, other WG interfaces, apt packages."
if [ "$ASSUME_YES" -ne 1 ]; then
    read -p "Proceed? (y/N): " _ans
    case "${_ans:-}" in
        y|Y|yes|YES) ;;
        *) echo "Aborted — nothing changed."; exit 0 ;;
    esac
fi

removed_any=0
legacy_connector_removed=0

# ── 1) Our systemd services — stop, disable, remove the unit. Guarded per unit;
#       only acts on OUR three service names, never any other unit. Each command
#       is best-effort so one stubborn unit can't stop the rest.
for svc in $OUR_SERVICES; do
    if systemctl cat "${svc}.service" >/dev/null 2>&1; then
        echo "⏹  Stopping + disabling ${svc}.service ..."
        $SUDO systemctl disable --now "${svc}.service" >/dev/null 2>&1 || \
            echo "   ⚠️  could not fully stop/disable ${svc}.service — continuing."
    fi
    unit="/etc/systemd/system/${svc}.service"
    if [ -f "$unit" ]; then
        if $SUDO rm -f "$unit" 2>/dev/null; then
            echo "🗑  Removed ${unit}"; removed_any=1
        else
            echo "   ⚠️  could not remove ${unit} — continuing."
        fi
    fi
done
$SUDO systemctl daemon-reload >/dev/null 2>&1 || true

# ── 2) Our WireGuard tunnel — ONLY wg-adsb, and ONLY if the conf is ours (header
#       check), so a same-named interface we didn't create is never removed.
if [ -f "$WG_CONF" ]; then
    if grep -q "Managed by dataero-adsb-feeder" "$WG_CONF" 2>/dev/null; then
        echo "🔻 Bringing down + removing WireGuard ${WG_IFACE} ..."
        $SUDO wg-quick down "$WG_IFACE" >/dev/null 2>&1 || \
            echo "   ⚠️  ${WG_IFACE} was not up (or wg-quick missing) — continuing."
        $SUDO systemctl disable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
        if $SUDO rm -f "$WG_CONF" 2>/dev/null; then
            echo "🗑  Removed ${WG_CONF}"; removed_any=1
        else
            echo "   ⚠️  could not remove ${WG_CONF} — continuing."
        fi
    else
        echo "⚠️  ${WG_CONF} exists but is not Dataero-managed — leaving it untouched."
    fi
fi

# ── 3) Remove OUR connector(s) from the shared readsb config — legacy installs
#       only. Strip ONLY connectors to a Dataero endpoint; leave every other token
#       and every other feeder's connector intact. Does NOT restart readsb.
if [ -f "$READSB_DEFAULT" ] && grep -qE 'net-connector=(adsb\.dataero\.eu|10\.7\.)' "$READSB_DEFAULT" 2>/dev/null; then
    if command -v python3 >/dev/null 2>&1; then
        echo "🧽 Removing Dataero connector(s) from the shared ${READSB_DEFAULT} (other feeders untouched)..."
        $SUDO cp -a "$READSB_DEFAULT" "${READSB_DEFAULT}.dataero-uninstall.bak" 2>/dev/null || true
        if $SUDO python3 - "$READSB_DEFAULT" <<'PY' 2>/dev/null
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
        then
            echo "✅ Stripped our connector(s) (backup: ${READSB_DEFAULT}.dataero-uninstall.bak)."
            legacy_connector_removed=1; removed_any=1
        else
            echo "   ⚠️  could not edit ${READSB_DEFAULT} — left as-is (backup kept). Continuing."
        fi
    else
        echo "   ⚠️  python3 not available — leaving ${READSB_DEFAULT} untouched. Continuing."
    fi
fi

# ── 4) Our install directory (feeder/, .venv, .venv-mlat, .env, requirements.txt).
if [ -d "$INSTALL_DIR" ]; then
    if $SUDO rm -rf "$INSTALL_DIR" 2>/dev/null; then
        echo "🗑  Removed ${INSTALL_DIR}"; removed_any=1
    else
        echo "   ⚠️  could not remove ${INSTALL_DIR} — continuing."
    fi
fi

# ── 5) Our debug log, if DEBUG mode ever created it.
if [ -f "$DEBUG_LOG" ]; then
    $SUDO rm -f "$DEBUG_LOG" 2>/dev/null && { echo "🗑  Removed ${DEBUG_LOG}"; removed_any=1; } || \
        echo "   ⚠️  could not remove ${DEBUG_LOG} — continuing."
fi

echo ""
if [ "$removed_any" -eq 1 ]; then
    echo "✅ Dataero feeder uninstall complete (best-effort)."
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
echo "   other WireGuard interfaces, and apt packages."

# Always succeed: a downgrade/reinstall that runs this first must never be blocked.
exit 0
