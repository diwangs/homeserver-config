"""Offline wiring checks for the seafile tenant: no hosts, no vault password.

Run from the repo root: python3 -m unittest discover -s roles/tenant/seafile/tests
(needs PyYAML). Ansible's own templating is not exercised here; this guards the
cross-file invariants that are easy to break by hand (unique VMID/hostid/MAC, the
address, DDNS and proxy entries agreeing, and no secret or real domain in the tree).
"""

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[4]
ROLE = ROOT / "roles/tenant/seafile"


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def seafile_dhcp(prydwen):
    return next(s for s in prydwen["prydwen_uci_sections"] if s.get("name") == "host_seafile")


class SeafileWiring(unittest.TestCase):
    def test_vmid_unique(self):
        vmids = {}
        for f in (ROOT / "host_vars").glob("*.yml"):
            cfg = yaml.safe_load(f.read_text()).get("proxmox_lxc")
            if cfg:
                vmids.setdefault(cfg["vmid"], []).append(f.stem)
        self.assertEqual(vmids[109], ["seafile"])

    def test_hwaddr_matches_router_reservation_and_is_unique(self):
        cfg = load("host_vars/seafile.yml")["proxmox_lxc"]
        mac = re.search(r"hwaddr=([0-9A-F:]+)", cfg["netif"]["net6"]).group(1)
        prydwen = load("host_vars/prydwen.yml")
        dhcp = seafile_dhcp(prydwen)["value"]
        self.assertEqual(dhcp["mac"], [mac])
        text = "".join(p.read_text() for p in (ROOT / "host_vars").glob("*.yml"))
        self.assertEqual(text.upper().count(mac), 2)  # netif + dhcp host only

    def test_hostid_matches_inventory_and_is_unique(self):
        prydwen = load("host_vars/prydwen.yml")
        hostid = seafile_dhcp(prydwen)["value"]["hostid"]
        inv = (ROOT / "inventory").read_text()
        self.assertIn(f"seafile ansible_host=fd5a:715f:1edc:a706::{hostid}\n", inv)
        ids = [
            s["value"]["hostid"].lower()
            for s in prydwen["prydwen_uci_sections"]
            if s.get("config") == "dhcp" and "hostid" in s.get("value", {}) and s.get("type") == "host"
        ]
        self.assertEqual(ids.count(hostid), 1)

    def test_docker_ranges_do_not_overlap_nextcloud(self):
        seafile = load("host_vars/seafile.yml")["docker_host_ipvlan_network"]["iprange"]
        nextcloud = load("host_vars/nextcloud.yml")["docker_host_ipvlan_network"]["iprange"]
        self.assertNotEqual(seafile, nextcloud)
        self.assertTrue(seafile.startswith("fd5a:715f:1edc:a706::5"))

    def test_inventory_groups(self):
        inv = (ROOT / "inventory").read_text()
        docker = inv.split("[lxc_docker]")[1].split("[")[0].split()
        self.assertIn("seafile", docker)
        nixos = inv.split("[lxc_nixos]")[1].split()
        self.assertNotIn("seafile", nixos)

    def test_ddns_publishes_the_dmz_lease(self):
        prydwen = load("host_vars/prydwen.yml")
        svc = next(s for s in prydwen["prydwen_uci_sections"] if s.get("name") == "seafile" and s.get("config") == "ddns")
        self.assertEqual(svc["find"]["lookup_host"], "{{ seafile_hostname }}")
        self.assertIn("prydwen_dmz_device", svc["value"]["ip_script"])
        self.assertIn("hostname='seafile'", svc["value"]["ip_script"])
        self.assertTrue(svc["secret"])
        self.assertEqual(svc["value"]["domain"], "seafile.us@{{ public_domain }}")

    def test_hostname_derives_from_vaulted_domain(self):
        v = load("group_vars/all/vars.yml")
        self.assertEqual(v["seafile_hostname"], "seafile.us.{{ public_domain }}")

    def test_proxy_template_routes_seafile(self):
        conf = (ROOT / "extern/ipv4-proxy/nginx.conf.example").read_text()
        self.assertIn("seafile.us.example.org   seafile.us.example.org:443;", conf)

    def test_secrets_come_from_vault_without_defaults(self):
        self.assertNotIn("password", (ROLE / "defaults/main.yml").read_text().lower())
        vars_ = load("roles/tenant/seafile/vars/main.yml")
        for name in ("db_password", "db_root_password", "jwt_private_key", "admin_email", "admin_password"):
            self.assertIn(f"vault_seafile_{name}", vars_[f"seafile_{name}"])

    def test_image_is_pinned(self):
        version = load("roles/tenant/seafile/defaults/main.yml")["seafile_version"]
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")
        tasks = (ROLE / "tasks/seafile.yml").read_text()
        self.assertNotIn("latest", tasks.replace("# ", ""))
        self.assertIn('seafileltd/seafile-mc:{{ seafile_version }}', tasks)

    def test_secret_bearing_tasks_are_no_log(self):
        for name in ("seafile.yml", "validate.yml"):
            for task in load(f"roles/tenant/seafile/tasks/{name}"):
                body = yaml.safe_dump(task)
                if re.search(r"seafile_(db|jwt|admin)\w*password|jwt_private_key", body):
                    self.assertTrue(task.get("no_log"), task["name"])

    def test_only_caddy_publishes_ports(self):
        for task in load("roles/tenant/seafile/tasks/seafile.yml"):
            c = task.get("community.docker.docker_container")
            if c and c["name"] != "seafile-caddy":
                self.assertNotIn("ports", c, c["name"])

    def test_no_real_domain_or_inline_secret_committed(self):
        # The only domains allowed in the new files are RFC 2606 placeholders.
        for path in [*ROLE.rglob("*"), ROOT / "host_vars/seafile.yml"]:
            if not path.is_file() or path.suffix == ".pyc" or path == Path(__file__):
                continue
            for host in re.findall(r"\b[\w-]+(?:\.[\w-]+)*\.(?:com|org|net|io|dev)\b", path.read_text()):
                self.assertRegex(host, r"(^|\.)example\.(org|com)$|^(manual|docs)\.seafile\.com$|^seafile\.us\.example\.org$|^github\.com$", f"{path}: {host}")


if __name__ == "__main__":
    unittest.main()
