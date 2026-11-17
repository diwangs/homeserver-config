# Matrix (Tuwunel)

> Hostnames below use `example.org` (the hosting zone, `vault_public_domain`) and
> `example.com` (the Matrix `server_name`, `vault_matrix_server_name`) as
> placeholders; the real values are in `group_vars/all/vault.yml`.

Matrix homeserver on LXC 106, in the dmz (VLAN 6). Runs
[Tuwunel](https://matrix-construct.github.io/tuwunel/), the Rust homeserver that
succeeded conduwuit, via the `services.matrix-tuwunel` nixpkgs module.

| | |
|---|---|
| vmid / hostname | 106 / `matrix` |
| Address | `fd5a:715f:1edc:a706::27` (dmz) |
| Public name | `matrix.us.example.org` (AAAA only) — where it is *hosted* |
| `server_name` | `example.com` — its *identity*; user IDs read `@you:example.com` |
| Ports | 443 client + federation, 8448 federation, 80 ACME + redirect |

## This guest is not Debian

It is the only NixOS tenant in the repo, which changes three things:

- **The image is the configuration.** `files/nixos/` holds the flake; the LXC
  template is generated from it by `tasks/build_template.yml` on the workstation
  (Proxmox has no Nix) and uploaded to `local:vztmpl`. There is no `pveam` template
  and nothing in `roles/host/proxmox_templates` applies.
- **There is no `playbooks/init_tenant.yml` stage.** The Debian roles split immutable in-guest
  provisioning (apt repos, docker) from configuration. Here `nixos-rebuild switch`
  is idempotent and does both, so everything in-guest lives in `playbooks/configure.yml` via
  `tasks/main.yml`.
- **The dist-upgrade tooling does not apply.** `roles/maintenance/debian_dist_upgrade` and
  `playbooks/upgrade_lxc_dist.yml` assert `ansible_distribution == "Debian"`. Upgrade this
  guest by bumping `files/nixos/flake.lock` and re-running `playbooks/configure.yml`.

`host_vars/matrix.yml` pins `ansible_python_interpreter` to
`/run/current-system/sw/bin/python3` — Ansible's `auto` discovery probes
`/usr/bin/python3` and friends, none of which exist on NixOS.

## nixpkgs pinning

`flake.nix` tracks `https://flakehub.com/f/NixOS/nixpkgs/0.1`, FlakeHub's selector
for the newest **unstable** nixpkgs (`0` would be stable). The exact revision is
pinned by the committed `flake.lock`, and both the image build and `nixos-rebuild`
pass `--no-update-lock-file`, so tracking unstable does not mean a different
nixpkgs on every run. Upgrade deliberately:

~~~sh
nix flake update --flake roles/tenant/matrix/files/nixos
ansible-playbook playbooks/configure.yml --limit matrix
~~~

## Storage and backups

Tuwunel owns its own backups, the same division of labour Nextcloud AIO has: Ansible
only provides the mount, and the application does the rest. There is no borg here —
`database_backup_path` uses RocksDB's native online backup engine.

| | |
|---|---|
| Host path | `/mnt/frontpanel-pool/frontpanel-dataset/Backup/matrix` |
| In container | `/mnt/matrix-backup` (`mp0`) |
| Schedule | Sundays 04:00, ±15 min jitter, `Persistent = true` |
| Retention | `database_backups_to_keep = 4` (~1 month) |

Tuwunel has no internal scheduler and its admin commands normally require posting
into the admin room. The way out is `admin_signal_execute`, which runs a command list
on **SIGUSR2** — so `tuwunel-backup.timer` just signals the running process, with no
restart and no access token:

~~~sh
systemctl kill --kill-whom=main --signal=SIGUSR2 tuwunel.service
~~~

Two upstream defaults had to be overridden for this to work at all, both in
`files/nixos/configuration.nix`:

- `ReadWritePaths = [ "-/mnt/matrix-backup" ]` — the unit ships
  `ProtectSystem = "strict"`, so without this the backup fails at *write* time. The
  service would look perfectly healthy until the first Sunday. The leading `-` is
  equally load-bearing: without it a missing mount aborts namespace setup and the
  unit dies with `226/NAMESPACE` before starting at all. That is not hypothetical —
  it happened on first boot, since `mp0` only appears after a container restart.
- `DynamicUser = lib.mkForce false` plus `users.users.tuwunel.uid = 1000` — a
  transient uid cannot be expressed in the host-side LXC idmap, so backups would
  land on the pool owned by an arbitrary high uid instead of `diwangs`.

Backups are **not** a directly usable database directory. To restore, stop the
service and run `tuwunel --restore-backup` (or `--restore-backup=N` for a specific
one); `server list-backups` shows what is there.

## IPv4 reachability

The container itself is still IPv6-only — `matrix.us.example.org`'s `AAAA` is the
only address it ever holds. IPv4 clients and homeservers reach it through
**`extern/ipv4-proxy/`**, the same Fly.io TCP-passthrough shim Nextcloud uses,
*shared* rather than duplicated: one Fly app now fronts both tenants, routed by TLS
SNI (`ssl_preread`, no certificate termination at the proxy — the real backend still
negotiates TLS end-to-end with the client). See that directory's `nginx.conf` for
the routing map.

This tenant added a second Fly `[[services]]` block for **port 8448** (federation)
alongside the existing 443 one, since Nextcloud only ever needed 443.

**Manual, one-time DNS step** (same category as the DHCPv6 lease and the apex
`.well-known` — outside what Ansible reaches): add an `A` record for
`matrix.us.example.org` in Cloudflare, pointed at the **same IPv4** Nextcloud's
`A` record already uses, and **DNS-only** (grey cloud) — proxying it through
Cloudflare would terminate TLS at the edge, which this passthrough setup deliberately
avoids. The existing `AAAA` (ddns-managed, direct to the container) is untouched;
this is purely additive, matching Nextcloud's dual-stack split exactly: IPv6 clients
go straight to the box, IPv4 clients go via Fly.

**The trade-off worth knowing**: reachability for *both* tenants now depends on one
shared Fly app. An outage there — the app crashing, its region going down, the
dedicated IPv4 being reassigned — takes down IPv4 access to Nextcloud and Matrix
together, where before it was Nextcloud's problem alone. Nothing about the
container's own health or the DMZ firewall changes; this risk is entirely in the
external proxy layer, and is the direct cost of not running (and paying for) a
second dedicated IPv4 and machine.

Once the `A` record exists and `fly deploy` has picked up the new `nginx.conf` /
`fly.toml`, verify with
[federationtester](https://federationtester.matrix.org/api/report?server_name=example.com)
— it should now report a *successful* connection over IPv4, not merely IPv6.

## TLS

nginx terminates TLS and proxies `/_matrix/` to tuwunel on `[::1]:6167`. Matrix
requires a real certificate — federation and clients both reject plain HTTP, and a
self-signed cert will not federate.

The certificate is issued over **ACME HTTP-01**, which is why this role needs no
credential of any kind. Let's Encrypt proves ownership by fetching a challenge file
over port 80, so the only thing it depends on is the `AAAA` record being correct.
Note the bootstrap ordering that implies: ddns keeps that record *current* but does
not *create* it, so until the record exists in Cloudflare (checklist step 6) nothing
resolves and ACME cannot validate — nginx serves the self-signed placeholder
`security.acme` installs so it can start at all. DNS-01 was the obvious alternative, but
it proves the same fact by writing a `_acme-challenge` `TXT` record, which would mean
a Cloudflare token with `Zone:DNS:Edit` sitting on a public-facing host to solve a
problem ddns has already solved.

What this trades away: **renewal now depends on inbound port 80.** Verified open end
to end at both layers —

- Router: `forward_wan_dmz` is an unrestricted forwarding (no `dest_port` filter), and
  no rule narrows it. Contrast `rule_hass`, which needs an explicit `dest_port: '80
  443'` because the backend zone has no forwarding entry at all.
- Proxmox: the `firewall=1` on the netif is inert — there is no `cluster.fw` and
  `nodes/sentinel-lp/host.fw` has `enable: 0`, so the PVE firewall is off node-wide.

**Confirmed working in practice**, not just on paper: lego completed an HTTP-01
order against `acme-v02.api.letsencrypt.org` and issued a real certificate, which
only succeeds if Let's Encrypt can reach port 80 from the internet. So the ISP does
deliver inbound 80. If a renewal ever fails with a connection timeout on the
challenge, that is the thing to suspect, and the fix is to move this cert to DNS-01.

## First-run checklist

This role needs **no vault entry** — see "TLS" below.

There is **no manual DHCPv6 lease step** — see "Pinned DHCPv6 identity" below.

1. `ansible-playbook playbooks/configure.yml --limit prydwen` — installs the static lease and
   the ddns service. Do this first so the address is reserved before 106 boots.
2. `ansible-playbook playbooks/init_proxmox.yml` — builds the template, creates and starts 106.
3. Confirm reachability: `ansible matrix -m ping`.
4. `ansible-playbook playbooks/configure.yml --limit sentinel-lp,matrix`.
5. **`pct reboot 106` once.** `mp0` is added while the container is already running,
   so the backup mount is not visible until a restart — the same one-time step
   Immich needs. Verify with `pct exec 106 -- findmnt /mnt/matrix-backup`.
6. **Create the `AAAA` record for `matrix.us.example.org` in Cloudflare**, with any
   placeholder address. This cannot be skipped and cannot be automated from here:
   ddns-scripts' `cloudflare.com-v4` provider *updates* an existing record, it does
   not create one. Until the record exists it logs
   `Could not detect 'record id' for host.domain.tld` and never publishes, and
   because nothing resolves, ACME cannot validate either — nginx keeps serving the
   self-signed placeholder cert that `security.acme` installs so it can start.
   Once the record exists, ddns keeps it pointed at the current dmz GUA.
7. **`.well-known` at the apex** — see below.
8. Create the admin user. Tuwunel runs admin commands at startup via `--execute` /
   `admin_execute`; `allow_registration` is off, so this is the only way in.

## `.well-known` delegation (manual, out of band)

`server_name = example.com` means federation and clients first ask
**`https://example.com`**, which nothing in this repo hosts — the apex is not
pointed at any container, and never should be (see below). Resolved with a
**Cloudflare Redirect Rule**, not a Worker or Snippet — Snippets moved to a
paid-plan-only feature, and the spec explicitly permits this:

> 30x redirects should be followed, however redirection loops should be avoided.

Rule, on the `example.com` zone:

- **When**: `http.host eq "example.com" and starts_with(http.request.uri.path, "/.well-known/matrix/")`
- **Then**: 301/308 to `concat("https://matrix.us.example.org", http.request.uri.path)`

Two prerequisites the rule depends on, both manual and both already done:

1. `example.com` has a **proxied** (orange-cloud) placeholder record — an apex can't
   be proxied without one, and there was no real A/AAAA to reuse. Cloudflare
   documents `100::` (AAAA) / `192.0.2.0` (A) as reserved addresses for exactly this
   originless case; traffic never reaches them because the proxy answers first.
2. `matrix.us.example.org` stays **grey** (DNS-only, direct). Proxying it would
   terminate TLS at Cloudflare, and — more concretely — federation's port 8448 isn't
   in Cloudflare's proxied port list, so the fallback listener would go dark.

nginx also serves both documents directly on `matrix.us.example.org` for clients
handed that host, but that does not substitute for the apex — federation and most
clients look up the `server_name`, not the hosting name.

This is manual for the same reason the PVE firewall rules and DHCPv6 leases are —
it lives outside what Ansible reaches, in Cloudflare's dashboard rather than in this
repo. Verified end to end with
[federationtester](https://federationtester.matrix.org/api/report?server_name=example.com):
delegation resolves to `matrix.us.example.org:443`, TLS validates via ISRG Root
X2, all checks pass.

**Not yet verified**: client-side auto-discovery (Element and similar, fetching
`/.well-known/matrix/client` via `fetch()` rather than a plain federation GET). The
redirected response does carry nginx's `Access-Control-Allow-Origin: *`, and simple
GETs follow redirects without a CORS preflight, so it should work — but log in with
a real client before calling that path confirmed.

## Pinned DHCPv6 identity

**This tenant's lease works differently from every other one in the repo, on
purpose.** The others hold a *discovered* DUID: theirs is derived from a random
`machine-id`, so the guest must boot and be observed on the router before its lease
can be written — and it is only reachable once that lease exists. That
chicken-and-egg is what `playbooks/init_proxmox.yml`'s header means by "the DUID can't be set
statically from outside," and it is why every other tenant needs a manual pause
mid-provisioning.

It does not apply to a NixOS guest, which carries its network configuration *in the
image* rather than receiving it over SSH afterwards. So the identity is assigned
rather than discovered, in `files/nixos/configuration.nix`:

~~~ini
[DHCPv6]
DUIDType=vendor
DUIDRawData=00:00:ab:11:6d:61:74:72:69:78:00:6a
IAID=1835101810
~~~

`DUIDType=vendor` prepends the type (`00:02`), giving the 14-byte DUID-EN
`00020000ab116d6174726978006a` — the same shape the other systemd guests produce.
The enterprise number `00:00:ab:11` is systemd's (43793); the identifier is `matrix`
in ASCII followed by `0x006a` (106, the vmid), so it reads as obviously deliberate
rather than random. The IAID `0x6d617472` (`matr`) is pinned for the same reason and
appears as the `%` suffix on the lease's `duid`, which is how odhcpd records it —
`ubus call dhcp ipv6leases` reports `duid` and `iaid` as separate fields.

Both halves are committed, so `host_vars/prydwen.yml` can reserve `::27` before the
container exists. Apply the router play first and the address is waiting on first
boot. A side benefit: rebuilding the container from a fresh image keeps the same
address instead of needing a new lease.

## Networking

`net6`/`eth6` on VLAN 6 with `ip6=manual`, so addressing belongs to
systemd-networkd. Unlike the Debian guests there are no `networkd_interfaces`: the
`10-eth6.network` unit is declared in `configuration.nix` and ships inside the image,
so the guest addresses itself on first boot with no host-side `pct exec`. The `10-`
prefix sorts ahead of anything Proxmox drops into `/etc/systemd/network`, and
networkd takes the first matching file.

No firewall rule is needed on the router. The dmz zone is already forwarded from
wan (`forward_wan_dmz` in `host_vars/prydwen.yml`), which is the reason for putting
a public service on VLAN 6 rather than backend, where each service needs its own
prefix-relative `dest_ip` rule.
