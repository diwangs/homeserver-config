"""Nix evaluation checks of the bunkerweb NixOS configuration.

Run from the repo root: python3 -m unittest discover -s roles/tenant/bunkerweb/tests

Evaluates (does not build) the flake the same way build_template.yml and the in-guest
`nixos-rebuild` do — a `path:` copy of files/nixos with a rendered site.nix beside it
and the committed flake.lock, with --no-update-lock-file — and asserts on the resulting
option values. Skipped when `nix` is missing or the locked inputs cannot be fetched.
Set BUNKERWEB_NIX_BUILD=1 to also build the system closure.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

NIX_DIR = Path(__file__).resolve().parents[1] / "files/nixos"
NIX = shutil.which("nix")

# What templates/site.nix.j2 renders to, with placeholder values.
SITE = """{
  acmeEmail = "ops@example.org";
  bunkerwebVersion = "1.6.17";
  modsecurityEngine = "DetectionOnly";
  matrixHostName = "matrix.us.example.org";
  hermesHostName = "hermes.us.example.org";
  seafileHostName = "seafile.us.example.org";
  davHostName = "dav.us.example.org";
  hassHostName = "hass.us.example.org";
  matrixUpstream = "fd5a:715f:1edc:a706::27";
  hermesUpstream = "fd5a:715f:1edc:a706::29";
  seafileUpstream = "fd5a:715f:1edc:a706::2a";
  davUpstream = "fd5a:715f:1edc:a706::2c";
  hassUpstream = "fd5a:715f:1edc:a703::24";
  uiBindAddress = "fd5a:715f:1edc:a706::2b";
  frigateWebrtcUpstream = "fd5a:715f:1edc:a706::22";
}
"""
FLAKE_ARGS = ["--no-update-lock-file", "--extra-experimental-features", "nix-command flakes"]
HOSTS = (
    "matrix.us.example.org",
    "hermes.us.example.org",
    "seafile.us.example.org",
    "dav.us.example.org",
    "hass.us.example.org",
)


def stage():
    tmp = tempfile.TemporaryDirectory()
    shutil.copytree(NIX_DIR, tmp.name, dirs_exist_ok=True)
    (Path(tmp.name) / "site.nix").write_text(SITE)
    return tmp


@unittest.skipUnless(NIX, "nix not installed")
class NixosConfig(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = stage()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.attr = f"path:{cls.tmp.name}#nixosConfigurations.bunkerweb.config"
        probe = cls.run_nix("eval", "--json", f"{cls.attr}.virtualisation.oci-containers.backend")
        if probe.returncode != 0:
            raise unittest.SkipTest("cannot evaluate the flake (inputs not fetchable): " + probe.stderr[-300:])
        cls.containers = cls.eval("virtualisation.oci-containers.containers")
        cls.env = cls.containers["bunkerweb-scheduler"]["environment"]

    @staticmethod
    def run_nix(*args):
        return subprocess.run([NIX, *args, *FLAKE_ARGS], capture_output=True, text=True, timeout=1200)

    @classmethod
    def eval(cls, path):
        r = cls.run_nix("eval", "--json", f"{cls.attr}.{path}")
        if r.returncode != 0:
            raise AssertionError(r.stderr)
        return json.loads(r.stdout)

    def test_pinned_upstream_images(self):
        self.assertEqual(self.eval("virtualisation.oci-containers.backend"), "docker")
        self.assertEqual(
            {n: c["image"] for n, c in self.containers.items()},
            {
                "bunkerweb": "bunkerity/bunkerweb:1.6.17",
                "bunkerweb-scheduler": "bunkerity/bunkerweb-scheduler:1.6.17",
                "bunkerweb-ui": "bunkerity/bunkerweb-ui:1.6.17",
            },
        )

    def test_instance_publishes_http_and_https(self):
        self.assertEqual(self.containers["bunkerweb"]["ports"], ["80:8080", "443:8443"])
        self.assertEqual(self.containers["bunkerweb-scheduler"]["ports"], [])

    def test_real_client_address_without_proxy_protocol(self):
        e = self.env
        for k in ("USE_PROXY_PROTOCOL", "USE_REAL_IP", "REAL_IP_HEADER", "REAL_IP_FROM"):
            self.assertNotIn(k, e)  # Docker's DNAT keeps the real client address
        self.assertEqual(e["USE_IPV6"], "yes")

    def test_ipv6_only_guest(self):
        # IPv4 clients come in through the router's Jool NAT64, so the dmz needs no IPv4.
        net = 'systemd.network.networks."10-eth6"'
        self.assertEqual(self.eval(f"{net}.address"), [])
        self.assertEqual(self.eval(f"{net}.gateway"), [])

    def test_no_tunnel_left(self):
        self.assertNotIn("20-fly0", self.eval("systemd.network.netdevs"))
        self.assertNotIn("edge-ingress", self.eval("networking.firewall.extraCommands"))
        self.assertNotIn(
            "wireguard-tools",
            " ".join(p["name"] for p in self.eval("environment.systemPackages") if isinstance(p, dict) and "name" in p),
        )

    def test_webrtc_tcp_relay(self):
        # Kernel DNAT cannot reach go2rtc's IPv6-only listener from IPv4, so nginx relays.
        self.assertEqual(self.eval("networking.firewall.allowedTCPPorts"), [8555])
        stream = self.eval("services.nginx.streamConfig")
        for needle in ("listen [::]:8555;", "proxy_pass [fd5a:715f:1edc:a706::22]:8555;"):
            self.assertIn(needle, stream)
        self.assertNotIn("listen 8555;", stream)
        for c in self.containers.values():
            self.assertFalse(any("8555" in p for p in c["ports"]))

    def test_no_docker_socket_anywhere(self):
        for name, c in self.containers.items():
            for v in c["volumes"]:
                self.assertNotIn("docker.sock", v, name)
        self.assertEqual(self.containers["bunkerweb-scheduler"]["volumes"], ["bw-storage:/data"])

    def test_wildcard_dns01_certificate(self):
        e = self.env
        self.assertEqual(e["AUTO_LETS_ENCRYPT"], "yes")
        self.assertEqual(e["LETS_ENCRYPT_CHALLENGE"], "dns")
        self.assertEqual(e["LETS_ENCRYPT_DNS_PROVIDER"], "cloudflare")
        self.assertEqual(e["USE_LETS_ENCRYPT_WILDCARD"], "yes")
        self.assertEqual(e["LETS_ENCRYPT_DNS_CREDENTIAL_DECODE_BASE64"], "no")
        self.assertEqual(e["EMAIL_LETS_ENCRYPT"], "ops@example.org")
        # The token only ever arrives through the env file.
        self.assertNotIn("LETS_ENCRYPT_DNS_CREDENTIAL_ITEM", e)
        self.assertEqual(
            self.containers["bunkerweb-scheduler"]["environmentFiles"],
            ["/var/lib/bunkerweb/secrets/scheduler.env"],
        )

    def test_sites_and_upstreams(self):
        self.assertEqual(sorted(self.env["SERVER_NAME"].split()), sorted(HOSTS))
        self.assertEqual(self.env["MULTISITE"], "yes")
        self.assertEqual(self.env["DISABLE_DEFAULT_SERVER"], "yes")
        upstreams = {h: self.env[f"{h}_REVERSE_PROXY_HOST"] for h in HOSTS}
        self.assertEqual(
            upstreams,
            {
                "matrix.us.example.org": "http://[fd5a:715f:1edc:a706::27]",
                "hermes.us.example.org": "http://[fd5a:715f:1edc:a706::29]",
                "seafile.us.example.org": "http://[fd5a:715f:1edc:a706::2a]",
                "dav.us.example.org": "http://[fd5a:715f:1edc:a706::2c]",
                "hass.us.example.org": "http://[fd5a:715f:1edc:a703::24]:8123",
            },
        )
        for h in HOSTS:
            self.assertEqual(self.env[f"{h}_USE_REVERSE_PROXY"], "yes", h)
            self.assertEqual(self.env[f"{h}_MODSECURITY_SEC_RULE_ENGINE"], "DetectionOnly", h)

    def test_service_specific_tuning(self):
        e = self.env
        self.assertIn("PUT", e["matrix.us.example.org_ALLOWED_METHODS"].split("|"))
        self.assertEqual(e["matrix.us.example.org_MAX_CLIENT_SIZE"], "20m")
        self.assertEqual(e["hermes.us.example.org_REVERSE_PROXY_WS"], "yes")
        self.assertIn("PROPFIND", e["dav.us.example.org_ALLOWED_METHODS"].split("|"))
        self.assertIn("MKCALENDAR", e["dav.us.example.org_ALLOWED_METHODS"].split("|"))
        self.assertEqual(e["hass.us.example.org_REVERSE_PROXY_WS"], "yes")
        self.assertEqual(e["hass.us.example.org_REVERSE_PROXY_READ_TIMEOUT"], "3600s")
        self.assertEqual(e["seafile.us.example.org_MAX_CLIENT_SIZE"], "0")
        self.assertEqual(e["seafile.us.example.org_REVERSE_PROXY_URL_1"], "/seafhttp")
        self.assertEqual(e["seafile.us.example.org_REVERSE_PROXY_MODSECURITY_1"], "no")
        # gunicorn rejects X-Forwarded-Protocol: https next to X-Forwarded-Proto: https.
        for k in ("REVERSE_PROXY_HEADERS", "REVERSE_PROXY_HEADERS_1"):
            self.assertEqual(e[f"seafile.us.example.org_{k}"], 'X-Forwarded-Protocol ""')

    def test_api_reachable_only_from_the_private_bridge(self):
        wl = "127.0.0.0/8 10.110.0.0/24 fd00:b0b0:5e::/64"
        self.assertEqual(self.containers["bunkerweb"]["environment"]["API_WHITELIST_IP"], wl)
        self.assertEqual(self.env["API_WHITELIST_IP"], wl)
        script = self.eval('systemd.services."bunkerweb-docker-network".script')
        self.assertIn("--subnet 10.110.0.0/24 --subnet fd00:b0b0:5e::/64 bw-net", script)

    def test_pinned_dhcpv6_identity(self):
        dhcp = self.eval('systemd.network.networks."10-eth6".dhcpV6Config')
        self.assertEqual(dhcp["DUIDRawData"], "00:00:ab:11:62:75:6e:6b:65:72:00:6e")
        self.assertEqual(dhcp["IAID"], 0x62756E6B)
        self.assertEqual(bytes.fromhex("62756e6b6572").decode(), "bunker")

    def test_web_ui_is_lan_only_and_shares_the_database(self):
        ui = self.containers["bunkerweb-ui"]
        # Published on the edge's own ULA only: never the public 80/443, no router rule for 7000.
        self.assertEqual(ui["ports"], ["[fd5a:715f:1edc:a706::2b]:7000:7000"])
        self.assertEqual(ui["volumes"], ["bw-storage:/data"])  # same SQLite database as the scheduler
        self.assertEqual(ui["environmentFiles"], ["/var/lib/bunkerweb/secrets/ui.env"])
        self.assertNotIn("ADMIN_PASSWORD", ui["environment"])  # credentials only via the env file
        # Reachable through the IPv6 publish; the brackets matter (a bare "::" crashes the entrypoint).
        self.assertEqual(ui["environment"]["UI_LISTEN_ADDR"], "[::]")
        self.assertEqual(ui["environment"]["UI_LISTEN_PORT"], "7000")
        self.assertEqual(ui["dependsOn"], ["bunkerweb-scheduler"])
        for c in self.containers.values():
            self.assertFalse(any(":7000" in p and not p.startswith("[fd5a:") for p in c["ports"]))

    def test_units_wait_for_secrets_and_autostart(self):
        secrets = "/var/lib/bunkerweb/secrets"
        for n in self.containers:
            svc = f'systemd.services."docker-{n}"'
            self.assertEqual(self.eval(f"{svc}.wantedBy"), ["multi-user.target"], n)
            want = [f"{secrets}/scheduler.env"] + ([f"{secrets}/ui.env"] if n == "bunkerweb-ui" else [])
            self.assertEqual(self.eval(f"{svc}.unitConfig.ConditionPathExists"), want, n)
        self.assertFalse(self.eval("services.openssh.enable"))

    @unittest.skipUnless(os.environ.get("BUNKERWEB_NIX_BUILD"), "set BUNKERWEB_NIX_BUILD=1 to build the closure")
    def test_system_closure_builds(self):
        r = self.run_nix("build", "--no-link", f"{self.attr}.system.build.toplevel")
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
