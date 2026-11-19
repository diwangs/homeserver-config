"""Nix evaluation checks of the dav (Radicale) NixOS configuration.

Run from the repo root: python3 -m unittest discover -s roles/tenant/dav/tests

Evaluates (does not build) the flake the same way build_template.yml and the in-guest
`nixos-rebuild` do — a `path:` copy of files/nixos with a rendered site.nix beside it
and the committed flake.lock, with --no-update-lock-file — and asserts on the resulting
option values. Skipped when `nix` is missing or the locked inputs cannot be fetched.
"""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROLE = Path(__file__).resolve().parents[1]
NIX_DIR = ROLE / "files/nixos"
NIX = shutil.which("nix")

SITE = """{
  hostName = "dav.us.example.org";
  edgeAddress = "fd5a:715f:1edc:a706::2b";
  radicaleVersion = "3.9.2";
}
"""
FLAKE_ARGS = ["--no-update-lock-file", "--extra-experimental-features", "nix-command flakes"]


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
        cls.attr = f"path:{cls.tmp.name}#nixosConfigurations.dav.config"
        probe = cls.run_nix("eval", "--json", f"{cls.attr}.virtualisation.oci-containers.backend")
        if probe.returncode != 0:
            raise unittest.SkipTest("cannot evaluate the flake (inputs not fetchable): " + probe.stderr[-300:])
        cls.container = cls.eval("virtualisation.oci-containers.containers.radicale")

    @staticmethod
    def run_nix(*args):
        return subprocess.run([NIX, *args, *FLAKE_ARGS], capture_output=True, text=True, timeout=1200)

    @classmethod
    def eval(cls, option):
        r = cls.run_nix("eval", "--json", f"{cls.attr}.{option}")
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)

    def test_pinned_upstream_image(self):
        self.assertEqual(self.container["image"], "ghcr.io/kozea/radicale:3.9.2")

    def test_only_loopback_publish(self):
        self.assertEqual(self.container["ports"], ["127.0.0.1:5232:5232"])

    def test_state_and_secret_mounts(self):
        vols = self.container["volumes"]
        self.assertIn("/mnt/radicale:/var/lib/radicale", vols)
        self.assertIn("/var/lib/dav/secrets/users:/etc/radicale/users:ro", vols)

    def test_no_credentials_in_the_container_definition(self):
        self.assertNotIn("environment", {k for k, v in self.container.items() if v})
        self.assertFalse(self.container.get("environmentFiles"))

    def test_unit_waits_for_users_file_and_mount(self):
        unit_config = self.eval('systemd.services."docker-radicale".unitConfig')
        pre = self.eval('systemd.services."docker-radicale".serviceConfig.ExecStartPre')
        self.assertEqual(unit_config["ConditionPathExists"], "/var/lib/dav/secrets/users")
        self.assertTrue(any("dav-require-mount /mnt/radicale" in c for c in pre))

    def test_origin_open_to_the_edge_only(self):
        fw = self.eval("networking.firewall.extraCommands")
        self.assertIn("--dport 80 -s fd5a:715f:1edc:a706::2b", fw)

    def test_pinned_dhcpv6_identity(self):
        net = self.eval('systemd.network.networks."10-eth6".dhcpV6Config')
        self.assertEqual(net["DUIDRawData"], "00:00:ab:11:72:61:64:69:63:61:00:6f")
        self.assertEqual(net["IAID"], 0x72616469)


if __name__ == "__main__":
    unittest.main()
