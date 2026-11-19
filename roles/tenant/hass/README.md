# Home Assistant (`hass`)

> Hostnames below use `example.org` for the hosting zone (`vault_public_domain`).

Home Assistant Core in **Container mode** on LXC 113 on the backend, public as
`hass.us.example.org` through the BunkerWeb edge (`roles/tenant/bunkerweb`), which terminates
TLS. It replaces the HAOS VM (VM 200, previously reached directly as `hass-us.example.org` with
its own TLS add-on; destroy that VM with `qm destroy 200` once you no longer want it as a
fallback). The Zigbee/Thread/MQTT add-ons had already moved to the `iot` CT (`roles/tenant/iot`).

| | |
|---|---|
| vmid / hostname | 113 / `hass` (unprivileged, `nesting=1`) |
| backend address | `fd5a:715f:1edc:a703::24` + `192.168.3.24`, the old VM's addresses (leases `host_hass_v6`/`_v4`, pinned DUID/IAID and MAC) |
| Guest OS | NixOS; `ghcr.io/home-assistant/home-assistant:<hass_version>@<hass_image_digest>` under `virtualisation.oci-containers`, `--network=host` |
| Origin | plain HTTP :8123, admitted from the edge's ULA and the home LANs (nixos-fw) |
| Auth | Home Assistant's own users, MFA and tokens, carried over in `/config/.storage`; no secrets in this repo |
| Data | `/var/lib/hass/config` on the rootfs (SSD; the recorder would keep the RAID-Z disks awake) |

## Layout

Same architecture as `roles/tenant/dav`: the flake in `files/nixos/` *is* the image,
`tasks/build_template.yml` builds it on the workstation, `tasks/nixos.yml` runs
`nixos-rebuild switch` in the guest. `site.nix` (rendered, gitignored) holds the hostname, the
edge address, the LAN ranges, extra ports and the image pin.

- **Host networking**: discovery (mDNS, SSDP, DHCP) and the Thread backbone need the backend
  link itself, so HA's listeners are ordinary host sockets. nixos-fw opens 8123 to the edge and
  the home LANs, 5353/udp for mDNS, and `hass_extra_tcp_ports`/`hass_extra_udp_ports` (LAN only)
  for integrations that listen (HomeKit Bridge and the like).
- **Not privileged**: no USB or Bluetooth in this guest. Docker's default capabilities include
  `NET_RAW` (DHCP discovery, ping).
- **The edge reaches the backend directly** over the router's `forward_dmz_backend`; there is no
  dmz NIC. HA's `http:` trusts `X-Forwarded-For` from the edge only, so `ip_ban` and the logs
  see real clients (IPv4 clients as `64:ff9b::<addr>`).
- **Gated start**: `docker-homeassistant` runs only once `/var/lib/hass/migrated` exists and
  `/config` holds `.storage/auth`, so a fresh guest can never show the onboarding page (which
  would hand the owner account to whoever got there first).
- **Dropped with Supervisor**: add-ons, ingress, Supervisor backups and OS updates. The TLS add-on
  is replaced by the edge; the file editor by `pct enter 113` (`/var/lib/hass/config`). Core's own
  backups (Settings → System → Backups) still work and land in `/config/backups`.

## Frontend cards

The Cameras dashboard uses [Advanced Camera Card](https://github.com/dermotduffy/advanced-camera-card)
(`custom:advanced-camera-card`), registered as the Lovelace resource
`/local/community/advanced-camera-card/advanced-camera-card.js`. HACS is not installed, so
nothing updates it: the release zip's `dist/` is unpacked by hand into
`/var/lib/hass/config/www/community/advanced-camera-card/` (currently v8.2.0, see `.version`
there). If those files are missing, the card shows "Configuration error" (which it did on HAOS too).
To upgrade, verify the release asset's sha256, replace the directory's contents, and bump the
`?v=` on the resource (Settings → Dashboards → Resources) so browsers reload it.

## History

Moved off the HAOS VM in November 2026 by a one-off playbook, since removed
(`git show e1b4a21:playbooks/migrate_hass.yml`): it stopped Core and the VM, copied
`/mnt/data/supervisor/homeassistant` from the VM's disk, and pointed the http settings and
`external_url` at the edge. Things learned there that still matter:

- The http settings HA actually uses live in `/config/.storage/http` (migrated out of YAML once,
  `yaml_migration_done`); the `http:` block in `configuration.yaml` mirrors them but is not what
  HA reads. If the stored ones are unusable, HA starts in **recovery mode** with them anyway. The
  loader also requires `ssl_profile` to be present, even without a certificate.
- `www/community/` came over empty (see "Frontend cards").

## Restoring

`/config` is the only state. On a rebuilt CT113 (or after losing `/config`):

1. `pct exec 113 -- systemctl stop docker-homeassistant` (it does not run without the marker
   anyway).
2. Unpack a Core backup (Settings → System → Backups; the archive's `homeassistant.tar.gz`) into
   `/var/lib/hass/config`, as root. Use a backup made by the pinned `hass_version` or older.
3. `pct exec 113 -- touch /var/lib/hass/migrated`, then
   `ansible-playbook playbooks/configure.yml --limit hass` starts it.

## Verify

- In CT113: `docker logs homeassistant` has no `http`/`trusted_proxies` errors and no recovery
  mode; `curl -s -o /dev/null -w '%{http_code}' http://[::1]:8123/api/` prints `401`.
- From outside the house, over IPv4 and IPv6: `openssl s_client -connect hass.us.example.org:443
  -servername hass.us.example.org` shows `*.us.example.org`; login (and MFA) and the companion
  app work; HA's log shows real client addresses, not the edge's.
- MQTT (CT112, user `hass`) is connected, and the Frigate entities update.

## Upgrading

Read the release notes (breaking changes), take a Core backup, bump `hass_version` and
`hass_image_digest` together (`defaults/main.yml`), rerun `playbooks/configure.yml --limit hass`.
A newer Core migrates `/config` on first start; going back means restoring that backup.

## Tests

`python3 -m unittest discover -s roles/tenant/hass/tests` evaluates the flake with a placeholder
`site.nix` (skipped without Nix).
