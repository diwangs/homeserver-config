"""Nix evaluation checks of the hass (Home Assistant) NixOS configuration.

Run from the repo root: python3 -m unittest discover -s roles/tenant/hass/tests

Evaluates (does not build) the flake the same way build_template.yml and the in-guest
`nixos-rebuild` do — a `path:` copy of files/nixos with a rendered site.nix beside it
and the committed flake.lock, with --no-update-lock-file — and asserts on the resulting
option values. Skipped when `nix` is missing or the locked inputs cannot be fetched.
"""

import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROLE = Path(__file__).resolve().parents[1]
NIX_DIR = ROLE / "files/nixos"
NIX = shutil.which("nix")

IMAGE = "ghcr.io/home-assistant/home-assistant:2026.11.2@sha256:" + "0" * 64
SITE = """{
  hostName = "hass.us.example.org";
  edgeAddress = "fd5a:715f:1edc:a706::2b";
  lanPrefix = "fd5a:715f:1edc:a700::/56";
  lanPrefix4 = "192.168.0.0/16";
  image = "%s";
  extraTcpPorts = [ 21063 ];
  extraUdpPorts = [ 5683 ];
}
""" % IMAGE
FLAKE_ARGS = ["--no-update-lock-file", "--extra-experimental-features", "nix-command flakes"]


def stage():
    tmp = tempfile.TemporaryDirectory()
    shutil.copytree(NIX_DIR, tmp.name, dirs_exist_ok=True)
    (Path(tmp.name) / "site.nix").write_text(SITE)
    return tmp


def role_var(name):
    text = (ROLE / "vars/main.yml").read_text()
    return re.search(rf"^{name}: (\S+)$", text, re.M).group(1)


@unittest.skipUnless(NIX, "nix not installed")
class NixosConfig(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = stage()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.attr = f"path:{cls.tmp.name}#nixosConfigurations.hass.config"
        probe = cls.run_nix("eval", "--json", f"{cls.attr}.virtualisation.oci-containers.backend")
        if probe.returncode != 0:
            raise unittest.SkipTest("cannot evaluate the flake (inputs not fetchable): " + probe.stderr[-300:])
        cls.container = cls.eval("virtualisation.oci-containers.containers.homeassistant")

    @staticmethod
    def run_nix(*args):
        return subprocess.run([NIX, *args, *FLAKE_ARGS], capture_output=True, text=True, timeout=1200)

    @classmethod
    def eval(cls, option):
        r = cls.run_nix("eval", "--json", f"{cls.attr}.{option}")
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)

    def test_pinned_image(self):
        self.assertEqual(self.container["image"], IMAGE)

    def test_host_network_not_privileged(self):
        opts = self.container["extraOptions"]
        self.assertIn("--network=host", opts)
        self.assertFalse(any(o.startswith("--privileged") for o in opts))
        self.assertEqual(self.container["ports"], [])

    def test_config_on_the_rootfs(self):
        self.assertEqual(self.container["volumes"], [role_var("hass_config_dir") + ":/config"])

    def test_no_credentials_in_the_container_definition(self):
        self.assertFalse(self.container.get("environmentFiles"))
        self.assertEqual(set(self.container["environment"]), {"TZ"})

    def test_unit_waits_for_the_migration(self):
        unit_config = self.eval('systemd.services."docker-homeassistant".unitConfig')
        pre = self.eval('systemd.services."docker-homeassistant".serviceConfig.ExecStartPre')
        self.assertEqual(unit_config["ConditionPathExists"], role_var("hass_migrated_marker"))
        self.assertTrue(any("hass-require-config" in c for c in pre))

    def test_http_open_to_the_edge_and_the_lan_only(self):
        fw = self.eval("networking.firewall.extraCommands")
        self.assertIn("ip6tables -A nixos-fw -p tcp --dport 8123 -s fd5a:715f:1edc:a706::2b", fw)
        self.assertIn("ip6tables -A nixos-fw -p tcp --dport 8123 -s fd5a:715f:1edc:a700::/56", fw)
        self.assertIn("iptables -A nixos-fw -p tcp --dport 8123 -s 192.168.0.0/16", fw)
        self.assertIn("--dport 21063 -s fd5a:715f:1edc:a700::/56", fw)
        self.assertIn("-p udp --dport 5683 -s 192.168.0.0/16", fw)
        self.assertEqual(self.eval("networking.firewall.allowedTCPPorts"), [])

    def test_pinned_dhcp_identity(self):
        net = 'systemd.network.networks."10-eth3"'
        v6 = self.eval(f"{net}.dhcpV6Config")
        self.assertEqual(v6["DUIDRawData"], "00:00:ab:11:68:61:73:73:6c:78:00:71")
        self.assertEqual(v6["IAID"], 0x68617373)
        self.assertEqual(self.eval(f"{net}.dhcpV4Config")["ClientIdentifier"], "mac")
        self.assertEqual(self.eval(f"{net}.networkConfig")["DHCP"], "yes")


if __name__ == "__main__":
    unittest.main()
