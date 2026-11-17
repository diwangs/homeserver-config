# Immich

Photo/video management on LXC 105 (backend VLAN 3, LAN-only). Stack: immich-server,
immich-machine-learning, valkey, postgres (VectorChord) — pinned via
`immich_version` in `defaults/main.yml`; check the release's `docker-compose.yml`
before bumping (the DB image moves in lockstep with some releases).

## Network

| Port | Host bind | Reachable on | Purpose |
|------|-----------|--------------|---------|
| 2283 | `[fd5a:715f:1edc:a703::26]` | backend (VLAN 3) | Immich web UI + API |
| 9443 | `[fd5a:715f:1edc:a703::40]` | backend (VLAN 3) | Portainer (ipvlan, 40 - 4f) |

- No Caddy: immich-server listens on IPv6 directly (`IMMICH_HOST=::`), so the
  NAT66 DNAT of the published port lands somewhere that answers — unlike
  frigate's IPv4-only nginx. If this ever breaks, clone frigate's Caddy proxy.
- LAN-only by design; phone sync away from home needs VPN.

## Storage (hybrid, for HDD spindown)

| Data | Where | Why |
|------|-------|-----|
| `library/ upload/ profile/ backups/` | ZFS RAID-Z (`frontpanel-dataset/Immich` → `mp0` → `/mnt/immich` → `/data`) | Irreplaceable originals + DB dumps: redundancy + encryption |
| `thumbs/ encoded-video/` | `/opt/immich/{thumbs,encoded-video}` (Optane rootfs) over `/data/...` | Regenerable, hot path — browsing must not wake the WD Reds |
| Postgres data, ML model cache | named volumes (Optane rootfs) | Constant writes stay off the HDDs |

Opening a full-res original (or playing a non-transcoded video) reads ZFS and
spins the disks up — expected. Timeline scrolling stays on Optane.

Plain dirs (not named volumes) for thumbs/encoded-video: Immich's FAQ says named
volumes don't support non-root access, and immich-server runs as uid 1000.

The ZFS-side `/mnt/immich/{thumbs,encoded-video}` are only the mount points the
Optane dirs sit on and must stay empty. Anything written there (by a container
running without the overlay) is invisible to Immich, so Immich never deletes it:
the November 2026 move to Optane copied rather than moved, and the stale copies
turned into orphans as assets were deleted. The role refuses to deploy while either
dir has entries; the failure message has the cleanup command.

## uid 1000 passthrough

immich-server runs as `user: "1000:1000"`; the LXC idmaps uid/gid 1000 ↔ host
1000 (`idmap` in `host_vars/immich.yml`), so the whole upload tree on ZFS is
owned by `diwangs` on the host — nextcloud's www-data pattern, identity-mapped.
Don't create files under `/mnt/immich` as container root (e.g. via `docker exec`):
they'd surface as host uid 100000 and mix ownership.

## QSV hardware transcoding

The iGPU render node is passed with Proxmox-native `dev0:
/dev/dri/renderD128,gid=104` (`config_lines` in `host_vars/immich.yml`) — works for this *unprivileged* CT,
unlike frigate's raw `lxc.cgroup2`/`lxc.mount.entry` lines (which is why frigate
is privileged). immich-server gets the device + supplementary gid 104. The GPU is
shared with frigate; i915 timeshares fine.

Enable in Admin → Video transcoding settings → Hardware acceleration → **Quick
Sync** (off by default); use a slower preset than for software encoding. Default
policy "Required" only transcodes HDR / non-yuv420p / non-H.264 (e.g. iPhone
HEVC) to 720p H.264. ML inference stays on CPU (OpenVINO out of scope).

## Backup — scope decision

**No borg job** (hence no `fuse=1`). Immich dumps its DB nightly at 02:00 (keeps
14) into `/data/backups/` = the ZFS pool; confirm under Admin → Settings →
Backup after install. Originals rely on RAID-Z redundancy + ZFS encryption —
**no off-pool copy**. If that changes, mirror nextcloud's borg mount pattern.

## First run

1. Vault: `vault_immich_db_password` (alphanumeric only).
2. `playbooks/init_proxmox.yml` → set the ::26 static DHCPv6 lease → `ansible immich -m ping`
   → `playbooks/init_tenant.yml` → `playbooks/configure.yml`.
3. First `playbooks/configure.yml` only: mp0 lands while the CT runs — `pct reboot 105`,
   check `pct exec 105 -- findmnt /mnt/immich`, rerun `playbooks/configure.yml` so
   immich-server starts with ZFS actually backing `/data`.
4. Create admin at `http://[fd5a:715f:1edc:a703::26]:2283`; confirm backup
   schedule; enable Quick Sync.
