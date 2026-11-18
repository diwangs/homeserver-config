"""Nix evaluation checks of the seafile NixOS configuration.

Run from the repo root: python3 -m unittest discover -s roles/tenant/seafile/tests

Evaluates (does not build) the flake the same way build_template.yml and the in-guest
`nixos-rebuild` do — a `path:` copy of files/nixos with a rendered site.nix beside it
and the committed flake.lock, with --no-update-lock-file — and asserts on the resulting
option values. Skipped when `nix` is missing or the locked inputs cannot be fetched
(first run needs network, or a populated /nix/store). Set SEAFILE_NIX_BUILD=1 to also
build the system closure, which runs shellcheck on the wrapped scripts.
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

# What templates/site.nix.j2 renders to, with placeholder values (and a sentinel that
# must never be reachable from Nix, see test_no_credentials_in_units).
SITE = """{
  hostName = "seafile.us.example.org";
  acmeEmail = "ops@example.org";
  seafileVersion = "13.0.29";
  dbImage = "mariadb:10.11";
  redisImage = "redis:7";
  caddyImage = "caddy:2";
  dbUsername = "seafile";
  timeZone = "America/New_York";
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
        cls.attr = f"path:{cls.tmp.name}#nixosConfigurations.seafile.config"
        probe = cls.run_nix("eval", "--json", f"{cls.attr}.virtualisation.oci-containers.backend")
        if probe.returncode != 0:
            raise unittest.SkipTest("cannot evaluate the flake (inputs not fetchable): " + probe.stderr[-300:])
        cls.containers = cls.eval("virtualisation.oci-containers.containers")

    @staticmethod
    def run_nix(*args):
        return subprocess.run([NIX, *args, *FLAKE_ARGS], capture_output=True, text=True, timeout=1200)

    @classmethod
    def eval(cls, path, attr=None):
        r = cls.run_nix("eval", "--json", f"{attr or cls.attr}.{path}")
        if r.returncode != 0:
            raise AssertionError(r.stderr)
        return json.loads(r.stdout)

    def test_docker_backend_and_four_containers(self):
        self.assertEqual(self.eval("virtualisation.oci-containers.backend"), "docker")
        self.assertEqual(set(self.containers), {"seafile-mysql", "seafile-redis", "seafile", "seafile-caddy"})

    def test_images_are_pinned(self):
        images = {n: c["image"] for n, c in self.containers.items()}
        self.assertEqual(
            images,
            {
                "seafile-mysql": "mariadb:10.11",
                "seafile-redis": "redis:7",
                "seafile": "seafileltd/seafile-mc:13.0.29",
                "seafile-caddy": "caddy:2",
            },
        )
        for c in self.containers.values():
            self.assertEqual(c["pull"], "missing")  # a re-pull never moves a pinned tag

    def test_private_network_and_only_caddy_publishes_ports(self):
        for name, c in self.containers.items():
            self.assertEqual(c["networks"], ["seafile-net"], name)
            if name != "seafile-caddy":
                self.assertEqual(c["ports"], [], name)  # database and cache are not public
        self.assertEqual(self.containers["seafile-caddy"]["ports"], ["80:80", "443:443"])
        self.assertEqual(self.eval("networking.firewall.allowedTCPPorts"), [80, 443])

    def test_dependencies_and_health(self):
        self.assertEqual(sorted(self.containers["seafile"]["dependsOn"]), ["seafile-mysql", "seafile-redis"])
        self.assertEqual(self.containers["seafile-caddy"]["dependsOn"], ["seafile"])
        db = " ".join(self.containers["seafile-mysql"]["extraOptions"])
        self.assertIn("--health-cmd=/usr/local/bin/healthcheck.sh --connect --mariadbupgrade --innodb_initialized", db)
        self.assertIn("--health-start-period=30s", db)
        self.assertIn("--health-cmd=curl -f http://localhost:80", " ".join(self.containers["seafile"]["extraOptions"]))
        unit = self.unit("docker-seafile.service")
        self.assertIn("seafile-wait-healthy seafile-mysql", unit)  # compose's service_healthy
        self.assertIn("seafile-require-mount /mnt/seafile", unit)  # mount guard
        for line in ("Requires=", "After="):
            deps = next(x for x in unit.splitlines() if x.startswith(line))
            self.assertIn("docker-seafile-mysql.service", deps)
            self.assertIn("docker-seafile-redis.service", deps)
            self.assertIn("seafile-docker-network.service", deps)

    def test_storage_semantics_unchanged(self):
        self.assertEqual(self.containers["seafile"]["volumes"], ["/mnt/seafile:/shared"])
        self.assertEqual(self.containers["seafile-mysql"]["volumes"], ["seafile_db:/var/lib/mysql"])
        caddy = self.containers["seafile-caddy"]["volumes"]
        self.assertIn("seafile_caddy_data:/data", caddy)
        self.assertTrue(any(v.endswith("-Caddyfile:/etc/caddy/Caddyfile:ro") for v in caddy))

    def test_upstream_environment_preserved(self):
        env = self.containers["seafile"]["environment"]
        for key, value in {
            "SEAFILE_MYSQL_DB_HOST": "seafile-mysql",
            "SEAFILE_SERVER_HOSTNAME": "seafile.us.example.org",
            "SEAFILE_SERVER_PROTOCOL": "https",
            "SEAFILE_LOG_TO_STDOUT": "true",
            "ENABLE_SEADOC": "false",
            "CACHE_PROVIDER": "redis",
            "REDIS_HOST": "seafile-redis",
            "REDIS_PASSWORD": "",
            "NON_ROOT": "false",
        }.items():
            self.assertEqual(env[key], value, key)

    def test_no_credentials_in_units_or_environment(self):
        for name, c in self.containers.items():
            # Credentials come only from root-only runtime files, never the store.
            for f in c["environmentFiles"]:
                self.assertTrue(f.startswith("/var/lib/seafile/secrets/"), f)
                self.assertFalse(f.startswith("/nix/store"), f)
            for key, value in c["environment"].items():
                if any(w in key for w in ("PASSWORD", "JWT", "SECRET", "KEY")):
                    self.assertEqual(value, "", f"{name}.{key}")
        self.assertEqual(self.containers["seafile-mysql"]["environmentFiles"], ["/var/lib/seafile/secrets/mysql.env"])
        self.assertEqual(self.containers["seafile"]["environmentFiles"], ["/var/lib/seafile/secrets/seafile.env"])
        for svc in ("docker-seafile-mysql", "docker-seafile"):
            unit = self.unit(f"{svc}.service")
            run = self.eval(f'systemd.services."{svc}".script')
            self.assertIn("--env-file /var/lib/seafile/secrets/", run)
            self.assertIn("ConditionPathExists=/var/lib/seafile/secrets/", unit)
            for leak in ("MYSQL_ROOT_PASSWORD", "JWT_PRIVATE_KEY", "INIT_SEAFILE_ADMIN_PASSWORD", "SEAFILE_MYSQL_DB_PASSWORD"):
                self.assertNotIn(leak, unit)
                self.assertNotIn(leak, run)
        self.assertEqual(self.eval("systemd.tmpfiles.rules").count("d /var/lib/seafile/secrets 0700 root root -"), 1)

    def test_docker_daemon_and_log_rotation(self):
        s = self.eval("virtualisation.docker.daemon.settings")
        self.assertTrue(s["ip6tables"])
        self.assertEqual(s["default-network-opts"]["bridge"]["com.docker.network.enable_ipv6"], "true")
        self.assertEqual(s["log-driver"], "json-file")
        self.assertEqual(s["log-opts"], {"max-size": "50m", "max-file": "3"})
        for c in self.containers.values():
            self.assertEqual(c["log-driver"], "json-file")
        net = self.eval('systemd.services."seafile-docker-network".script')
        self.assertIn("docker network create --driver bridge --ipv6 --subnet fd00:5ea4:11::/64 seafile-net", net)

    def test_pinned_dhcpv6_identity(self):
        net = 'systemd.network.networks."10-eth6"'
        self.assertEqual(self.eval(f"{net}.matchConfig.Name"), "eth6")
        self.assertEqual(self.eval(f"{net}.networkConfig.DHCP"), "ipv6")
        self.assertEqual(
            self.eval(f"{net}.dhcpV6Config"),
            {"DUIDType": "vendor", "DUIDRawData": "00:00:ab:11:73:65:61:66:69:6c:00:6d", "IAID": 1936023910},
        )
        self.assertFalse(self.eval("services.openssh.enable"))

    def test_nightly_dump_timer(self):
        timer = self.eval('systemd.timers."seafile-db-dump".timerConfig')
        self.assertEqual(timer["OnCalendar"], "*-*-* 02:30:00")
        self.assertEqual(timer["RandomizedDelaySec"], "15m")
        self.assertTrue(timer["Persistent"])
        svc = self.eval('systemd.services."seafile-db-dump".environment')
        self.assertEqual(svc["SEAFILE_BACKUP_DIR"], "/mnt/seafile-backup")
        self.assertEqual(svc["SEAFILE_BACKUP_KEEP"], "14")

    def test_all_containers_autostart(self):
        names = ("seafile-mysql", "seafile-redis", "seafile", "seafile-caddy")
        self.assertEqual(sorted(self.containers), sorted(names))
        for n in names:
            self.assertEqual(
                self.eval(f'systemd.services."docker-{n}".wantedBy'), ["multi-user.target"], n
            )

    def unit(self, name):
        return self.eval(f'systemd.units."{name}".text')

    @unittest.skipUnless(os.environ.get("SEAFILE_NIX_BUILD"), "set SEAFILE_NIX_BUILD=1 to build the closure")
    def test_system_closure_builds(self):
        r = self.run_nix("build", "--no-link", f"{self.attr}.system.build.toplevel")
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
