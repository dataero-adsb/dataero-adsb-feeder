#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
#
# Configure the LOCAL readsb to forward a *reduced* Beast stream (with UUID) to
# the Dataero aggregator, using readsb's native `beast_reduce_plus_out`
# connector. This is the FlightRadar24/ADSBExchange-standard edge-reduction
# approach (FR24 hard rule: reduce at the edge with readsb-native mechanisms).
#
# IMPORTANT — this DELIBERATELY edits the decoder config (/etc/default/readsb,
# the NET_OPTIONS line) and restarts readsb. That reverses the old "never touch
# the decoder" stance for the reduced path. The edit is *additive* (it only adds
# an outbound connector + the reduce interval; existing outputs like :30005 and
# aircraft.json are untouched), so other consumers on the host keep working —
# but readsb is restarted, which briefly interrupts all of its consumers.
#
# readsb ONLY: dump1090-fa does not support the beast_reduce_plus_out connector.
#
# Env / config:
#   UUID            (required) feeder receiver id (from Dataero registration)
#   HUB_HOST        aggregator host           (default: adsb.dataero.eu)
#   HUB_PORT        Dataero LB ingest port    (default: 30005 — the load
#                   balancer receives Beast on 30005 and forwards to the
#                   aggregator container's beast-input)
#   REDUCE_INTERVAL position throttle seconds (default: 0.25 — readsb default)
#   READSB_DEFAULT  config path               (default: /etc/default/readsb)
#
# Idempotent: re-running replaces our previous connector/interval rather than
# stacking duplicates.
set -euo pipefail

HUB_HOST="${HUB_HOST:-adsb.dataero.eu}"
HUB_PORT="${HUB_PORT:-30005}"
UUID="${UUID:?UUID required (feeder receiver id from Dataero registration)}"
REDUCE_INTERVAL="${REDUCE_INTERVAL:-0.25}"
READSB_DEFAULT="${READSB_DEFAULT:-/etc/default/readsb}"

if ! systemctl cat readsb.service &>/dev/null; then
    echo "❌ readsb.service not found. The native reduced-Beast connector requires readsb"
    echo "   (dump1090-fa is not supported in this mode). Use a different feed mode."
    exit 1
fi
if [ ! -f "$READSB_DEFAULT" ]; then
    echo "❌ $READSB_DEFAULT not found — is this a wiedehopf readsb install?"
    exit 1
fi

CONNECTOR="--net-connector=${HUB_HOST},${HUB_PORT},beast_reduce_plus_out,uuid=${UUID}"
REDUCE_OPT="--net-beast-reduce-interval ${REDUCE_INTERVAL}"

# Back up the current config before editing.
sudo cp -a "$READSB_DEFAULT" "${READSB_DEFAULT}.dataero.bak" || true

# Rewrite NET_OPTIONS with python3 (tokenised, safe) rather than sed: strip any
# previous Dataero beast_reduce connector + reduce-interval, then append fresh.
sudo python3 - "$READSB_DEFAULT" "$CONNECTOR" "$REDUCE_INTERVAL" <<'PY'
import re, shlex, sys
path, connector, interval = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
out, found = [], False
for line in lines:
    m = re.match(r'^\s*NET_OPTIONS\s*=\s*"(.*)"\s*$', line)
    if not m:
        out.append(line)
        continue
    found = True
    toks, cleaned, skip = shlex.split(m.group(1)), [], False
    for t in toks:
        if skip:
            skip = False
            continue
        if t.startswith('--net-connector=') and 'beast_reduce_plus_out' in t:
            continue
        if t == '--net-beast-reduce-interval':
            skip = True
            continue
        if t.startswith('--net-beast-reduce-interval='):
            continue
        cleaned.append(t)
    cleaned += [connector, '--net-beast-reduce-interval', interval]
    out.append('NET_OPTIONS="%s"\n' % ' '.join(cleaned))
if not found:
    out.append('NET_OPTIONS="--net %s --net-beast-reduce-interval %s"\n' % (connector, interval))
with open(path, 'w') as f:
    f.writelines(out)
print("✅ NET_OPTIONS updated with the Dataero reduced-Beast connector.")
PY

echo "🔄 Restarting readsb to apply..."
sudo systemctl restart readsb.service
echo "✅ readsb now forwards reduced Beast (uuid ${UUID}) to ${HUB_HOST}:${HUB_PORT}."
