"""Offline wiring checks for the seafile tenant: no hosts, no vault password, no Nix.

Run from the repo root: python3 -m unittest discover -s roles/tenant/seafile/tests
(needs PyYAML). Ansible's own templating is not exercised here; this guards the
cross-file invariants that are easy to break by hand: unique VMID/hostid/MAC, the pinned
DHCPv6 identity matching the router reservation, the build_template contract with
proxmox_lxc, mount paths agreeing between LXC and Nix, secrets confined to root-only
runtime env files, and no secret or real domain in the tree.
"""

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[4]
ROLE = ROOT / "roles/tenant/seafile"
NIX = ROLE / "files/nixos"
SECRET_VARS = ("db_password", "db_root_password", "jwt_private_key", "admin_email", "admin_password")


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def seafile_dhcp(prydwen):
    return next(s for s in prydwen["prydwen_uci_sections"] if s.get("name") == "host_seafile")


def config_nix():
    return (NIX / "configuration.nix").read_text()


def nix_string(name):
    return re.search(rf'^\s*{name} = "([^"]*)";', config_nix(), re.M).group(1)


def role_tasks():
    for f in sorted((ROLE / "tasks").glob("*.yml")):
        for task in yaml.safe_load(f.read_text()) or []:
            yield f.name, task


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
        dhcp = seafile_dhcp(load("host_vars/prydwen.yml"))["value"]
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

    def test_pinned_duid_and_iaid_match_router_reservation(self):
        nix = config_nix()
        raw = re.search(r'DUIDRawData = "([0-9a-f:]+)";', nix).group(1)
        iaid = int(re.search(r"IAID = (\d+);", nix).group(1))
        self.assertIn('DUIDType = "vendor";', nix)
        # DUIDType=vendor prepends the DUID-EN type 0x0002 to enterprise number + identifier.
        duid = "0002" + raw.replace(":", "")
        self.assertEqual(len(duid), 28)  # 14 bytes, the shape every other systemd guest has
        reserved = seafile_dhcp(load("host_vars/prydwen.yml"))["value"]["duid"]
        self.assertEqual(reserved, [f"{duid}%{iaid:08x}"])
        # And it is unique among the reservations (matrix/hermes pin their own).
        text = (ROOT / "host_vars/prydwen.yml").read_text()
        self.assertEqual(text.count(duid), 1)
        # Readable, like the others: "seafil" + vmid 109.
        self.assertEqual(bytes.fromhex(raw.split(":", 4)[4].replace(":", "")), b"seafil\x00\x6d")
        self.assertEqual(iaid.to_bytes(4, "big"), b"seaf")

    def test_follows_the_matrix_reference_architecture(self):
        cfg = load("host_vars/seafile.yml")["proxmox_lxc"]
        ref = load("host_vars/matrix.yml")["proxmox_lxc"]
        for key in ("template", "ostype", "nixos_path_shim", "unprivileged"):
            self.assertEqual(cfg[key], ref[key], key)
        self.assertEqual(cfg["template_role"], "seafile")
        self.assertNotIn("networkd_interfaces", cfg)  # eth6 addressing ships in the image
        self.assertIn("nesting=1", cfg["features"])
        # Same flake shape and pins as matrix: same input set, committed lock, same nixpkgs.
        self.assertTrue((NIX / "flake.lock").is_file())
        self.assertEqual(
            (NIX / "flake.lock").read_bytes(),
            (ROOT / "roles/tenant/matrix/files/nixos/flake.lock").read_bytes(),
        )
        flake = (NIX / "flake.nix").read_text()
        self.assertIn("nixosConfigurations.seafile", flake)
        self.assertIn("packages.${system}.proxmox-lxc", flake)
        self.assertIn("proxmox-lxc.nix", flake)

    def test_build_template_contract(self):
        tasks = yaml.safe_load((ROLE / "tasks/build_template.yml").read_text())
        text = (ROLE / "tasks/build_template.yml").read_text()
        fact = next(t for t in tasks if t["name"] == "Set the template filename")
        name = fact["ansible.builtin.set_fact"]["proxmox_lxc_built_template"]
        self.assertTrue(name.startswith("nixos-seafile_") and name.endswith("_amd64.tar.xz"), name)
        self.assertIn("--no-update-lock-file", text)
        self.assertIn("packages.x86_64-linux.proxmox-lxc", text)
        self.assertIn("site.nix", text)
        # Everything is built on the workstation and uploaded to the template cache.
        upload = next(t for t in tasks if t["name"] == "Upload the template to Proxmox")
        self.assertEqual(upload["ansible.builtin.copy"]["dest"], "/var/lib/vz/template/cache/{{ proxmox_lxc_built_template }}")
        # No secret variable is referenced by anything that feeds the image.
        for var in SECRET_VARS:
            self.assertNotIn(f"seafile_{var}", text)

    def test_rebuild_is_declarative_and_pinned(self):
        nixos = yaml.safe_load((ROLE / "tasks/nixos.yml").read_text())
        rebuild = next(t for t in nixos if t["name"] == "Apply the NixOS configuration")
        cmd = rebuild["ansible.builtin.shell"]["cmd"]
        self.assertIn("nixos-rebuild switch --flake /etc/nixos#seafile --no-update-lock-file", cmd)
        self.assertEqual(rebuild["changed_when"], "'CHANGED' in seafile_rebuild.stdout")

    def test_inventory_groups(self):
        inv = (ROOT / "inventory").read_text()
        docker = inv.split("[lxc_docker]")[1].split("[")[0].split()
        self.assertNotIn("seafile", docker)
        nixos = inv.split("[lxc_nixos]")[1].split()
        self.assertIn("seafile", nixos)
        self.assertEqual(inv.count("seafile ansible_host"), 1)

    def test_no_debian_leftovers(self):
        cfg = load("host_vars/seafile.yml")
        for key in cfg:
            self.assertFalse(key.startswith("docker_host_"), key)  # docker_host role no longer applies
        self.assertEqual(cfg["proxmox_lxc"]["template"], "nixos")
        for gone in ("tasks/seafile.yml", "tasks/backup.yml", "templates/Caddyfile.j2"):
            self.assertFalse((ROLE / gone).exists(), gone)
        for _, task in role_tasks():
            for module in task:
                self.assertFalse(module.startswith("community.docker."), module)
                self.assertNotIn("apt", module.split(".")[-1:])
        self.assertNotIn("seafile", load("group_vars/lxc_nixos.yml") or {})

    def test_mount_paths_agree_between_lxc_and_nix(self):
        lines = {c["key"]: c for c in load("host_vars/seafile.yml")["proxmox_lxc"]["config_lines"]}
        vars_ = load("roles/tenant/seafile/vars/main.yml")
        self.assertTrue(lines["mp0"]["value"].endswith(f"mp={vars_['seafile_data_dir']}"))
        self.assertTrue(lines["mp1"]["value"].endswith(f"mp={vars_['seafile_backup_dir']}"))
        self.assertTrue(lines["mp0"]["at_create"] and lines["mp1"]["at_create"])
        self.assertEqual(nix_string("dataDir"), vars_["seafile_data_dir"])
        self.assertEqual(nix_string("backupDir"), vars_["seafile_backup_dir"])
        self.assertEqual(nix_string("secretsDir"), vars_["seafile_secrets_dir"])
        self.assertIn('"${dataDir}:/shared"', config_nix())

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
        self.assertIn("seafile.us.example.org seafile.us.example.org:80;", conf)

    def test_site_nix_template_matches_what_nix_reads(self):
        template = (ROLE / "templates/site.nix.j2").read_text()
        defined = set(re.findall(r"^\s+(\w+) = ", template, re.M))
        used = set(re.findall(r"(?<![\w./])site\.(\w+)", config_nix()))
        self.assertEqual(defined, used)

    def test_secrets_come_from_vault_without_defaults(self):
        self.assertNotIn("password", (ROLE / "defaults/main.yml").read_text().lower())
        vars_ = load("roles/tenant/seafile/vars/main.yml")
        for name in SECRET_VARS:
            self.assertIn(f"vault_seafile_{name}", vars_[f"seafile_{name}"])

    def test_secrets_only_reach_root_only_runtime_env_files(self):
        secret_refs = re.compile(r"seafile_(" + "|".join(SECRET_VARS) + ")")
        users = {
            str(p.relative_to(ROLE))
            for p in ROLE.rglob("*")
            if p.is_file()
            and "tests" not in p.parts
            and "__pycache__" not in p.parts
            and p.name != "README.md"
            and secret_refs.search(p.read_text())
        }
        # vars: indirection from the vault; validate: strength checks; the two env templates.
        self.assertEqual(
            users,
            {"vars/main.yml", "tasks/validate.yml", "templates/mysql.env.j2", "templates/seafile.env.j2"},
        )
        # Nothing the flake tree / image / Nix store sees names a credential value.
        for p in [*NIX.iterdir(), ROLE / "templates/site.nix.j2"]:
            self.assertNotRegex(p.read_text(), r"vault_seafile|seafile_(" + "|".join(SECRET_VARS) + ")", p.name)
        installs = {
            t["name"]: t
            for f, t in role_tasks()
            if f == "secrets.yml" and "ansible.builtin.template" in t
        }
        self.assertEqual(len(installs), 2)
        for name, t in installs.items():
            tpl = t["ansible.builtin.template"]
            self.assertEqual((tpl["owner"], tpl["group"], tpl["mode"]), ("root", "root", "0400"), name)
            self.assertTrue(tpl["dest"].startswith("{{ seafile_secrets_dir }}/"), name)
            self.assertTrue(t["no_log"], name)
        directory = next(t for f, t in role_tasks() if f == "secrets.yml" and "ansible.builtin.file" in t)
        self.assertEqual(directory["ansible.builtin.file"]["mode"], "0700")

    def test_env_files_hold_exactly_the_credentials_nix_expects(self):
        env = {}
        for name in ("mysql", "seafile"):
            text = (ROLE / f"templates/{name}.env.j2").read_text()
            env[name] = set(re.findall(r"^([A-Z_]+)=", text, re.M))
        self.assertEqual(env["mysql"], {"MYSQL_ROOT_PASSWORD"})
        self.assertEqual(
            env["seafile"],
            {
                "SEAFILE_MYSQL_DB_PASSWORD",
                "INIT_SEAFILE_MYSQL_ROOT_PASSWORD",
                "INIT_SEAFILE_ADMIN_EMAIL",
                "INIT_SEAFILE_ADMIN_PASSWORD",
                "JWT_PRIVATE_KEY",
            },
        )
        # Credentials must not also be set inline in Nix (that would put them in the store).
        inline = set(re.findall(r"^\s+([A-Z_]+) = ", config_nix(), re.M))
        self.assertFalse(inline & (env["mysql"] | env["seafile"]), inline & (env["mysql"] | env["seafile"]))

    def test_validate_guards_secret_strength_and_env_file_safety(self):
        text = (ROLE / "tasks/validate.yml").read_text()
        for needle in ("length >= 16", "length >= 32", "length >= 12", "[\\r\\n]"):
            self.assertIn(needle, text)

    def test_images_are_pinned(self):
        d = load("roles/tenant/seafile/defaults/main.yml")
        self.assertRegex(str(d["seafile_version"]), r"^\d+\.\d+\.\d+$")
        self.assertEqual(
            (d["seafile_db_image"], d["seafile_redis_image"], d["seafile_caddy_image"]),
            ("mariadb:10.11", "redis:7", "caddy:2"),
        )
        for image in (d["seafile_db_image"], d["seafile_redis_image"], d["seafile_caddy_image"]):
            self.assertRegex(image, r":[\w.]+$")
            self.assertNotIn("latest", image)
        self.assertIn('"seafileltd/seafile-mc:${site.seafileVersion}"', config_nix())
        self.assertNotIn("latest", config_nix().replace("# ", ""))
        self.assertTrue(d["seafile_start_app"])

    def test_vault_variable_names_unchanged(self):
        vault_names = set(re.findall(r"vault_seafile_\w+", (ROLE / "vars/main.yml").read_text()))
        self.assertEqual(vault_names, {f"vault_seafile_{n}" for n in SECRET_VARS})

    def test_stack_is_started_after_the_rebuild_and_restarts_only_existing_stacks(self):
        main = [t["ansible.builtin.import_tasks"] for t in yaml.safe_load((ROLE / "tasks/main.yml").read_text())]
        self.assertEqual(main, ["validate.yml", "secrets.yml", "nixos.yml", "stack.yml"])
        stack = (ROLE / "tasks/stack.yml").read_text()
        self.assertIn("mountpoint -q {{ seafile_data_dir }}", stack)
        self.assertIn("mountpoint -q {{ seafile_backup_dir }}", stack)
        self.assertIn("seafile_start_app | bool", stack)
        self.assertIn("_before.stat.exists", stack)

    def test_no_real_domain_or_inline_secret_committed(self):
        # The only domains allowed in the new files are RFC 2606 placeholders.
        for path in [*ROLE.rglob("*"), ROOT / "host_vars/seafile.yml"]:
            if not path.is_file() or "__pycache__" in path.parts or path == Path(__file__):
                continue
            for host in re.findall(r"\b[\w-]+(?:\.[\w-]+)*\.(?:com|org|net|io|dev)\b", path.read_text()):
                self.assertRegex(
                    host,
                    r"(^|\.)example\.(org|com)$|^(manual|docs)\.seafile\.com$|^seafile\.us\.example\.org$|^github\.com$|^(api\.)?flakehub\.com$",
                    f"{path}: {host}",
                )


if __name__ == "__main__":
    unittest.main()
