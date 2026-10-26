# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
"""ADSB-72 - the registrar/heartbeat values are validated before any privileged
use. Run from the repo root:  python3 -m unittest discover -s tests -v

Pure stdlib. `requests` and `python-dotenv` are stubbed when absent so the suite
runs on a bare machine; nothing here touches the network or the filesystem
outside a temp dir."""
import io
import os
import re
import shlex
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "feeder"))

for _mod in ("requests", "dotenv"):
    if _mod not in sys.modules:
        try:
            __import__(_mod)
        except ImportError:  # pragma: no cover - bare test machine
            stub = types.ModuleType(_mod)
            if _mod == "requests":
                stub.Session = lambda: None
                stub.RequestException = Exception
                stub.post = None
            else:
                stub.load_dotenv = lambda *a, **k: None
            sys.modules[_mod] = stub

import assignment  # noqa: E402
import register  # noqa: E402
import main  # noqa: E402

# The eval gate in installer.sh, kept in step by hand (see the comment there).
EVAL_GATE = re.compile(r"^[A-Z][A-Z0-9_]*=('[A-Za-z0-9._:/@+=,-]*'|[A-Za-z0-9._:/@+=,-]*)$")

UUID = "11111111-2222-3333-4444-555555555555"
WG_KEY = "mNb8Z5GjvcTd3z6dAxZJNK6mQW5F8nq6SBzI9ZV8QUo="

# Exactly what adsb-api build_registration_response emits in DIRECT mode.
DIRECT_REG = {
    "receiver_id": UUID, "beast_id": "1111111122223333", "shard": None,
    "tunnel_ip": None, "enabled": True, "mlat_enabled": False,
    "mlat_reason": None, "wireguard": None,
    "aggregator": {"beast_host": "adsb.dataero.eu", "beast_port": 30004},
    "mlat": None, "claimed": False, "secret": "bound",
    "claim_url": f"https://radar.dataero.eu/claim/{UUID}",
}
# ...and in LEGACY (tunnel) mode, MLAT accepted.
LEGACY_REG = {
    **DIRECT_REG, "shard": "ctr-01a", "tunnel_ip": "10.7.0.2",
    "mlat_enabled": True, "mlat_reason": None,
    "wireguard": {"hub_public_key": WG_KEY, "hub_endpoint": "adsb.dataero.eu:51820",
                  "allowed_ips": "10.7.0.1/32", "address": "10.7.0.2/32",
                  "persistent_keepalive": 25},
    "aggregator": {"beast_host": "10.7.0.1", "beast_port": 30004},
    "mlat": {"server_host": "mlat.dataero.eu", "server_port": 31090},
    "claimed": True, "claim_url": None,
}
DIRECT_CFG = {"shard": None, "tunnel_ip": None, "wireguard": None,
              "aggregator": {"beast_host": "adsb.dataero.eu", "beast_port": 30004}}
LEGACY_CFG = {"shard": "ctr-01a", "tunnel_ip": "10.7.0.2",
              "wireguard": LEGACY_REG["wireguard"],
              "aggregator": {"beast_host": "10.7.0.1", "beast_port": 30004}}
EPOCH = "0123456789abcdef"

# The reporter's payloads, verbatim.
INJ_QUOTE = "hub.example'; touch /tmp/pwned1; : '"
INJ_NEWLINE = "x\nExecStartPre=/bin/sh -c 'id > /tmp/pwned2'\nX-Pad="


def _emit(reg):
    buf = io.StringIO()
    with redirect_stdout(buf):
        register._emit_shell(assignment.validate_registration(reg))
    return buf.getvalue().splitlines()


class RegistrationValidation(unittest.TestCase):
    def test_direct_response_accepted(self):
        out = assignment.validate_registration(DIRECT_REG)
        self.assertEqual(out["BEAST_HOST"], "adsb.dataero.eu")
        self.assertEqual(out["BEAST_PORT"], 30004)
        self.assertEqual(out["SHARD"], "")
        self.assertEqual(out["WG_HUB_PUBKEY"], "")
        self.assertEqual(out["CLAIM_URL"], DIRECT_REG["claim_url"])
        self.assertEqual(out["SECRET_STATUS"], "bound")
        self.assertIs(out["MLAT_ENABLED"], False)

    def test_legacy_response_accepted(self):
        out = assignment.validate_registration(LEGACY_REG)
        self.assertEqual(out["WG_HUB_ENDPOINT"], "adsb.dataero.eu:51820")
        self.assertEqual(out["WG_ADDRESS"], "10.7.0.2/32")
        self.assertEqual(out["TUNNEL_IP"], "10.7.0.2")
        self.assertEqual(out["MLAT_SERVER_PORT"], 31090)
        self.assertIs(out["MLAT_ENABLED"], True)

    def test_bug1_single_quote_in_beast_host_rejected(self):
        bad = {**DIRECT_REG, "aggregator": {"beast_host": INJ_QUOTE, "beast_port": 30004}}
        with self.assertRaises(assignment.InvalidAssignment):
            assignment.validate_registration(bad)

    def test_newline_in_any_field_rejected(self):
        for field, value in (
            ("beast_id", "1111111122223333\n"),
            ("shard", "ctr-01a\nPostUp=id"),
            ("mlat_reason", "x\ny"),
            ("claim_url", "https://radar.dataero.eu/claim/x\nEvil=1"),
            ("secret", "ok\n"),
        ):
            with self.subTest(field=field):
                with self.assertRaises(assignment.InvalidAssignment):
                    assignment.validate_registration({**DIRECT_REG, field: value})

    def test_wireguard_block_fully_validated(self):
        wg = LEGACY_REG["wireguard"]
        for field, value in (
            ("hub_endpoint", "adsb.dataero.eu:51820\nPostUp=/bin/sh -c id"),
            ("hub_public_key", "not-a-key"),
            ("allowed_ips", "10.7.0.1/32,evil"),
            ("address", "10.7.0.2"),
            ("persistent_keepalive", "25; id"),
        ):
            with self.subTest(field=field):
                bad = {**LEGACY_REG, "wireguard": {**wg, field: value}}
                with self.assertRaises(assignment.InvalidAssignment):
                    assignment.validate_registration(bad)

    def test_port_range_and_type(self):
        for p in (0, 65536, -1, "30004\n", "abc", True, 3.5, None):
            with self.subTest(port=p):
                bad = {**DIRECT_REG, "aggregator": {"beast_host": "adsb.dataero.eu", "beast_port": p}}
                with self.assertRaises(assignment.InvalidAssignment):
                    assignment.validate_registration(bad)

    def test_hostname_rules(self):
        ok = ["adsb.dataero.eu", "10.7.0.1", "a", "x-y.example", "a" * 63 + ".eu"]
        bad = ["-x.eu", "x-.eu", "a" * 64 + ".eu", "host name", "host;id", "héllo.eu",
               "a." * 127 + "a", "", "$(id)", "`id`", "x|y"]
        for h in ok:
            self.assertEqual(assignment.hostname(h, "h"), h)
        for h in bad:
            with self.subTest(host=h), self.assertRaises(assignment.InvalidAssignment):
                assignment.hostname(h, "h")

    def test_claim_url_rules(self):
        for u in ("http://radar.dataero.eu/claim/x", "https://radar.dataero.eu/claim?x=1",
                  "https://user@radar.dataero.eu/", "https://radar.dataero.eu/c'laim",
                  "https://radar.dataero.eu/claim/x#f", "ftp://x"):
            with self.subTest(url=u), self.assertRaises(assignment.InvalidAssignment):
                assignment.validate_registration({**DIRECT_REG, "claim_url": u})

    def test_missing_endpoint_rejected(self):
        with self.assertRaises(assignment.InvalidAssignment):
            assignment.validate_registration({**DIRECT_REG, "aggregator": {}})


class ShellEmission(unittest.TestCase):
    def test_every_line_passes_the_installer_eval_gate(self):
        for reg in (DIRECT_REG, LEGACY_REG):
            for line in _emit(reg):
                with self.subTest(line=line):
                    self.assertRegex(line, EVAL_GATE)

    def test_emitted_values_round_trip_through_shlex(self):
        lines = _emit(LEGACY_REG)
        env = {}
        for line in lines:
            k, v = line.split("=", 1)
            parts = shlex.split(v)
            env[k] = parts[0] if parts else ""
        self.assertEqual(env["BEAST_HOST"], "10.7.0.1")
        self.assertEqual(env["WG_HUB_PUBKEY"], WG_KEY)
        self.assertEqual(env["MLAT_ENABLED"], "True")   # installer lowercases + matches
        self.assertEqual(env["SHARD"], "ctr-01a")
        self.assertEqual(env["WG_KEEPALIVE"], "25")
        self.assertEqual(set(env), {
            "BEAST_ID", "SHARD", "TUNNEL_IP", "ENABLED", "WG_ADDRESS", "WG_HUB_PUBKEY",
            "WG_HUB_ENDPOINT", "WG_ALLOWED_IPS", "WG_KEEPALIVE", "BEAST_HOST", "BEAST_PORT",
            "MLAT_ENABLED", "MLAT_REASON", "MLAT_SERVER_HOST", "MLAT_SERVER_PORT",
            "CLAIM_URL", "SECRET_STATUS"})

    def test_emit_shell_quotes_even_if_validation_were_bypassed(self):
        """Defence in depth: _emit_shell on its own must never produce a line the
        eval could execute, and the gate must reject what it produces."""
        buf = io.StringIO()
        with redirect_stdout(buf):
            register._emit_shell({"BEAST_HOST": INJ_QUOTE, "X": INJ_NEWLINE})
        text = buf.getvalue()
        self.assertEqual(text.splitlines()[0], "BEAST_HOST=" + shlex.quote(INJ_QUOTE))
        self.assertFalse(all(EVAL_GATE.match(l) for l in text.splitlines()))
        self.assertNotIn("\ntouch", text.replace(shlex.quote(INJ_QUOTE), ""))


class HeartbeatValidation(unittest.TestCase):
    def test_direct_config_accepted(self):
        out = assignment.validate_heartbeat_config(DIRECT_CFG, EPOCH)
        self.assertTrue(out["direct"])
        self.assertIsNone(out["wireguard"])
        self.assertEqual((out["beast_host"], out["beast_port"]), ("adsb.dataero.eu", 30004))

    def test_legacy_config_accepted(self):
        out = assignment.validate_heartbeat_config(LEGACY_CFG, EPOCH)
        self.assertFalse(out["direct"])
        self.assertEqual(out["wireguard"]["hub_endpoint"], "adsb.dataero.eu:51820")

    def test_bug2_newline_in_beast_host_rejected(self):
        bad = {**DIRECT_CFG, "aggregator": {"beast_host": INJ_NEWLINE, "beast_port": 30004}}
        with self.assertRaises(assignment.InvalidAssignment):
            assignment.validate_heartbeat_config(bad, EPOCH)

    def test_epoch_format(self):
        for e in ("", "xyz", "0123456789abcdef\n", "0123456789ABCDEF!", "0" * 17):
            with self.subTest(epoch=e), self.assertRaises(assignment.InvalidAssignment):
                assignment.validate_heartbeat_config(DIRECT_CFG, e)

    def test_legacy_without_shard_rejected(self):
        bad = {**LEGACY_CFG, "shard": None}
        with self.assertRaises(assignment.InvalidAssignment):
            assignment.validate_heartbeat_config(bad, EPOCH)

    def test_maybe_apply_config_ignores_an_invalid_block(self):
        """main.maybe_apply_config must neither run a script nor touch .env when
        the config block fails validation."""
        calls = []
        tmp = tempfile.mkdtemp()
        env_file = os.path.join(tmp, ".env")
        with open(env_file, "w") as f:
            f.write("BEAST_HOST=adsb.dataero.eu\nBEAST_PORT=30004\n")
        orig = (main.ENV_FILE, main._run_feeder_script, main._applied_epoch,
                main._last_reconfig_fail_ts, main._last_error_print_ts)
        try:
            main.ENV_FILE = env_file
            main._run_feeder_script = lambda *a, **k: calls.append(a)
            main._applied_epoch = ""
            main._last_reconfig_fail_ts = 0.0
            main._last_error_print_ts = 0.0
            resp = {"ok": True, "config_epoch": EPOCH,
                    "config": {**DIRECT_CFG, "aggregator": {"beast_host": INJ_NEWLINE,
                                                            "beast_port": 30004}}}
            with redirect_stdout(io.StringIO()):
                main.maybe_apply_config(resp)
            self.assertEqual(calls, [])
            self.assertEqual(main._applied_epoch, "")
            with open(env_file) as f:
                self.assertEqual(f.read(), "BEAST_HOST=adsb.dataero.eu\nBEAST_PORT=30004\n")
        finally:
            (main.ENV_FILE, main._run_feeder_script, main._applied_epoch,
             main._last_reconfig_fail_ts, main._last_error_print_ts) = orig

    def test_maybe_apply_config_applies_a_valid_direct_change(self):
        calls = []
        tmp = tempfile.mkdtemp()
        env_file = os.path.join(tmp, ".env")
        with open(env_file, "w") as f:
            f.write("BEAST_HOST=old.dataero.eu\nBEAST_PORT=30004\nSHARD=\n")
        orig = (main.ENV_FILE, main._run_feeder_script, main._applied_epoch,
                main._last_reconfig_fail_ts, main._teardown_tunnel)
        saved_env = {k: os.environ.get(k) for k in ("BEAST_HOST", "BEAST_PORT", "SHARD",
                                                     "TUNNEL_IP", "CONFIG_EPOCH")}
        try:
            os.environ.update({"BEAST_HOST": "old.dataero.eu", "BEAST_PORT": "30004", "SHARD": ""})
            main.ENV_FILE = env_file
            main._run_feeder_script = lambda script, env: calls.append((script, env))
            main._teardown_tunnel = lambda: None
            main._applied_epoch = ""
            main._last_reconfig_fail_ts = 0.0
            with redirect_stdout(io.StringIO()):
                main.maybe_apply_config({"ok": True, "config_epoch": EPOCH, "config": DIRECT_CFG})
            self.assertEqual(len(calls), 1)
            script, env = calls[0]
            self.assertEqual(script, "configure_readsb_reduce.sh")
            self.assertEqual((env["HUB_HOST"], env["HUB_PORT"]), ("adsb.dataero.eu", 30004))
            self.assertEqual(main._applied_epoch, EPOCH)
            with open(env_file) as f:
                body = f.read()
            self.assertIn("BEAST_HOST=adsb.dataero.eu\n", body)
            self.assertIn(f"CONFIG_EPOCH={EPOCH}\n", body)
        finally:
            (main.ENV_FILE, main._run_feeder_script, main._applied_epoch,
             main._last_reconfig_fail_ts, main._teardown_tunnel) = orig
            for k, v in saved_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


class EnvFileGuard(unittest.TestCase):
    def test_update_env_file_rejects_newlines_and_quotes(self):
        tmp = tempfile.mkdtemp()
        env_file = os.path.join(tmp, ".env")
        with open(env_file, "w") as f:
            f.write("A=1\n")
        orig = main.ENV_FILE
        try:
            main.ENV_FILE = env_file
            for bad in (INJ_NEWLINE, "x\ry", "it's", 'say "hi"', "a b", "50%", "$HOME", "x\\y"):
                with self.subTest(value=bad), self.assertRaises(ValueError):
                    main._update_env_file({"BEAST_HOST": bad})
            with open(env_file) as f:
                self.assertEqual(f.read(), "A=1\n")
            with self.assertRaises(ValueError):
                main._update_env_file({"bad key": "x"})
            main._update_env_file({"BEAST_HOST": "adsb.dataero.eu", "BEAST_PORT": 30004})
            with open(env_file) as f:
                self.assertEqual(f.read(), "A=1\nBEAST_HOST=adsb.dataero.eu\nBEAST_PORT=30004\n")
        finally:
            main.ENV_FILE = orig
            for k in ("BEAST_HOST", "BEAST_PORT"):
                os.environ.pop(k, None)


class Version(unittest.TestCase):
    def test_feeder_version_moved(self):
        self.assertEqual(main.FEEDER_VERSION, "1.2.1")


if __name__ == "__main__":
    unittest.main()
