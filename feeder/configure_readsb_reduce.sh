#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
#
# Configure Dataero's feed as a DEDICATED, net-only readsb instance that taps the
# local decoder and forwards a reduced Beast stream to the Dataero hub.
#
# ── BUBBLE RULE (do not violate) ───────────────────────────────────────────────
# We must NEVER disrupt other feeders on this host. Earlier versions of this
# script edited the SHARED /etc/default/readsb and restarted the main readsb —
# which blips every other feeder that reads it and, on a bad edit, takes the main
# decoder (and therefore ALL feeders) down. That was wrong.
#
# This version runs our OWN readsb process (dataero-readsb.service) that:
#   * reads the main decoder's Beast output at 127.0.0.1:<LOCAL_BEAST_PORT> (read-only),
#   * forwards reduced Beast (carrying our uuid) to the Dataero hub,
#   * opens NO listening ports (all readsb listen ports default to 0/off), so it
#     cannot conflict with the main readsb,
#   * NEVER writes /etc/default/readsb and NEVER restarts the shared decoder.
# This is the same coexisting model FR24 / FlightAware / Adsb-Italia use.
#
# It also SELF-HEALS: if a previous Dataero install edited /etc/default/readsb,
# it strips ONLY our own connector back out and restarts the main readsb ONCE to
# undo that past intrusion (other feeders' connectors are left untouched).
#
# Env / config:
#   UUID             (required) feeder receiver id (from Dataero registration)
#   HUB_HOST         hub host the reduced Beast goes to   (default: adsb.dataero.eu)
#   HUB_PORT         hub Beast ingest port                (default: 30005)
#   LOCAL_BEAST_PORT main decoder Beast output to tap     (default: 30005)
#   REDUCE_INTERVAL  position-throttle seconds            (default: 0.25)
#   READSB_BIN       readsb binary                        (autodetected)
#   READSB_DEFAULT   shared config path (self-heal only)  (default: /etc/default/readsb)
#
# Idempotent: rewrites our unit + restarts only OUR service.
set -euo pipefail

HUB_HOST="${HUB_HOST:-adsb.dataero.eu}"
HUB_PORT="${HUB_PORT:-30005}"
UUID="${UUID:?UUID required (feeder receiver id from Dataero registration)}"
LOCAL_BEAST_PORT="${LOCAL_BEAST_PORT:-30005}"
REDUCE_INTERVAL="${REDUCE_INTERVAL:-0.25}"
READSB_DEFAULT="${READSB_DEFAULT:-/etc/default/readsb}"
SERVICE_FILE="/etc/systemd/system/dataero-readsb.service"

# Locate the readsb binary — we REUSE it, we do not install or reconfigure it.
READSB_BIN="${READSB_BIN:-$(command -v readsb || true)}"
if [ -z "$READSB_BIN" ]; then
    for c in /usr/bin/readsb /usr/local/bin/readsb; do
        [ -x "$c" ] && READSB_BIN="$c" && break
    done
fi
if [ -z "$READSB_BIN" ] || [ ! -x "$READSB_BIN" ]; then
    echo "❌ readsb binary not found — cannot start the Dataero feed instance." >&2
    exit 1
fi

# ── Self-heal: undo any /etc/default/readsb edit a PREVIOUS Dataero install made.
# Strip ONLY our own --net-connector (matched by our uuid), leave everything else
# exactly as-is, then restart the main readsb ONCE so other feeders get a clean
# decoder. Skips entirely if we never touched it (the normal case from now on).
if [ -f "$READSB_DEFAULT" ] && grep -q "uuid=${UUID}" "$READSB_DEFAULT" 2>/dev/null; then
    echo "🧹 Legacy install detected — removing our connector from the shared $READSB_DEFAULT (no other feeders touched)..."
    sudo python3 - "$READSB_DEFAULT" "$UUID" <<'PY'
import re, shlex, sys
path, uuid = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
out = []
for line in lines:
    m = re.match(r'^(\s*NET_OPTIONS\s*=\s*)(["\'])(.*)\2(\s*)$', line)
    if not m:
        out.append(line)
        continue
    toks = [t for t in shlex.split(m.group(3))
            if not (t.startswith('--net-connector=') and ('uuid=' + uuid) in t)]
    out.append('%s"%s"\n' % (m.group(1), ' '.join(toks)))
with open(path, 'w') as f:
    f.writelines(out)
print("stripped Dataero connector from NET_OPTIONS")
PY
    sudo systemctl restart readsb.service 2>/dev/null || true
    echo "✅ Shared readsb restored; from now on Dataero never edits it."
fi

# ── Our own dedicated, net-only forwarder. No listeners (readsb listen ports
# default to 0), so zero conflict with the main readsb; it only reads the main
# decoder's Beast output and forwards a reduced copy to the hub.
sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Dataero ADS-B feed (dedicated net-only readsb -> Dataero hub)
After=network-online.target
Wants=network-online.target

[Service]
# --net-only: networking, NO SDR (we never touch the radio or the main decoder).
# Reads the local decoder's Beast output read-only and forwards a reduced stream.
ExecStart=$READSB_BIN --net-only --quiet \\
  --net-connector=127.0.0.1,$LOCAL_BEAST_PORT,beast_in \\
  --net-connector=$HUB_HOST,$HUB_PORT,beast_reduce_plus_out,uuid=$UUID \\
  --net-beast-reduce-interval $REDUCE_INTERVAL
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOL

echo "🔄 Enabling + starting dataero-readsb.service..."
sudo systemctl daemon-reload
sudo systemctl enable dataero-readsb.service
sudo systemctl restart dataero-readsb.service
echo "✅ dataero-readsb.service up: taps 127.0.0.1:$LOCAL_BEAST_PORT (read-only) -> reduced Beast (uuid $UUID) -> $HUB_HOST:$HUB_PORT. Shared decoder untouched."
