# BunkerWeb (public HTTP(S) edge)

> Hostnames below use `example.org` for the hosting zone (`vault_public_domain`); the
> real value is in `group_vars/all/vault.yml`.

[BunkerWeb](https://docs.bunkerweb.io/) (nginx + ModSecurity/OWASP CRS, rate limiting,
bad-behavior bans) on LXC 110 in the dmz, the TLS-terminating edge for:

| Hostname | Origin (plain HTTP :80 on its dmz ULA) |
|---|---|
| `matrix.us.example.org` | matrix (CT106) `fd5a:715f:1edc:a706::27` — nginx → tuwunel |
| `hermes.us.example.org` | hermes-gateway (CT108) `fd5a:715f:1edc:a706::29` — nginx → CT107 dashboard |
| `seafile.us.example.org` | seafile (CT109) `fd5a:715f:1edc:a706::2a` — Seafile's own nginx |
| `dav.us.example.org` | dav (CT111) `fd5a:715f:1edc:a706::2c` — Radicale, CalDAV/CardDAV, via a host nginx stream relay |
| `hass.us.example.org` | hass (CT113) `[fd5a:715f:1edc:a703::24]:8123` — Home Assistant itself. The exception: its **backend** ULA and port 8123, over the router's dmz → backend forwarding (see `roles/tenant/hass/README.md`) |

It also relays **Frigate's WebRTC media** (`frigate-webrtc.us.example.org:8555`, TCP only) at L4
with an nginx stream server to go2rtc on Frigate's dmz ULA (`bunkerweb_frigate_webrtc_upstream`,
`fd5a:715f:1edc:a706::22`). BunkerWeb itself is not involved (it is not HTTP).

Every public HTTP(S) service is behind the edge. Home Assistant used to be reached directly as
`hass-us.example.org` (own TLS, `Allow-Hass`) and Nextcloud likewise; both exceptions are gone.

## How traffic arrives

- **DNS**: `matrix.us`, `hermes.us`, `seafile.us`, `dav.us`, `hass.us` and `frigate-webrtc.us` are **CNAMEs** to
  `edge.us.example.org` (`edge_hostname`), whose records the router's ddns keeps current:
  AAAA from the edge's dmz lease (`ddns.edge`), A from the router's WAN address (`ddns.edge4`).
  Both records must already exist in Cloudflare (ddns updates, it does not create).
- **IPv6**: wan → the edge's GUA, tcp 80/443/8555 (`Allow-BunkerWeb`, `host_vars/prydwen.yml`).
- **IPv4**: the dmz has no IPv4 (`dmz4` stays down), so IPv4 goes through the router's Jool
  NAT64. The router DNATs wan4 tcp 80/443/8555 (`DNAT-BunkerWeb-*`) to Jool's translator
  (`192.168.64.2`, ports 64080/64443/64555), and static Jool mappings (`prydwen_jool_inbound`,
  applied by `setupjool.sh`) turn each into a connection to the edge's ULA
  (`fd5a:715f:1edc:a706::2b`, ports 80/443/8555). The ULA is used, not the GUA, because a static
  mapping cannot follow a changing prefix.
- **Client addresses**: Docker's DNAT keeps the real source address. IPv6 clients appear as
  themselves; IPv4 clients appear as `64:ff9b::<their IPv4>` (distinct per client, so bans, rate
  limits and logs still work, but the address prints in that form). No PROXY protocol or real-IP
  configuration is needed.

| | |
|---|---|
| vmid / hostname | 110 / `bunkerweb` (unprivileged, `nesting=1`) |
| dmz address | `fd5a:715f:1edc:a706::2b` (pinned DHCPv6 lease `host_bunkerweb`); IPv6 only |
| Ports | 80 (redirect to https), 443, and 8555/tcp (WebRTC relay) |
| TLS | one wildcard, `*.us.example.org`, Let's Encrypt over Cloudflare **DNS-01** |
| Images | `bunkerity/bunkerweb` + `bunkerity/bunkerweb-scheduler`, pinned by `bunkerweb_version` |
| Guest OS | NixOS; containers declared with `virtualisation.oci-containers` (the seafile pattern) |

## Layout

Same architecture as `roles/tenant/seafile` (see its README): the flake in `files/nixos/` *is*
the image, `tasks/build_template.yml` builds it on the workstation, and `tasks/nixos.yml` runs
`nixos-rebuild switch` in the guest. `site.nix` (rendered from `templates/site.nix.j2`, gitignored)
holds the hostnames, ACME contact, image tag, ModSecurity mode and the origins' ULAs (taken from
the inventory) — no secrets.

Containers, on the dual-stack `bw-net` bridge (`10.110.0.0/24`, `fd00:b0b0:5e::/64`):

| Container / unit | Role |
|---|---|
| `bunkerweb` / `docker-bunkerweb` | nginx instance; publishes `80:8080` and `443:8443` (the image runs unprivileged) |
| `bunkerweb-scheduler` / `docker-bunkerweb-scheduler` | the single configuration source: renders the config, issues/renews the certificate, pushes both to the instance's API (`:5000`, `API_WHITELIST_IP` = bw-net only). State (SQLite + certs) in volume `bw-storage` |
| `bunkerweb-ui` / `docker-bunkerweb-ui` | the web dashboard, see below. Shares the scheduler's SQLite database through the same `bw-storage` volume |

**No autoconf and no Docker socket** in any container. Every setting is an environment
variable in `files/nixos/configuration.nix` (`schedulerEnvironment`, per-site settings prefixed
`<hostname>_`), so the repo is the only source of truth.

## Web UI (dashboard)

`http://[fd5a:715f:1edc:a706::2b]:7000/` — the edge's own ULA, **LAN only**: Docker publishes it
on that address, the router forwards no 7000 from wan, and the Jool mappings carry only
80/443/8555. Log in as `vault_bunkerweb_ui_admin_username` with `vault_bunkerweb_ui_admin_password`
(`ansible-vault view group_vars/all/vault.yml`). It is plain HTTP, so the password crosses the LAN
unencrypted; put it behind TLS before using it from untrusted segments.

- The credentials only *seed* the admin account on the UI's first start; later changes to the vault
  entry have no effect unless `OVERRIDE_ADMIN_CREDS=yes` is set. Change the password in the UI's
  profile page instead, and enable TOTP there.
- `UI_LISTEN_ADDR` must be `[::]` (with the brackets) and `UI_LISTEN_PORT` set: the image binds
  IPv4 only by default, which an IPv6 publish never reaches, and a bare `::` crashes the entrypoint.
- Settings defined in `files/nixos/configuration.nix` stay the source of truth: the scheduler
  re-applies them from its environment on every restart. Treat UI edits to those settings as
  temporary, and use the UI mainly to inspect traffic, bans and ModSecurity events.

## Exposure

nixos-fw opens only 8555 (the WebRTC relay is a host nginx). BunkerWeb's 80/443 are Docker-published
(DNAT bypasses nixos-fw), so what may reach them is decided by the router: `Allow-BunkerWeb` for
IPv6 and the `DNAT-BunkerWeb-*` forwards (into Jool) for IPv4. Nothing else from wan reaches the dmz.

## Settings that matter

- **Wildcard via DNS-01**: `USE_LETS_ENCRYPT_WILDCARD=yes`, `LETS_ENCRYPT_DNS_PROVIDER=cloudflare`,
  so issuance and renewal need no inbound port. `LETS_ENCRYPT_DNS_CREDENTIAL_DECODE_BASE64=no`,
  because a Cloudflare token can look like base64.
- **`USE_IPV6=yes`**: BunkerWeb listens on IPv4 only by default; IPv6 clients are handed to the
  container's IPv6 address and would otherwise be reset before TLS.
- **Origins** are plain HTTP on the dmz ULAs; each origin's firewall admits port 80 from this
  guest's ULA only (`site.edgeAddress` there). Home Assistant: 8123 on its backend ULA, admitted
  from this guest and the home LANs; HA trusts `X-Forwarded-For` from this guest only.
- **Per-site tuning**: Matrix and Seafile need `PUT`/`DELETE`/`OPTIONS`; Matrix allows 20 MB
  bodies and long `/sync` polls; Hermes needs websockets and hour-long reads; Seafile has no body
  limit, `/seafhttp` (file transfer) is streamed unbuffered with ModSecurity off, and
  `X-Forwarded-Protocol` is dropped (seahub's gunicorn rejects it next to `X-Forwarded-Proto`);
  Home Assistant needs websockets held for hours, up to 1 GB bodies (backup uploads) and 50 r/s
  (a cold frontend load).
- **ModSecurity** runs in `DetectionOnly` (`bunkerweb_modsecurity_engine` in `defaults/main.yml`).
  Watch `docker logs bunkerweb` for CRS hits from normal Matrix/Seafile/Hermes use, add
  exclusions if needed, then set it to `On`.
- **Bad behavior** counts only `400 405 444`: 401/403/404/429 are routine API answers here.
- `HTTP3=no`, `USE_DNSBL=no`, `SEND_ANONYMOUS_REPORT=no`, `DISABLE_DEFAULT_SERVER=yes`.

## Trade-offs accepted

- **The home addresses are public**: `edge.us` publishes the router's IPv4 and the edge's GUA
  (and so the `/56`). A volumetric flood would saturate the home line
  (the ISP is the only mitigation); the realistic risks are application-level, which the WAF
  covers once ModSecurity is switched from `DetectionOnly` to `On`.
- **Remote WebRTC is TCP-only**, so it stalls more than UDP on lossy mobile networks. LAN clients
  still use UDP on the dmz ULA.

## Secrets

One: the Cloudflare API token, reused by decision from the router's DDNS
(`vault_openwrt_cloudflare_api_token`, needs `Zone:DNS:Edit`). Rendered only into
`/var/lib/bunkerweb/secrets/scheduler.env` (root, 0400) as
`LETS_ENCRYPT_DNS_CREDENTIAL_ITEM=api_token …`. The container units skip themselves until that file
exists. The same token also controls the router's DDNS records.

## Router (`host_vars/prydwen.yml`)

- `host_bunkerweb` lease: hostid `2b`, DUID `00020000ab1162756e6b6572006e` (`bunker` + vmid
  `0x006e`), IAID `0x62756e6b` (`bunk`), mac `BC:24:11:B0:0B:6E`, all pinned in the image /
  `host_vars/bunkerweb.yml`.
- `prydwen_jool_inbound` + `redirect_bunkerweb_*` carry inbound IPv4 through Jool (see above).
- `ddns.edge` / `ddns.edge4` keep `edge.us` current; the per-name `matrix`, `hermes`, `seafile` and
  `frigate_webrtc` ddns services are listed as absent, so they can't overwrite the CNAMEs.
- The services role restarts ddns whenever its running updaters differ from the configured
  services, so an interrupted run cannot leave a deleted service rewriting a record.

## First run / cutover

1. In Cloudflare create `edge.us.example.org` A (the router's WAN IPv4) and AAAA (the edge's GUA),
   DNS-only.
2. `ansible-playbook playbooks/configure.yml --limit prydwen` (no `timeout` wrapper: a killed run
   leaves half-applied state): installs the rules, the DNATs, the Jool static mappings (re-running
   `setupjool.sh`) and the edge ddns services. Check `/etc/init.d/ddns` lists `edge` and `edge4` and both records stay correct.
3. `ansible-playbook playbooks/init_proxmox.yml --limit sentinel-lp` (new guest only), then
   `ansible-playbook playbooks/configure.yml --limit sentinel-lp,bunkerweb`. Wait for the wildcard
   certificate in `docker logs bunkerweb-scheduler`.
4. Point `matrix.us`, `hermes.us`, `seafile.us` and `frigate-webrtc.us` at `edge.us` as CNAMEs
   (delete their old A/AAAA first).
5. Origins and Frigate: `configure.yml --limit matrix,hermes,hermes-gateway,seafile,frigate`.

Verify (from outside the house, ideally a phone off Wi-Fi):
- `openssl s_client -connect matrix.us.example.org:443 -servername matrix.us.example.org` shows
  `*.us.example.org`, over both IPv4 and IPv6.
- `docker logs bunkerweb` shows real client addresses on both families.
- federationtester passes, a Seafile client syncs a large file, the Hermes dashboard and its
  websocket work, and remote camera viewing in the HA app connects (TCP).
- From outside, the origins' GUAs refuse 80/443, and so does Home Assistant's (`Allow-Hass` is gone).

## Upgrading

Bump `bunkerweb_version` after reading the release notes and diffing upstream's
`misc/integrations/docker.yml` and the settings docs at the new tag, then rerun
`playbooks/configure.yml --limit bunkerweb`. Losing `bw-storage` only means re-issuing the
certificate (mind Let's Encrypt's rate limits).

## Tests

`python3 -m unittest discover -s roles/tenant/bunkerweb/tests` evaluates the flake with a
placeholder `site.nix` (skipped without Nix). `BUNKERWEB_NIX_BUILD=1` also builds the closure.
