"""Unit tests for files/rewrite_http.py (the migration's http: / external_url rewrite).

Run from the repo root: python3 -m unittest discover -s roles/tenant/hass/tests
"""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

ROLE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rewrite_http", ROLE / "files/rewrite_http.py")
rh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rh)

EDGE = "fd5a:715f:1edc:a706::2b"
LETSENCRYPT = """\
# Loads default set of integrations. Do not remove.
default_config:

http:
  ssl_certificate: /ssl/fullchain.pem
  ssl_key: /ssl/privkey.pem
  # keep bans
  ip_ban_enabled: true
  login_attempts_threshold: 5
  cors_allowed_origins:
    - https://example.org

automation: !include automations.yaml
"""
NGINX_ADDON = """\
http:
    use_x_forwarded_for: true
    trusted_proxies:
    - 172.30.33.0/24
    server_port: 443
mqtt: !secret mqtt
"""


class RewriteYaml(unittest.TestCase):
    def test_drops_tls_and_keeps_the_rest(self):
        out, rep = rh.rewrite_yaml(LETSENCRYPT, EDGE)
        self.assertEqual(rep["dropped_http_keys"], ["ssl_certificate", "ssl_key"])
        self.assertNotIn("ssl_", out)
        for kept in ("# keep bans", "ip_ban_enabled: true", "login_attempts_threshold: 5",
                     "    - https://example.org", "default_config:", "automation: !include automations.yaml"):
            self.assertIn(kept, out)
        self.assertIn("  use_x_forwarded_for: true\n  trusted_proxies:\n    - %s\n" % EDGE, out)
        self.assertTrue(out.endswith("\n\nautomation: !include automations.yaml\n"))

    def test_replaces_the_proxy_addon_settings_at_its_indent(self):
        out, rep = rh.rewrite_yaml(NGINX_ADDON, EDGE)
        self.assertEqual(set(rep["dropped_http_keys"]), {"use_x_forwarded_for", "trusted_proxies", "server_port"})
        self.assertNotIn("172.30.33.0/24", out)
        self.assertNotIn("443", out)
        self.assertEqual(
            out,
            "http:\n    server_port: 8123\n    use_x_forwarded_for: true\n    trusted_proxies:\n"
            "      - %s\nmqtt: !secret mqtt\n" % EDGE,
        )

    def test_adds_a_block_when_there_is_none(self):
        out, rep = rh.rewrite_yaml("default_config:", EDGE)
        self.assertEqual(rep["old_http_block"], "")
        self.assertEqual(out, "default_config:\n\nhttp:\n  server_port: 8123\n  use_x_forwarded_for: true\n"
                              "  trusted_proxies:\n    - %s\n" % EDGE)

    def test_refuses_what_it_cannot_edit(self):
        for text in ("http: !include http.yaml\n", "http:\n  a: 1\nhttp:\n  b: 2\n"):
            with self.assertRaises(rh.Refuse):
                rh.rewrite_yaml(text, EDGE)

    def test_idempotent(self):
        once, _ = rh.rewrite_yaml(LETSENCRYPT, EDGE)
        twice, _ = rh.rewrite_yaml(once, EDGE)
        self.assertEqual(once, twice)


class RewriteCoreConfig(unittest.TestCase):
    def doc(self, internal):
        return json.dumps({"version": 1, "minor_version": 4, "key": "core.config",
                           "data": {"external_url": "https://hass-us.example.org", "internal_url": internal,
                                    "time_zone": "America/New_York"}})

    def test_sets_external_and_clears_legacy_internal(self):
        out, rep = rh.rewrite_core_config(self.doc("https://hass-us.example.org:443"),
                                          "https://hass.us.example.org", "hass-us.example.org")
        data = json.loads(out)["data"]
        self.assertEqual(data["external_url"], "https://hass.us.example.org")
        self.assertIsNone(data["internal_url"])
        self.assertEqual(data["time_zone"], "America/New_York")
        self.assertEqual(rep["old_external_url"], "https://hass-us.example.org")

    def test_keeps_a_plain_http_internal_url(self):
        out, _ = rh.rewrite_core_config(self.doc("http://192.168.3.24:8123"),
                                        "https://hass.us.example.org", "hass-us.example.org")
        self.assertEqual(json.loads(out)["data"]["internal_url"], "http://192.168.3.24:8123")


# What HAOS 2026.11.2 had in .storage/http (the settings HA actually used).
STORE = json.dumps({"version": 3, "minor_version": 1, "key": "http", "data": {
    "stable": {"server_port": 443, "ssl_certificate": "/ssl/fullchain.pem", "ssl_key": "/ssl/privkey.pem",
               "use_x_forwarded_for": True, "trusted_proxies": ["2400:cb00::/32"],
               "login_attempts_threshold": -1, "cors_allowed_origins": ["https://cast.home-assistant.io"],
               "ip_ban_enabled": True, "use_x_frame_options": True, "ssl_profile": "modern_v4",
               "created_at": "2026-08-07T21:42:37.226696+00:00", "error": None, "error_message": None},
    "pending": None, "yaml_migration_done": True}})


class RewriteHttpStore(unittest.TestCase):
    def test_drops_tls_keeps_the_rest_and_ssl_profile(self):
        out, rep = rh.rewrite_http_store(STORE, EDGE)
        st = json.loads(out)["data"]["stable"]
        self.assertEqual(rep["store_dropped_keys"], ["ssl_certificate", "ssl_key"])
        self.assertEqual((st["server_port"], st["use_x_forwarded_for"], st["trusted_proxies"]), (8123, True, [EDGE]))
        # The loader indexes ssl_profile unconditionally (KeyError without it).
        self.assertEqual(st["ssl_profile"], "modern_v4")
        for k in ("ip_ban_enabled", "login_attempts_threshold", "cors_allowed_origins", "use_x_frame_options"):
            self.assertEqual(st[k], json.loads(STORE)["data"]["stable"][k])
        self.assertTrue(json.loads(out)["data"]["yaml_migration_done"])

    def test_refuses_a_store_without_stable(self):
        with self.assertRaises(rh.Refuse):
            rh.rewrite_http_store(json.dumps({"data": {}}), EDGE)


class Main(unittest.TestCase):
    def test_dry_run_writes_nothing_and_real_run_keeps_modes(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / ".storage").mkdir()
            cfg, core = Path(d) / "configuration.yaml", Path(d) / ".storage/core.config"
            cfg.write_text(LETSENCRYPT)
            core.write_text(RewriteCoreConfig().doc(None))
            core.chmod(0o600)
            store = Path(d) / ".storage/http"
            store.write_text(STORE)
            args = [d, EDGE, "https://hass.us.example.org", "hass-us.example.org"]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(rh.main(["--dry-run", *args]), 0)
                self.assertEqual(cfg.read_text(), LETSENCRYPT)
                self.assertEqual(rh.main(args), 0)
            self.assertIn("trusted_proxies", cfg.read_text())
            self.assertEqual(core.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(core.read_text())["data"]["external_url"], "https://hass.us.example.org")
            self.assertEqual(json.loads(store.read_text())["data"]["stable"]["server_port"], 8123)


if __name__ == "__main__":
    unittest.main()
