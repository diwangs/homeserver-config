# Zigbee, Thread and MQTT (`iot`)

The Zigbee radio stack, the Thread border router, Mosquitto and Zigbee2MQTT on LXC 112 in the
backend. They used to be Home Assistant add-ons (Silicon Labs Multiprotocol, Mosquitto,
Zigbee2MQTT) inside the HAOS VM; HA now reaches them over the network.

| | |
|---|---|
| vmid / hostname | 112 / `iot` (unprivileged, `nesting=1`) |
| Backend address | `fd5a:715f:1edc:a703::2d` (pinned DHCPv6 lease `host_iot`); IPv6 only |
| Radio | SkyConnect with the **multiprotocol RCP firmware** (left as is), Proxmox `dev0` by-id passthrough |
| Guest OS | NixOS; Mosquitto and Zigbee2MQTT native, the radio stack in Docker |
| Ports | 1883 MQTT (backend /64), 8080 Z2M frontend (home ULA /56, token), 8081 OTBR REST (HA only), 5353/udp mDNS |

## Layout

The radio is a plain RCP: the **Zigbee network (key, PAN IDs, frame counter) lives in zigbeed's
working directory**, not on the stick, and the Thread dataset lives in otbr-agent's settings.

```
SkyConnect ──dev0──▶ docker-multipan (host network)
                       cpcd ─┬─ zigbeed  :9999 EZSP ◀── zigbee2mqtt (adapter: ezsp) ──▶ mosquitto :1883 ◀── HA, Frigate
                             └─ otbr-agent wpan0 ⇄ eth3 (backbone), REST :8081 ◀── HA OTBR integration
                       mdnsd
```

- **Radio stack**: nixpkgs has no cpcd/zigbeed and its OTBR is not built for CPC, so the
  binaries come from the (deprecated) add-on image `homeassistant/amd64-addon-silabs-multiprotocol`,
  pinned by digest (`defaults/main.yml`). Its s6/bashio scripts need the Supervisor API, so
  `files/nixos/multipan-run.sh` replaces them: same daemons, same arguments, same OTBR forward
  firewall as add-on 2.4.6. It never runs the image's firmware flasher. The first daemon to
  exit takes the stack down and systemd restarts it.
- **Docker** has iptables management off (host network only), so it never sets FORWARD to DROP
  and cut Thread off from the backbone.
- **Zigbee2MQTT** keeps the `ezsp` driver it used before. Its `configuration.yaml` is rewritten
  from Nix on every start; secrets are `!secret` references into `/var/lib/zigbee2mqtt/secret.yaml`.
  Z2M only resolves those for the MQTT login, `network_key` and `frontend.auth_token`, so the PAN
  IDs and channel are in `site.nix` (they are broadcast over the air anyway). Devices and groups
  are in `devices.yaml`/`groups.yaml`.
- **Start gating**: `docker-multipan` and `zigbee2mqtt` only start once
  `/var/lib/iot/migrated` exists (written by `playbooks/migrate_iot.yml`), and the radio stack
  also refuses an empty zigbeed directory. A fresh guest can therefore never bring up a blank
  stack, and Z2M can never form a new network. Mosquitto starts as soon as its passwords exist.
- Same build/deploy shape as `roles/tenant/dav`: the flake in `files/nixos/` is the image,
  `tasks/build_template.yml` builds it on the workstation, `tasks/nixos.yml` runs `nixos-rebuild`.
  `tasks/host.yml` loads `tun`, `ip_set` and `ip_set_hash_net` on sentinel-lp, because an
  unprivileged CT cannot load modules.

## Vault

Already filled in from HAOS (read through the guest agent, never printed). The migration
re-checks every Zigbee value against the live HAOS state before it moves anything.

| Key | Value |
|---|---|
| `vault_iot_zigbee_network_key` | `advanced.network_key` of the HAOS Z2M config (16 numbers) |
| `vault_iot_zigbee_pan_id`, `_ext_pan_id`, `_channel` | `advanced.pan_id` / `ext_pan_id` / `channel` |
| `vault_iot_mqtt_password_{z2m,hass,frigate}` | broker passwords (random) |
| `vault_iot_z2m_frontend_token` | Z2M frontend token (random) |

Frigate reads its broker login from here too (`roles/tenant/frigate/vars/main.yml`: host
`hostvars['iot'].ansible_host`, user `frigate`, `vault_iot_mqtt_password_frigate`).

`iot_radio_by_id` (`host_vars/iot.yml`) is the SkyConnect's by-id path (the Multiprotocol add-on's
`device` option; same USB descriptors, same path on the Proxmox host).

## Migration

`playbooks/migrate_iot.yml` does the whole cutover from sentinel-lp: it reaches HAOS through the
QEMU guest agent of the HAOS VM (VM 200, since replaced by CT113 — `roles/tenant/hass`) and the Supervisor API, and CT112 with `pct`.
No HA backup or manual HAOS step is involved.

1. **Prepare** (no downtime):
   `ansible-playbook playbooks/configure.yml --limit prydwen` (lease `host_iot`),
   `ansible-playbook playbooks/init_proxmox.yml --limit sentinel-lp` (creates CT112 without the radio),
   `ansible-playbook playbooks/configure.yml --limit sentinel-lp,iot`. Mosquitto is up; the
   Zigbee services report that they are waiting for the migration.
   **Check Docker device access** in the unprivileged CT:
   `pct exec 112 -- docker run --rm --device=/dev/net/tun <multipan image> /bin/true`. If that
   fails with a device/BPF permission error, set `iot_multipan_privileged: true`
   (`host_vars/iot.yml`) and rerun `configure.yml --limit iot`.
   **Rehearse**: `ansible-playbook playbooks/migrate_iot.yml -e iot_rehearse=true` pulls and checks
   the state with the add-ons still running, and changes nothing.
2. **Attach the radio to CT112's config**: set `iot_radio_attached: true` (`host_vars/iot.yml`) and
   run `ansible-playbook playbooks/configure.yml --limit sentinel-lp`. This only adds `dev0`; it
   takes effect on CT112's next restart (until the cutover, a CT112 restart would fail to start).
3. **Cut over** (downtime starts): `ansible-playbook playbooks/migrate_iot.yml`. In order:
   - sets the Z2M, Multiprotocol and Mosquitto add-ons to `boot: manual` and stops them;
   - pulls zigbeed's state, the Thread dataset and Z2M's data (not its logs) into a root-only
     directory, never printing them;
   - checks the add-on version, radio path, baud rate and flow control against the pins
     (Z2M at most 2.14.3), and that the Zigbee parameters agree across the vault, the old config
     and the coordinator backup (adapter `ezsp`). Any mismatch stops it before the radio moves;
   - hot-unplugs the radio from VM 200 (power-cycling VM 200 through the agent if the unplug
     stays pending), restarts CT112, installs the state, devices.yaml and groups.yaml;
   - writes the marker and starts the radio stack and Z2M, then shows Z2M's startup log and the
     old Z2M settings that were not carried over (put the ones to keep into
     `iot_z2m_extra_settings` and rerun `configure.yml --limit iot`).
4. **Reconnect HA and Frigate**:
   - Settings → Devices & services → MQTT → *Reconfigure*: broker `fd5a:715f:1edc:a703::2d`,
     port 1883, user `hass`. Entities keep their IDs (discovery is keyed on the IEEE address).
   - Open Thread Border Router: remove the entry discovered from the add-on, add
     `http://[fd5a:715f:1edc:a703::2d]:8081`. The Thread integration should list the migrated
     dataset as preferred.
   - Frigate: `ansible-playbook playbooks/configure.yml --limit frigate` (it already points at
     the iot broker, see above).
5. **Clean up** after a few days: uninstall the three add-ons in HA.

**Rollback** (only soon after the cutover: the network's frame counter keeps advancing in CT112,
and the HAOS copy falls behind): stop `zigbee2mqtt` and `docker-multipan` in CT112,
`pct set 112 --delete dev0`, set `iot_radio_attached: false`, `qm set 200 --usb0 host=1-1`, and
start the three add-ons again (and set them back to start on boot). Frigate then needs the
old broker login back in `roles/tenant/frigate/vars/main.yml` (it was in the vault before
this migration; see git history).

## Verify

- `pct exec 112 -- journalctl -u docker-multipan -b`: cpcd reaches the radio, zigbeed and
  otbr-agent start, and nothing exits.
- `pct exec 112 -- journalctl -u zigbee2mqtt -b`: `Zigbee2MQTT started!`, the existing devices are
  listed, and there is **no** network formation or backup restore. Toggle a mains device and read
  a battery sensor in the frontend `http://[fd5a:715f:1edc:a703::2d]:8080`.
- `mosquitto_sub -h fd5a:715f:1edc:a703::2d -u hass -P … -t 'frigate/#' -v` shows Frigate events.
- From HA's network: `curl http://[fd5a:715f:1edc:a703::2d]:8081/node/state` returns `"leader"`
  or `"router"` once a Thread network exists.

## Upgrading

- **Zigbee2MQTT / Mosquitto**: they follow nixpkgs (`flake.lock`). Before bumping, check Z2M's
  settings `version` (`CURRENT_VERSION` in `lib/util/settings.ts`) against `version = 5` in
  `configuration.nix`.
- **Radio stack**: the image is deprecated and frozen at 2.4.6 (Debian bullseye). It is
  exposed internally only. The way out is Zigbee-only NCP firmware with `adapter: ember` and a
  separate Thread radio; that is a new migration, not an upgrade.

## Tests

`python3 -m unittest discover -s roles/tenant/iot/tests` evaluates the flake with a placeholder
`site.nix` (skipped without Nix).
