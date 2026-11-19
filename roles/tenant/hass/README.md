# Home Assistant (`hass`)

> Hostnames below use `example.org` for the hosting zone (`vault_public_domain`).

Home Assistant Core in **Container mode** on LXC 113 on the backend, public as
`hass.us.example.org` through the BunkerWeb edge (`roles/tenant/bunkerweb`), which terminates
TLS. It replaces the HAOS VM (VM 200, previously reached directly as `hass-us.example.org` with
its own TLS add-on). The Zigbee/Thread/MQTT add-ons had already moved to the `iot` CT
(`roles/tenant/iot`).

| | |
|---|---|
| vmid / hostname | 113 / `hass` (unprivileged, `nesting=1`) |
| backend address | `fd5a:715f:1edc:a703::24` + `192.168.3.24`, the VM's addresses (leases `host_hass_v6`/`_v4`, pinned DUID/IAID and MAC) |
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

## Migration (one-off)

`playbooks/migrate_hass.yml`, from sentinel-lp. It controls HAOS through the guest agent and
the `ha` CLI, copies `/mnt/data/supervisor/homeassistant` from the stopped VM's disk (mapped
read-only on the host), rewrites only the http settings and `external_url`, runs `check_config`
in the pinned image, and starts the container. The VM disk is never written.

The http settings HA actually uses live in `/config/.storage/http` (migrated out of YAML once,
`yaml_migration_done`); the `http:` block in `configuration.yaml` is rewritten too but is not
what HA reads. If the stored ones are wrong, HA starts in recovery mode with them anyway
(on HAOS that was port 443 with the add-on's certificate). The loader also requires
`ssl_profile` to be present, so it is kept.

1. Cloudflare: create `hass.us.example.org` as a CNAME to `edge.us.example.org` (DNS only).
   The `*.us` wildcard already covers it.
2. `ansible-playbook playbooks/init_proxmox.yml --limit sentinel-lp` (creates CT113; until the
   leases move it runs on dynamic addresses and HA stays stopped), then
   `ansible-playbook playbooks/configure.yml --limit hass`.
3. `ansible-playbook playbooks/migrate_hass.yml -e hass_rehearse=true`. It asserts that HAOS runs
   `hass_version`, that no add-on outside `hass_haos_dropped_addons` is started, and dry-runs the
   rewrite. Review what it prints: the add-on slugs (fix `hass_haos_dropped_addons` if the
   file manager or TLS add-on has another slug), the ports HAOS listens on (carry what you need
   into `hass_extra_*_ports`), and the `http:` block before/after.
4. `ansible-playbook playbooks/migrate_hass.yml`: freezes HAOS (`ha core stop`, VM shutdown,
   onboot off), copies, rewrites, checks and starts HA in CT113.
5. `ansible-playbook playbooks/configure.yml --limit prydwen`: the `::24`/`.24` leases move to
   CT113, `Allow-Hass` and the `hass-us` ddns updater go. Then `pct reboot 113` so the guest
   takes those addresses.
6. `ansible-playbook playbooks/configure.yml --limit hass,bunkerweb` (the edge site, and the
   firewall with the final addresses).
7. Delete the `hass-us` AAAA record in Cloudflare (ddns only stops updating it), and change the
   server URL in the companion apps to `https://hass.us.example.org`.
8. After it has run for a while: `qm destroy 200`.

**Rollback** (any step): `pct exec 113 -- systemctl stop docker-homeassistant`, revert
`host_hass_v6`/`host_hass_v4` and re-add `Allow-Hass`/the ddns service if step 5 already ran,
then `qm set 200 --onboot 1 && qm start 200`.

Verify:

- In CT113: `docker logs homeassistant` has no `http`/`trusted_proxies` errors or failed
  integrations; `curl -s -o /dev/null -w '%{http_code}' http://[::1]:8123/api/` prints `401`.
- From outside the house (phone off Wi-Fi), over IPv4 and IPv6: `openssl s_client -connect
  hass.us.example.org:443 -servername hass.us.example.org` shows `*.us.example.org`; logging in
  with the existing user (and MFA) works; the companion app reconnects; HA's logbook/`ip_ban`
  see the real client address, not the edge's.
- MQTT (CT112, user `hass`), the OTBR integration (`:8081`, admitted from `::24` only) and the
  Frigate entities update.
- `hass-us.example.org` no longer resolves; 8123 on `::24` is refused from outside the LANs.

## Upgrading

Read the release notes (breaking changes), take a Core backup, bump `hass_version` and
`hass_image_digest` together (`defaults/main.yml`), rerun `playbooks/configure.yml --limit hass`.
A newer Core migrates `/config` on first start; going back means restoring that backup.

## Tests

`python3 -m unittest discover -s roles/tenant/hass/tests` evaluates the flake with a placeholder
`site.nix` (skipped without Nix) and unit-tests the migration's `http:` rewrite
(`files/rewrite_http.py`).
