# `sentinel-lp` Infrastructure as Code
This is the repository containing the Terraform and Ansible files necessary for governing `sentinel-lp`.
It is a server that is optimized for mostly-idle workload (e.g., Omada, NAS, Home Assistant, and hosting in general). 
It has the following hardware:
- Intel i3 9100 CPU
- 32 GiB 2400 MT/s ECC RAM
- 1 TB Optane SSD (unused Optane parts)
- 3 x 12 TB WD Red (hot-swap)

## Ansible prerequisites
- SSH
  - Ansible authenticates with a dedicated automation key, `.ssh/sentinel-lp-ansible`
    (wired up via `private_key_file` in `ansible.cfg`), rather than an operator's
    personal key. The private half is gitignored; the public half is tracked at
    `.ssh/sentinel-lp-ansible.pub` and mirrored into `automation_pubkey` in
    `group_vars/all/vars.yml`.
  - Only `sentinel-lp` and `prydwen` accept SSH. The LXC guests run no sshd at all:
    Ansible reaches them through `sentinel-lp` with `pct exec`
    (`community.proxmox.proxmox_pct_remote`, see `group_vars/tenant_lxc.yml`), and a root
    shell is `pct enter <vmid>` on the host.
  - `managed_authorized_keys` (operator key + automation key) is reconciled onto
    prydwen every run by the `prydwen` role.
  - Bootstrapping: append the public key to `/root/.ssh/authorized_keys` on
    `sentinel-lp` by hand.
  - Rotating: regenerate the keypair, update `automation_pubkey`, re-copy it to
    `sentinel-lp`, then run `playbooks/configure.yml --limit prydwen`.
- Install `python3-proxmoxer`
- `frontpanel-pool` ZFS pool imported (not necessarily unlocked and mounted)
- Collections and roles: `ansible-galaxy install -r requirements.yml`

## Layout
```
ansible.cfg              inventory, roles_path, vault + automation key
inventory                groups: host, tenant_lxc (order matters), lxc_docker, lxc_nixos
group_vars/, host_vars/  per-group / per-host data; each guest's LXC definition is
                         `proxmox_lxc` in host_vars/<guest>.yml
site.yml                 imports the three stages below (tags: init_proxmox, init_tenant, configure)
playbooks/
  init_proxmox.yml       stage 1: host setup + create guests (host/proxmox_lxc, tenant/hass)
  init_tenant.yml        stage 2: immutable in-guest platform (docker_host, apt repos)
  configure.yml          reconcile resources/mounts + deploy apps; safe to re-run any time
  init_openwrt.yml       first-run provisioning of the prydwen router
  upgrade_lxc_dist.yml   in-place Debian major upgrade of one tenant
  migrate_hermes.yml     one-off: split the Matrix gateway out of hermes into CT108
  migrate_iot.yml        one-off: move the Zigbee/Thread state from the HAOS add-ons into CT112
roles/
  host/                 physical host, router, and guest provisioning
    proxmox_lxc, proxmox_templates, zfs, hd_idle, clat, prydwen,
    usbip, powertop      (usbip and powertop are not currently applied)
  common/               shared in-guest building blocks
    docker_host, portainer, cifs_mount, journald, disable_ssh
  tenant/               one role per tenant service
    hass, nas, omada, frigate, seedbox, immich, matrix, hermes, hermes_gateway,
    seafile, dav (Radicale), bunkerweb (the public HTTP(S) edge; see roles/tenant/bunkerweb/README.md),
    iot (Zigbee multiprotocol radio, Thread border router, Mosquitto, Zigbee2MQTT)
  maintenance/
    debian_dist_upgrade used by playbooks/upgrade_lxc_dist.yml
docs/network.md          network design notes
```
The four role directories are listed explicitly in `ansible.cfg`; playbooks use
short role names such as `proxmox_lxc` and `frigate`.
The `host` inventory group contains `sentinel-lp` and `prydwen`; platform-specific
plays target each host directly. Guests belong to `tenant_lxc`, with their
connection settings in `group_vars/tenant_lxc.yml`.
Home Assistant is a KVM tenant: `roles/tenant/hass` runs on `sentinel-lp` to
create its VM and reconcile resources, with no in-guest Ansible tasks. Its Zigbee, Thread
and MQTT add-ons moved to the `iot` CT (`roles/tenant/iot/README.md`); HA reaches them
over the backend.

Day to day: `ansible-playbook playbooks/configure.yml` (optionally `--limit <host>`).
Cold start: `playbooks/init_proxmox.yml` → set the DHCPv6 leases →
`playbooks/init_tenant.yml` → `playbooks/configure.yml` (see the playbook headers).

## Disk Configuration
- SSD is using ext4 and used for VM disks and such.
- HDDs are using ZFS and are configured in a RAID-Z configuration (24 TB effective size).
  - They are used for general data.
  - Encrypted with native encryption, not LUKS
- ZFS is encrypted with a TPM-bound key, with `tzpfms` (encrypt them with random password first, then change key using the provided command).
  - Initially, encrypt the dataset normally (i.e., when formatting, with passphrase)
  - Then run `zfs-tpm2-change-key` -> Change the passphrase-based key to TPM-based
    - Anchor it on PCR1 and PCR7, using sha256 (`-P sha256:1,7`)
    - Don't forget to produce backup key too (`-b file`)
    - Verify TPM2 key with `zfs-tpm2-load-key -n <dataset>`
    - Verify backup key with `zfs load-key -n <dataset> < file`
  - To revert to passphrase-based, use `zfs-tpm2-clear-key`
  - In case of catastrophic events, use backup key with `zfs load-key <dataset> < file` (backed up to Proton)

### Decrypt at Boot
- `tzpfms` extends load-key systemd service through a service.d directory (`zfs-load-key@.service.d`) 
- This assumes that the original service exists (`zfs-load-key@.service`)
- This is generated by `zfs-zed` on creation, which won't exist if you import the pool instead
  - Remedy: https://github.com/openzfs/zfs/issues/14571

## Power-Saving Measures
- Install `powertop`
- `powertop --auto-tune` (`roles/host/powertop`, not applied by any playbook yet)

# Services
## NAS
- Samba server using Cockpit. Technically a generic server dashboard, but since 45drives makes good NAS plugin for it, we'll use it. Inspired by apalrd
- Doesn't manage the disk themselves since this is already done by Proxmox's OpenZFS
- However, to be able to access files both from outside and inside the samba container, the owner UID should exist in both.
  - Otherwise, it will be owned by `nobody` due to unprivileged container.
- File permission: windows ACL, should have rwx?
- Creating shares for particular subdirectory: 
  - Create a new group to own the directory (but still owned by the shared UID user, frontpanel-owner)
  - Make the shared UID user part of that group
  - Create a new user as necessary for the share
  - Create the share (write as shared UID user and the new group)
    - Shared UID user -> so that it could be accessed without SMB
    - New group -> so that it could be accessed by the designated SMB user
- Mountpoint passthrough vs SMB mount
  - Mountpoint pros -> no network load, instant
  - Mountpoint cons -> user must be passed through (or be in privileged container), might have permission differences
  - SMB mount pros -> could translate UID and GID and permissions
  - SMB mount cons -> must be in privileged container, introduces network load, wait till NAS is online

## Omada
- TP-Link's SDN
- NOTE: reprovisioning will reset all port's config, pay attention to the 
adoption order 
  - Adopt internal, change config through backend, adopt backend
- TODO: backup to NAS, to be restored at setup

## Docker
- Problems
  - Doesn't have efficient use of IPv6: bridge network still have network 
  translation
  - Some deployment assumes some network configuration, especially bridge 
  creation and interface binding (e.g., Nextcloud AIO creates a new network 
  bridge that binds to 0.0.0.0)
- Solution: have two docker deployments
  - `docker` -> backend network
  - `dockerdmz` -> dmz network
