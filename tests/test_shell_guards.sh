#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
#
# ADSB-72 - end-to-end check of the shell gates. Runs the REAL feeder scripts
# with sudo / systemctl / wg-quick stubbed and every absolute path redirected
# under a temp dir, feeds them (a) the registrar's legitimate values and (b) the
# payloads of the 2026-10-26 report, and asserts that (a) writes the expected
# unit while (b) exits 1 and writes nothing. Also checks the installer's eval
# gate and the MLAT --user quoting. No root, no network, no systemd needed.
#
#   bash tests/test_shell_guards.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc/systemd/system" "$T/etc/wireguard" "$T/venv/bin"
printf '#!/bin/bash\nexec "$@"\n' > "$T/bin/sudo"
printf '#!/bin/bash\necho "systemctl $*" >> "%s/systemctl.log"\n' "$T" > "$T/bin/systemctl"
printf '#!/bin/bash\necho "wg-quick $*" >> "%s/wg.log"\n' "$T" > "$T/bin/wg-quick"
printf '#!/bin/bash\n' > "$T/bin/readsb"
chmod +x "$T/bin/"* ; touch "$T/venv/bin/mlat-client" "$T/venv/bin/python"
export PATH="$T/bin:$PATH"

# Copies of the scripts with their absolute targets pointed into $T.
cp "$ROOT/feeder/guards.sh" "$T/guards.sh"
sed -e "s#/etc/systemd/system/dataero-readsb.service#$T/etc/systemd/system/dataero-readsb.service#" \
    -e "s#READSB_DEFAULT:-/etc/default/readsb#READSB_DEFAULT:-$T/etc/default-readsb-absent#" \
    "$ROOT/feeder/configure_readsb_reduce.sh" > "$T/configure_readsb_reduce.sh"
sed -e "s#/etc/systemd/system/dataero-mlat.service#$T/etc/systemd/system/dataero-mlat.service#" \
    "$ROOT/feeder/configure_mlat_client.sh" > "$T/configure_mlat_client.sh"
sed -e "s#/etc/wireguard#$T/etc/wireguard#g" "$ROOT/feeder/wg_setup.sh" > "$T/wg_setup.sh"

UUID=11111111-2222-3333-4444-555555555555
KEY="mNb8Z5GjvcTd3z6dAxZJNK6mQW5F8nq6SBzI9ZV8QUo="
INJ_QUOTE="hub.example'; touch $T/pwned1; : '"
INJ_NL=$'x\nExecStartPre=/bin/sh -c \'id > /tmp/pwned2\'\nX-Pad='
INJ_WG=$'adsb.dataero.eu:51820\nPostUp = /bin/sh -c id'

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

reduce() { UUID="$UUID" READSB_BIN="$T/bin/readsb" LOCAL_SOURCE_PORT=30005 REDUCE_INTERVAL=0.25 \
           HUB_HOST="$1" HUB_PORT="$2" bash "$T/configure_readsb_reduce.sh" >"$T/out" 2>"$T/err"; }
mlat()   { MLAT_VENV="$T/venv" RECEIVER_UUID="$UUID" MLAT_SERVER_HOST="$1" MLAT_SERVER_PORT=31090 \
           FEEDER_LAT=50.85 FEEDER_LON=4.35 FEEDER_ALT_M=60 MLAT_USER="$2" \
           bash "$T/configure_mlat_client.sh" >"$T/out" 2>"$T/err"; }
wg()     { WG_PRIVKEY="$KEY" WG_ADDRESS=10.7.0.2/32 WG_HUB_PUBKEY="$KEY" WG_HUB_ENDPOINT="$1" \
           WG_ALLOWED_IPS="$2" WG_KEEPALIVE=25 bash "$T/wg_setup.sh" >"$T/out" 2>"$T/err"; }

echo "configure_readsb_reduce.sh"
reduce adsb.dataero.eu 30004; rc=$?
check "legit host:port -> exit 0" '[ $rc -eq 0 ]'
check "unit written with the endpoint" 'grep -q -- "--net-connector=adsb.dataero.eu,30004,beast_reduce_plus_out,uuid=$UUID" "$T/etc/systemd/system/dataero-readsb.service"'
check "service restarted" 'grep -q "restart dataero-readsb.service" "$T/systemctl.log"'
rm -f "$T/etc/systemd/system/dataero-readsb.service" "$T/systemctl.log"
reduce "$INJ_NL" 30004; rc=$?
check "bug 2 payload (newline in beast_host) -> exit 1" '[ $rc -eq 1 ]'
check "  nothing written" '[ ! -e "$T/etc/systemd/system/dataero-readsb.service" ] && [ ! -e "$T/systemctl.log" ]'
check "  error names the variable" 'grep -q "HUB_HOST is not a valid hostname" "$T/err"'
reduce "$INJ_QUOTE" 30004; rc=$?
check "bug 1 payload (quote in beast_host) -> exit 1" '[ $rc -eq 1 ] && [ ! -e "$T/pwned1" ]'
reduce adsb.dataero.eu 70000; rc=$?
check "port 70000 -> exit 1" '[ $rc -eq 1 ]'
reduce 'adsb.dataero.eu %h $X' 30004; rc=$?
check "systemd specifier chars -> exit 1" '[ $rc -eq 1 ]'

echo "configure_mlat_client.sh"
mlat mlat.dataero.eu "Daniel Home"; rc=$?
check "station name with a space -> exit 0" '[ $rc -eq 0 ]'
check "bug 3: --user is double-quoted in ExecStart" 'grep -q -- "--user \"Daniel Home\"" "$T/etc/systemd/system/dataero-mlat.service"'
mlat mlat.dataero.eu $'Dan\'s "Home" %h $X\nExecStartPre=id'; rc=$?
check "hostile label -> exit 0, label reduced to [A-Za-z0-9 ._-]" '[ $rc -eq 0 ] && grep -qE -- "^  --user \"[A-Za-z0-9 ._-]+\" \\\\$" "$T/etc/systemd/system/dataero-mlat.service"'
check "  no injected directive" '! grep -q "^ExecStartPre" "$T/etc/systemd/system/dataero-mlat.service"'
mlat mlat.dataero.eu '!!!'; rc=$?
check "unprintable label -> falls back to the UUID" '[ $rc -eq 0 ] && grep -q -- "--user \"$UUID\"" "$T/etc/systemd/system/dataero-mlat.service"'
rm -f "$T/etc/systemd/system/dataero-mlat.service"
mlat "$INJ_NL" "x"; rc=$?
check "newline in MLAT_SERVER_HOST -> exit 1, nothing written" '[ $rc -eq 1 ] && [ ! -e "$T/etc/systemd/system/dataero-mlat.service" ]'

echo "wg_setup.sh"
wg adsb.dataero.eu:51820 10.7.0.1/32; rc=$?
check "legit WireGuard values -> exit 0" '[ $rc -eq 0 ]'
check "conf written" 'grep -q "^Endpoint = adsb.dataero.eu:51820$" "$T/etc/wireguard/wg-adsb.conf"'
rm -f "$T/etc/wireguard/wg-adsb.conf" "$T/wg.log"
wg "$INJ_WG" 10.7.0.1/32; rc=$?
check "newline + PostUp in hub_endpoint -> exit 1, nothing written" '[ $rc -eq 1 ] && [ ! -e "$T/etc/wireguard/wg-adsb.conf" ] && [ ! -e "$T/wg.log" ]'
wg adsb.dataero.eu:51820 '10.7.0.1/32,evil'; rc=$?
check "bad allowed_ips -> exit 1" '[ $rc -eq 1 ]'
WG_PRIVKEY="not-a-key" WG_ADDRESS=10.7.0.2/32 WG_HUB_PUBKEY="$KEY" WG_HUB_ENDPOINT=adsb.dataero.eu:51820 \
    WG_ALLOWED_IPS=10.7.0.1/32 bash "$T/wg_setup.sh" >/dev/null 2>&1; rc=$?
check "bad key -> exit 1" '[ $rc -eq 1 ]'

echo "installer.sh eval gate"
# Extract the gate block from the installer and run it against register.py output.
sed -n '/_reg_line_re=/,/done <<< "\$REG_VARS"/p' "$ROOT/installer.sh" | tr -d '\r' > "$T/gate.sh"
check "gate block extracted" '[ -s "$T/gate.sh" ] && grep -q "done <<<" "$T/gate.sh"'
GOOD=$(printf "BEAST_HOST=adsb.dataero.eu\nBEAST_PORT=30004\nSHARD=''\nCLAIM_URL=https://radar.dataero.eu/claim/%s\nMLAT_ENABLED=False\nWG_HUB_PUBKEY=%s\n" "$UUID" "$KEY")
(REG_VARS="$GOOD"; source "$T/gate.sh") ; rc=$?
check "legit register.py lines pass" '[ $rc -eq 0 ]'
BADQ="BEAST_HOST='hub.example'; touch $T/pwned1; : ''"
(REG_VARS="$BADQ"; source "$T/gate.sh") >/dev/null; rc=$?
check "bug 1 line (pre-fix output) rejected" '[ $rc -eq 1 ] && [ ! -e "$T/pwned1" ]'
BADS="BEAST_HOST='hub.example'\"'\"'; touch $T/pwned1; : '\"'\"''"
(REG_VARS="$BADS"; source "$T/gate.sh") >/dev/null; rc=$?
check "shlex-quoted hostile value still rejected by the gate" '[ $rc -eq 1 ]'
(REG_VARS=""; source "$T/gate.sh") >/dev/null; rc=$?
check "empty output rejected" '[ $rc -eq 1 ]'
(REG_VARS=$'BEAST_HOST=x\nrm -rf /tmp/x'; source "$T/gate.sh") >/dev/null; rc=$?
check "bare command line rejected" '[ $rc -eq 1 ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
