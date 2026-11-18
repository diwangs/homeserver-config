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

## Stack

Follows upstream's `docker/ce` compose files (`.env`, `seafile-server.yml`, `caddy.yml`)
at the pinned version, as one `docker_container` task each on the `seafile-net` bridge:

| Container | Image | Notes |
|---|---|---|
| `seafile-mysql` | `mariadb:10.11` | Seafile 13.0's documented DB; named volume on the Optane rootfs |
| `seafile-redis` | `redis:7` | Cache (`CACHE_PROVIDER=redis`, the 13.0 default); no password, no published port, no persistence — same as upstream |
| `seafile` | `seafileltd/seafile-mc:<seafile_version>` | Seahub + Go fileserver; `/shared` = ZFS |
| `seafile-caddy` | `caddy:2` | TLS termination, the only container with published ports |

Deliberate deviations from upstream:

- **Caddy**: stock `caddy` with a static Caddyfile instead of `caddy-docker-proxy`, so the
  internet-facing container does not get `/var/run/docker.sock` (root on the guest).
- **Not deployed**: SeaDoc, notification server, Seafile AI, metadata server (upstream
  optional extensions). `ENABLE_SEADOC` is set to `false` explicitly (upstream defaults it
  to `true`). Add them from upstream's `seadoc.yml` etc. if wanted.
- **No Portainer**, unlike the other Docker tenants, to keep the public guest's admin surface minimal.
- **Logs** go to stdout (`SEAFILE_LOG_TO_STDOUT`), rotated by Docker, not into `/shared/logs` on the HDDs.
- **Client IPs**: Caddy's default `X-Forwarded-For` handling records the connecting peer, so direct
  clients keep their address as far as Caddy reports it to Seafile. Clients arriving through the IPv4 proxy
  are the exception: Fly hides the IPv4 source, so they appear as the proxy and Seafile's login
  throttling is per-proxy for them, not per-client.

## Secrets (operator action required)

Nothing is invented or committed. The role refuses to run (`tasks/validate.yml`, before
any change in the guest) unless `group_vars/all/vault.yml` — **not edited by this repo
change** — contains these entries. Add them with `ansible-vault edit group_vars/all/vault.yml`:

| Vault variable | Requirement |
|---|---|
| `vault_seafile_db_password` | alphanumeric only, 16+ chars (the `seafile` DB user) |
| `vault_seafile_db_root_password` | alphanumeric only, 16+ chars, different from the above (MariaDB root) |
| `vault_seafile_jwt_private_key` | random, 32+ chars (`JWT_PRIVATE_KEY`; also used by Seafile's internal services) |
| `vault_seafile_admin_email` | valid address; the first admin's login |
| `vault_seafile_admin_password` | 12+ chars; first admin's password |

Generate e.g. with `openssl rand -hex 24` (48 chars, alphanumeric).
`INIT_*` values (root password, admin email/password) are only consumed on the very first
start, when the data dir is empty. Rotating them later in the vault does **not** change the
live database or admin account; change those in the app / MariaDB. Rotating
`vault_seafile_db_password` also needs `ALTER USER` in MariaDB first. The values do
sit in the containers' environment (`docker inspect`, root on the guest only).

## Network and exposure

- **Router** (`host_vars/prydwen.yml`): `host_seafile` DHCPv6 reservation (hostid `2a`) and a
  `seafile` ddns service publishing the guest's dmz GUA as AAAA. No firewall rule: the dmz zone
  is already forwarded from wan (`forward_wan_dmz`), as for matrix/nextcloud.
- **IPv4**: shared Fly proxy, `extern/ipv4-proxy/nginx.conf.example` routes SNI
  `seafile.us.example.org` to the origin on 443 (TLS passthrough) and 80 (ACME challenge /
  redirect). Copy it into the gitignored `nginx.conf` and `fly deploy` (see that README). Adding
  a hostname to the shared Fly app means an outage there now also takes down Seafile's IPv4.
- **TLS**: Caddy gets a Let's Encrypt certificate itself (`acme_email`). It needs inbound 443
  (and ideally 80) and a resolving AAAA. State lives in the `seafile_caddy_data` volume
  — losing it only means re-issuing.
- Docker ipvlan `dmz` is required by `docker_host` but unused (range `::50/124`, away from
  nextcloud's `::30/124`).

## Storage and backup

| Data | Where |
|---|---|
| Library blocks, `seafile/conf`, avatars, `/shared` | ZFS `frontpanel-dataset/Seafile` → `mp0` → `/mnt/seafile` → `/shared` |
| Database | named volume `seafile_db` (Optane rootfs) |
| Nightly SQL dump | ZFS `frontpanel-dataset/Backup/seafile` → `mp1` → `/mnt/seafile-backup` |

Both host dirs are created owned by uid/gid `100000` (container root of the unprivileged CT);
there is no idmap.

`seafile-db-dump.timer` (02:30 ±15 min) runs `mariadb-dump --single-transaction` of
`ccnet_db seafile_db seahub_db` inside `seafile-mysql` into `seafile-db-<timestamp>.sql.gz`, keeping 14. It refuses
to run if `/mnt/seafile-backup` is not a mount. **Scope decision, as for Immich: no off-pool copy.**
The dump and `/shared` share one RAID-Z pool; add a borg/rsync job if that is not enough.

Consistent restore (per Seafile's backup docs the DB is dumped *before* data is copied, so
the DB never references blocks the data copy lacks): stop `seafile` and `seafile-caddy`, restore
the data dir to `/mnt/seafile`, load the dump into `seafile-mysql`
(`zcat dump.sql.gz | docker exec -i seafile-mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -uroot'`),
start the containers. Test a restore before relying on it.

## First run

1. Add the five vault entries above. Review `seafile_version` against the upstream release notes.
2. `ansible-playbook playbooks/init_proxmox.yml --limit sentinel-lp` creates CT109 (with both mounts
   present at first boot, so no `pct reboot` is needed). Do not create dirs by hand under the host paths.
3. **DHCPv6 lease** (as for every Debian tenant; the DUID is random so it cannot be
   pre-assigned): find the guest's DUID/IAID on prydwen (`ubus call dhcp ipv6leases`), add
   `duid: ["<duid>%<iaid>"]` to `host_seafile` in `host_vars/prydwen.yml`, then
   `ansible-playbook playbooks/configure.yml --limit prydwen`. Until then the guest has no stable
   address and ddns publishes nothing. The `mac` is already pinned (`hwaddr` in `host_vars/seafile.yml`).
4. `ansible seafile -m ping`, then `ansible-playbook playbooks/init_tenant.yml --limit seafile`
   (Docker engine + network), then `ansible-playbook playbooks/configure.yml --limit seafile`.
5. **Create the `AAAA` record** for `seafile.us.example.org` in Cloudflare (DNS-only, grey cloud,
   placeholder address): ddns updates an existing record but does not create it. Add the
   DNS-only `A` record pointing at the Fly app's IPv4 (same one nextcloud/matrix use) and
   redeploy the Fly proxy with the new map entries.
6. Wait for Caddy to obtain the certificate (`docker logs seafile-caddy`), then sign in at
   `https://seafile.us.example.org` as `vault_seafile_admin_email`. Seafile takes a minute or
   two on first start (database and config initialisation, `docker logs seafile`).
7. Confirm the first dump: `systemctl start seafile-db-dump` and check `/mnt/seafile-backup`.
8. In the admin UI, disable public registration and review upload limits before inviting users.

## Tests

`tests/test_seafile_wiring.py` checks the cross-file wiring offline (unique VMID/MAC/hostid, address,
ddns and proxy entries, vault indirection, pinned image, no ports except Caddy, no real domain).
`tests/test_db_dump.py` runs the dump script from `tasks/backup.yml` with mocked `docker` and
`mountpoint`: a failed or truncated dump publishes and prunes nothing, a good one is published,
and a missing mount is refused.

~~~sh
python3 -m unittest discover -s roles/tenant/seafile/tests   # needs PyYAML
~~~
