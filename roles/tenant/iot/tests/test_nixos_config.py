"""Nix evaluation checks of the iot (Zigbee/Thread/MQTT) NixOS configuration.

Run from the repo root: python3 -m unittest discover -s roles/tenant/iot/tests

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

RADIO = "/dev/serial/by-id/usb-Nabu_Casa_SkyConnect_v1.0_0123456789-if00-port0"
SITE = """{
  multipanImage = "homeassistant/amd64-addon-silabs-multiprotocol:2.4.6@sha256:%s";
  multipanPrivileged = false;
  radioDevice = "%s";
  radioBaudrate = 460800;
  radioFlowControl = true;
  hassAddress = "fd5a:715f:1edc:a703::24";
  backendPrefix = "fd5a:715f:1edc:a703::/64";
  lanPrefix = "fd5a:715f:1edc:a700::/56";
  zigbee = {
    panId = 6754;
    extPanId = [ 221 221 221 221 221 221 221 221 ];
    channel = 15;
  };
  z2mExtraSettings = builtins.fromJSON "{\\"availability\\": {\\"enabled\\": true}, \\"mqtt\\": {\\"server\\": \\"mqtt://elsewhere\\"}}";
}
""" % ("0" * 64, RADIO)
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
        cls.attr = f"path:{cls.tmp.name}#nixosConfigurations.iot.config"
        probe = cls.run_nix("eval", "--json", f"{cls.attr}.virtualisation.oci-containers.backend")
        if probe.returncode != 0:
            raise unittest.SkipTest("cannot evaluate the flake (inputs not fetchable): " + probe.stderr[-300:])
        cls.container = cls.eval("virtualisation.oci-containers.containers.multipan")
        cls.z2m = cls.eval("services.zigbee2mqtt.settings")

    @staticmethod
    def run_nix(*args):
        return subprocess.run([NIX, *args, *FLAKE_ARGS], capture_output=True, text=True, timeout=1200)

    @classmethod
    def eval(cls, option):
        r = cls.run_nix("eval", "--json", f"{cls.attr}.{option}")
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)

    # ── radio stack ──────────────────────────────────────────────────────────
    def test_pinned_image_with_own_entrypoint(self):
        self.assertTrue(self.container["image"].endswith("@sha256:" + "0" * 64))
        self.assertEqual(self.container["entrypoint"], "/bin/bash")
        self.assertEqual(self.container["cmd"], ["/opt/iot/multipan-run.sh"])

    def test_host_network_and_add_on_grants(self):
        opts = self.container["extraOptions"]
        self.assertIn("--network=host", opts)
        self.assertIn(f"--device={RADIO}", opts)
        self.assertIn("--device=/dev/net/tun", opts)
        for cap in ("NET_ADMIN", "NET_RAW", "IPC_LOCK"):
            self.assertIn(f"--cap-add={cap}", opts)
        self.assertNotIn("--privileged", opts)

    def test_state_mounts(self):
        vols = self.container["volumes"]
        self.assertIn(role_var("iot_zigbeed_dir") + ":/data/zigbeed", vols)
        self.assertIn(role_var("iot_thread_dir") + ":/var/lib/thread", vols)
        self.assertTrue(any(v.endswith(":/usr/local/etc/cpcd.conf:ro") for v in vols))

    def test_no_credentials_in_the_container_definition(self):
        self.assertEqual(set(self.container["environment"]), {"BACKBONE_IF", "OTBR_LOG_LEVEL"})
        self.assertFalse(self.container.get("environmentFiles"))

    def test_docker_leaves_forwarding_alone(self):
        daemon = self.eval("virtualisation.docker.daemon.settings")
        self.assertFalse(daemon["iptables"])
        self.assertFalse(daemon["ip6tables"])
        self.assertEqual(daemon["bridge"], "none")
        self.assertEqual(self.eval('boot.kernel.sysctl."net.ipv6.conf.all.forwarding"'), 1)

    # ── never start without the migrated network ─────────────────────────────
    def test_zigbee_units_wait_for_the_migration(self):
        marker = role_var("iot_migrated_marker")
        multipan = self.eval('systemd.services."docker-multipan".unitConfig')
        z2m = self.eval("systemd.services.zigbee2mqtt.unitConfig")
        self.assertEqual(multipan["ConditionPathExists"], marker)
        self.assertIn(marker, z2m["ConditionPathExists"])
        self.assertIn(role_var("iot_z2m_dir") + "/secret.yaml", z2m["ConditionPathExists"])
        pre = self.eval('systemd.services."docker-multipan".serviceConfig.ExecStartPre')
        self.assertTrue(any("iot-require-zigbeed-state" in c for c in pre))

    # ── Zigbee2MQTT ──────────────────────────────────────────────────────────
    def test_z2m_keeps_the_ezsp_driver_on_loopback(self):
        self.assertEqual(self.z2m["serial"], {"adapter": "ezsp", "port": "tcp://127.0.0.1:9999"})

    def test_z2m_network_identity_from_site(self):
        adv = self.z2m["advanced"]
        self.assertEqual(adv["network_key"], "!secret network_key")
        self.assertEqual(adv["pan_id"], 6754)
        self.assertEqual(adv["ext_pan_id"], [221] * 8)
        self.assertEqual(adv["channel"], 15)

    def test_z2m_secrets_are_references(self):
        self.assertEqual(self.z2m["mqtt"]["password"], "!secret mqtt_password")
        self.assertEqual(self.z2m["frontend"]["auth_token"], "!secret frontend_token")

    def test_extra_settings_merge_under_managed_ones(self):
        self.assertEqual(self.z2m["availability"], {"enabled": True})
        self.assertEqual(self.z2m["mqtt"]["server"], "mqtt://localhost:1883")

    # ── broker and firewall ──────────────────────────────────────────────────
    def test_broker_users_read_password_files(self):
        users = self.eval("services.mosquitto.listeners")[0]["users"]
        self.assertEqual(set(users), {"z2m", "hass", "frigate"})
        for name, user in users.items():
            self.assertEqual(user["passwordFile"], role_var("iot_secrets_dir") + f"/mqtt-{name}")
            self.assertIsNone(user["password"])

    def test_firewall(self):
        fw = self.eval("networking.firewall.extraCommands")
        self.assertIn("--dport 1883 -s fd5a:715f:1edc:a703::/64", fw)
        self.assertIn("--dport 8080 -s fd5a:715f:1edc:a700::/56", fw)
        self.assertIn("--dport 8081 -s fd5a:715f:1edc:a703::24", fw)
        self.assertNotIn("9999", fw)
        self.assertIn("wpan0", self.eval("networking.firewall.trustedInterfaces"))

    def test_whole_system_evaluates(self):
        # Forces every module assertion, not just the options above.
        r = self.run_nix("eval", "--raw", f"{self.attr}.system.build.toplevel.drvPath")
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])

    def test_pinned_dhcpv6_identity(self):
        net = self.eval('systemd.network.networks."10-eth3".dhcpV6Config')
        self.assertEqual(net["DUIDRawData"], "00:00:ab:11:69:6f:74:6c:78:63:00:70")
        self.assertEqual(net["IAID"], 0x696F746C)


if __name__ == "__main__":
    unittest.main()
