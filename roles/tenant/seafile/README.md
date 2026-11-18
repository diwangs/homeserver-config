# Seafile

> Hostnames below use `example.org` for the hosting zone (`vault_public_domain`); the
> real value is in `group_vars/all/vault.yml`. The role never names it:
> `seafile_hostname` is `seafile.us.{{ public_domain }}` (`group_vars/all/vars.yml`).

Seafile Community Edition on LXC 109, in the dmz (VLAN 6), publicly reachable at
`https://seafile.us.example.org`. Official upstream image
`seafileltd/seafile-mc`, pinned by `seafile_version` in `defaults/main.yml`
(13.0.29 at the time of writing; the floating `13.0-latest` is deliberately not used).

| | |
|---|---|
| vmid / hostname | 109 / `seafile` (unprivileged, `nesting=1`) |
| Address | `fd5a:715f:1edc:a706::2a` (dmz, DHCPv6 reservation) |
| Public name | `seafile.us.example.org` — AAAA via router ddns, A via the Fly IPv4 proxy |
| Ports | 443 (HTTPS), 80 (ACME + redirect) |
| Guest OS | NixOS (like `matrix`); the application runs as Docker containers declared with `virtualisation.oci-containers` |

## This guest is NixOS

It follows the `matrix` tenant's architecture (see `roles/tenant/matrix/README.md`):

- **The image is the configuration.** `files/nixos/` holds the flake and its committed
  `flake.lock` (the same nixpkgs / nixos-generators pins as matrix). `tasks/build_template.yml`
  builds the LXC template from it on the workstation (Proxmox has no Nix) and uploads it to
  `local:vztmpl`; `host_vars/seafile.yml` selects it with `template: nixos` /
  `template_role: seafile`, and `proxmox_lxc` sets `proxmox_lxc_built_template`.
- **There is no `playbooks/init_tenant.yml` stage.** `roles/common/docker_host` no longer applies
  (the guest left the `lxc_docker` inventory group for `lxc_nixos`); Docker, the bridge network and
  the containers are all in `configuration.nix`. In-guest work is `tasks/main.yml` via
  `playbooks/configure.yml`: install the runtime credentials, copy the flake to `/etc/nixos`,
  `nixos-rebuild switch --flake /etc/nixos#seafile --no-update-lock-file`, start the stack.
- **The dist-upgrade tooling does not apply** (`playbooks/upgrade_lxc_dist.yml` targets Debian guests).
  Upgrade nixpkgs by bumping `flake.lock`, Seafile by bumping `seafile_version`, and re-running
  `playbooks/configure.yml`.
- `group_vars/lxc_nixos.yml` pins `ansible_python_interpreter` to the system profile, and the
  `nixos_path_shim` makes `pct exec` find `nixos-rebuild`.

`site.nix` (gitignored, rendered from `templates/site.nix.j2` into both the build directory and
`/etc/nixos`) carries only the public hostname, the ACME contact and the image pins. **It holds no
secret**: anything a Nix expression sees ends up in the world-readable `/nix/store` and in the image.

### nixpkgs pinning

`flake.nix` tracks FlakeHub's newest-unstable selector, but the exact revision is pinned by the
committed `flake.lock`, and both the image build and `nixos-rebuild` pass `--no-update-lock-file`.
Upgrade deliberately:

~~~sh
nix flake update --flake roles/tenant/seafile/files/nixos
ansible-playbook playbooks/configure.yml --limit seafile
~~~

## Stack

Follows upstream's `docker/ce` compose files (`.env`, `seafile-server.yml`, `caddy.yml`) at the
pinned version, as `virtualisation.oci-containers` (Docker backend) units on the `seafile-net`
bridge (IPv6 subnet `fd00:5ea4:11::/64`, created by `seafile-docker-network.service`):

| Container / unit | Image | Notes |
|---|---|---|
| `seafile-mysql` / `docker-seafile-mysql` | `mariadb:10.11` | Seafile 13.0's documented DB; named volume `seafile_db` on the Optane rootfs; Docker healthcheck |
| `seafile-redis` / `docker-seafile-redis` | `redis:7` | Cache (`CACHE_PROVIDER=redis`, the 13.0 default); no password, no published port, no persistence — same as upstream |
| `seafile` / `docker-seafile` | `seafileltd/seafile-mc:<seafile_version>` | Seahub + Go fileserver; `/shared` = ZFS (`/mnt/seafile`) |
| `seafile-caddy` / `docker-seafile-caddy` | `caddy:2` | TLS termination, the only container with published ports (80, 443) |

Dependencies and health, which compose expresses with `depends_on: service_healthy` and systemd
orders only by "started": `docker-seafile` `Requires=` the database, cache and network units, and its
`ExecStartPre` runs `seafile-wait-healthy seafile-mysql` (up to 10 minutes) after the mount guard.
`docker-seafile-caddy` requires `docker-seafile`. Containers restart on failure (systemd
`Restart=on-failure`, the old `unless-stopped`); `docker logs <name>` works as before.

Guards:

- **Mounts**: `docker-seafile` refuses to start unless `/mnt/seafile` is a mountpoint (Docker would
  otherwise silently create the bind source on the rootfs and the library would land there); the dump
  script refuses unless `/mnt/seafile-backup` is one; `tasks/stack.yml` checks both before starting.
- **Credentials**: the container units carry `ConditionPathExists=` on their env files, so a freshly
  booted image (before Ansible has run) skips them quietly instead of crash-looping.
- **Logs** go to stdout (`SEAFILE_LOG_TO_STDOUT`) and Docker's `json-file` driver, rotated at 50 MB × 3
  by the daemon settings (the same values `docker_host` applied), not into `/shared/logs` on the HDDs.

Deliberate deviations from upstream:

- **Caddy**: stock `caddy` with a static Caddyfile (generated in Nix from the hostname and ACME
  contact) instead of `caddy-docker-proxy`, so the internet-facing container does not get
  `/var/run/docker.sock` (root on the guest).
- **Not deployed**: SeaDoc, notification server, Seafile AI, metadata server (upstream
  optional extensions). `ENABLE_SEADOC` is set to `false` explicitly (upstream defaults it
  to `true`). Add them from upstream's `seadoc.yml` etc. if wanted.
- **No Portainer**, unlike the other Docker tenants, to keep the public guest's admin surface minimal.
- **Client IPs**: Caddy's default `X-Forwarded-For` handling records the connecting peer, so direct
  clients keep their address as far as Caddy reports it to Seafile. Clients arriving through the IPv4 proxy
  are the exception: Fly hides the IPv4 source, so they appear as the proxy and Seafile's login
  throttling is per-proxy for them, not per-client.
- The dmz ipvlan network `docker_host` used to require is gone (nothing joined it).

## Secrets (operator action required)

Nothing is invented or committed. The role refuses to run (`tasks/validate.yml`, before
any change in the guest) unless `group_vars/all/vault.yml` — **not edited by this repo
change** — contains these entries. Add them with
`ansible-vault edit group_vars/all/vault.yml`:

| Vault variable | Requirement |
|---|---|
| `vault_seafile_db_password` | alphanumeric only, 16+ chars (the `seafile` DB user) |
| `vault_seafile_db_root_password` | alphanumeric only, 16+ chars, different from the above (MariaDB root) |
| `vault_seafile_jwt_private_key` | random, 32+ chars, one line (`JWT_PRIVATE_KEY`; also used by Seafile's internal services) |
| `vault_seafile_admin_email` | valid address; the first admin's login |
| `vault_seafile_admin_password` | 12+ chars, one line; first admin's password |

Generate e.g. with `openssl rand -hex 24` (48 chars, alphanumeric).

**Where they go**: only `tasks/secrets.yml` writes them, as `root:root 0400` files in
`/var/lib/seafile/secrets/` (directory `0700`): `mysql.env` (`MYSQL_ROOT_PASSWORD`) and `seafile.env`
(DB password, `INIT_*`, `JWT_PRIVATE_KEY`). The container units pass them with `docker run --env-file`.
They are never in `site.nix`, the flake tree, the image, a unit file or `/nix/store`
(`tests/` enforce this), so rotating one is an Ansible run, not a rebuild of the image. They do sit in
the containers' environment (`docker inspect`, root on the guest only). A changed credential on a
running stack restarts the affected containers; a first install just starts them.

`INIT_*` values (root password, admin email/password) are only consumed on the very first
start, when the data dir is empty. Rotating them later in the vault does **not** change the
live database or admin account; change those in the app / MariaDB. Rotating
`vault_seafile_db_password` also needs `ALTER USER` in MariaDB first.

## Network and exposure

- **Router** (`host_vars/prydwen.yml`): `host_seafile` DHCPv6 reservation (hostid `2a`) and a
  `seafile` ddns service publishing the guest's dmz GUA as AAAA. No firewall rule: the dmz zone
  is already forwarded from wan (`forward_wan_dmz`), as for matrix/nextcloud.
- **Pinned DHCPv6 identity.** As for matrix, the lease is *assigned*, not discovered, so it can be written
  before the container first boots (no manual lease step any more). `configuration.nix` sets for
  `eth6`:

  ~~~ini
  [DHCPv6]
  DUIDType=vendor
  DUIDRawData=00:00:ab:11:73:65:61:66:69:6c:00:6d
  IAID=1936023910
  ~~~

  `DUIDType=vendor` prepends the type, giving the 14-byte DUID-EN `00020000ab1173656166696c006d`
  (enterprise number 43793 = systemd's; identifier `seafil` + `0x006d`, the vmid 109). The IAID
  `0x73656166` is `seaf`. The reservation in `host_vars/prydwen.yml` is
  `duid: ["00020000ab1173656166696c006d%73656166"]`, and `tests/test_seafile_wiring.py` fails if the two
  ever disagree. The `mac` is pinned too (`hwaddr` in `host_vars/seafile.yml`). Addressing is
  systemd-networkd's, declared in the image (`10-eth6`); there is no `networkd_interfaces` pct-exec step.
- **IPv4**: shared Fly proxy, `extern/ipv4-proxy/nginx.conf.example` routes SNI
  `seafile.us.example.org` to the origin on 443 (TLS passthrough) and 80 (ACME challenge /
  redirect). Copy it into the gitignored `nginx.conf` and `fly deploy` (see that README). Adding
  a hostname to the shared Fly app means an outage there now also takes down Seafile's IPv4.
- **TLS**: Caddy gets a Let's Encrypt certificate itself (`acme_email`). It needs inbound 443
  (and ideally 80) and a resolving AAAA. State lives in the `seafile_caddy_data` volume
  — losing it only means re-issuing. Docker publishes 80/443 on the guest's own addresses (NAT66
  through the bridge, `ip6tables` in the daemon settings); the NixOS firewall also allows both.

## Storage and backup

| Data | Where |
|---|---|
| Library blocks, `seafile/conf`, avatars, `/shared` | ZFS `frontpanel-dataset/Seafile` → `mp0` → `/mnt/seafile` → `/shared` |
| Database | named volume `seafile_db` (Optane rootfs) |
| Nightly SQL dump | ZFS `frontpanel-dataset/Backup/seafile` → `mp1` → `/mnt/seafile-backup` |

Both host dirs are created owned by uid/gid `100000` (container root of the unprivileged CT);
there is no idmap. Both mounts are present at first boot (`at_create`), so no `pct reboot` is needed.

`seafile-db-dump.timer` (02:30 ±15 min, `Persistent`) runs `seafile-db-dump`
(`files/nixos/seafile-db-dump.sh`, built with `writeShellApplication`, so shellcheck runs at build time):
`mariadb-dump --single-transaction` of `ccnet_db seafile_db seahub_db` inside `seafile-mysql` into
`seafile-db-<timestamp>.sql.gz`. It is fail-safe: it refuses to run if `/mnt/seafile-backup` is not a
mount; dumps to a temp file; requires mariadb-dump's `-- Dump completed` trailer; gzips and
`gzip -t`-verifies; only then publishes (`mv`) and prunes to the newest 14. A failed night therefore leaves
every earlier dump untouched. **Scope decision, as for Immich: no off-pool copy.**
The dump and `/shared` share one RAID-Z pool; add a borg/rsync job if that is not enough.

Consistent restore (per Seafile's backup docs the DB is dumped *before* data is copied, so
the DB never references blocks the data copy lacks): stop `docker-seafile` and `docker-seafile-caddy`,
restore the data dir to `/mnt/seafile`, load the dump into `seafile-mysql` (see "Restore the database"
below), start the containers. Test a restore before
relying on it.

## First run (new guest, no existing data)

1. Add the five vault entries above. Review `seafile_version` against the upstream release notes.
2. `ansible-playbook playbooks/configure.yml --limit prydwen` installs the DHCPv6 reservation and the ddns
   service. Do this first so the address is waiting before CT109 boots.
3. `ansible-playbook playbooks/init_proxmox.yml --limit sentinel-lp` builds the NixOS template on the
   workstation (needs Nix there), uploads it and creates CT109 with both mounts present at first boot.
   Do not create dirs by hand under the host paths.
4. `ansible seafile -m ping`, then `ansible-playbook playbooks/configure.yml --limit seafile`. (There is no
   `init_tenant.yml` stage for this guest.) The first run pulls the images and Seafile initialises,
   which takes a minute or two.
5. **Create the `AAAA` record** for `seafile.us.example.org` in Cloudflare (DNS-only, grey cloud,
   placeholder address): ddns updates an existing record but does not create it. Add the
   DNS-only `A` record pointing at the Fly app's IPv4 (same one nextcloud/matrix use) and
   redeploy the Fly proxy with the new map entries.
6. Wait for Caddy to obtain the certificate (`docker logs seafile-caddy`), then sign in at
   `https://seafile.us.example.org` as `vault_seafile_admin_email`.
7. Confirm the first dump: `systemctl start seafile-db-dump` and check `/mnt/seafile-backup`.
8. In the admin UI, disable public registration and review upload limits before inviting users.

## Restoring from backup

To restore into a freshly created guest, stop the stack first so Seafile cannot write while data and database are swapped (`systemctl stop docker-seafile-caddy docker-seafile`), restore the data dir to `/mnt/seafile` and load the dump (below), then start the stack again (`systemctl start docker-seafile docker-seafile-caddy`, or re-run `playbooks/configure.yml --limit seafile`).

### Restore the database

Inside CT109 (`pct enter 109`), with the stack stopped except `seafile-mysql`, and a dump from `/mnt/seafile-backup`. The fresh MariaDB has no `seafile` account
(Seafile's own first-run script creates it, and it will not run against an existing `/shared`), so create
it with the vault's `vault_seafile_db_password`, then load the dump:

~~~sh
read -rs PW   # vault_seafile_db_password, typed, so it stays out of shell history
docker exec -i seafile-mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mariadb -uroot' <<SQL
CREATE USER IF NOT EXISTS 'seafile'@'%' IDENTIFIED BY '$PW';
ALTER USER 'seafile'@'%' IDENTIFIED BY '$PW';
GRANT ALL PRIVILEGES ON \`ccnet_db\`.* TO 'seafile'@'%';
GRANT ALL PRIVILEGES ON \`seafile_db\`.* TO 'seafile'@'%';
GRANT ALL PRIVILEGES ON \`seahub_db\`.* TO 'seafile'@'%';
SQL
unset PW
zcat /mnt/seafile-backup/seafile-db-<timestamp>.sql.gz \
  | docker exec -i seafile-mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mariadb -uroot'
~~~

The dump was made with `--databases`, so it contains the `CREATE DATABASE` statements. Grants and users
are not part of it, hence the first block. This path is documented from Seafile's and MariaDB's behaviour and
is **untested here** — rehearse it (for instance on a scratch container from the dump) before relying on it. If the restored application cannot log in to the database, compare the `seafile` account's
grants (`SHOW GRANTS FOR 'seafile'@'%'`) with what `seafile.conf` expects.

## Tests

All offline; none touch a host, the vault or the network once the Nix inputs are cached.

- `tests/test_seafile_wiring.py` — cross-file wiring (PyYAML only): unique VMID/MAC/hostid, the pinned
  DUID/IAID in `configuration.nix` equal to the router reservation, the matrix-shaped flake/lock/build_template
  contract, mount paths agreeing between `host_vars`, `vars/main.yml` and Nix, secrets confined to the two
  root-only env templates (no secret name in anything the flake or image sees), image pins, vault variable
  names unchanged, no `docker_container`/apt tasks, no real domain committed.
- `tests/test_db_dump.py` — runs `files/nixos/seafile-db-dump.sh` with mocked `docker` and `mountpoint`:
  a failed, partial, truncated or gzip-corrupt dump publishes and prunes nothing, a good one is published and
  retention applied, and a missing mount is refused before the database is touched.
- `tests/test_nixos_config.py` — evaluates the flake with Nix (`--no-update-lock-file`, a rendered `site.nix`) and
  asserts on the resulting containers, units, daemon settings, DHCPv6 identity and timer; skipped without Nix or
  the locked inputs. `SEAFILE_NIX_BUILD=1` also builds the system closure (which shellchecks the wrapped scripts).

~~~sh
python3 -m unittest discover -s roles/tenant/seafile/tests   # needs PyYAML and, for the Nix checks, nix
SEAFILE_NIX_BUILD=1 python3 -m unittest roles.tenant.seafile.tests.test_nixos_config
~~~

Not covered offline: Docker actually running inside the unprivileged LXC with NAT66, Seafile's first-run
behaviour, Let's Encrypt issuance, and the Proxmox/router plays. Those need the real guest.
