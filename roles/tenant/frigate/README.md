# Frigate

> Hostnames below use `example.org` (the hosting zone, `vault_public_domain`) and
> `example.com` (the Matrix `server_name`, `vault_matrix_server_name`) as
> placeholders; the real values are in `group_vars/all/vault.yml`.

## Network Configuration

The container runs on a Docker **bridge** (`frigate-net`, NAT66), not host networking.
Each port is published to a specific host address so services land on the right VLAN:

| Port | Host bind | Reachable on | Purpose |
|------|-----------|--------------|---------|
| 5000 | `127.0.0.1` | via Caddy only | Unauth web UI (+ MSE, WebRTC signaling). IPv4-only inside; Caddy fronts it. |
| 5050 | `[fd5a:715f:1edc:a703::22]` | backend (VLAN 3) | Caddy IPv6 -> IPv4 proxy to 5000 |
| 8971 | `127.0.0.1` | LXC-local only | Authenticated web UI. IPv4-only inside the container, so not published on the IPv6 backend; reachable only from within the LXC. |
| 8554 | `[fd5a:715f:1edc:a703::22]` | backend (VLAN 3) | go2rtc RTSP restream (IPv6-capable inside) |
| 1984 | `[fd5a:715f:1edc:a703::22]` | backend (VLAN 3) | go2rtc web UI / API (IPv6-capable inside) |
| 8555/tcp+udp | all IPv6 (`[::]`) | **dmz (VLAN 6)** | **WebRTC media**: LAN on the DMZ ULA; remote over TCP via the edge |

- Caddy bridges IPv6 -> IPv4 because Frigate's web UI binds IPv4 only.
- Frigate's nginx UIs (5000, 8971) are IPv4-only inside the container; go2rtc (1984, 8554, 8555) is IPv6-capable. That's why the UIs go via loopback/Caddy while go2rtc ports bind IPv6 directly.
- 8555 is published on all interfaces and kept off the backend by a **PVE firewall
  rule dropping 8555 on eth3**. The router forwards nothing from the internet to it.
- **Remote WebRTC is TCP-only, through the BunkerWeb edge.** `frigate-webrtc.us.example.org` is a
  CNAME to `edge.us.example.org`; the router forwards tcp 8555 to the edge (CT110, IPv6 directly
  and IPv4 through the router's Jool NAT64), whose nginx stream server relays it to `[fd5a:715f:1edc:a706::22]:8555`.
  No UDP remotely, so media stalls more on lossy networks; LAN clients keep UDP on the dmz ULA.
- WebRTC ICE **candidates** are set in the go2rtc section of Frigate's config, from
  `frigate_webrtc_candidates` (`defaults/main.yml`): the dmz ULA for LAN clients (UDP or TCP),
  and `frigate-webrtc.us.example.org:8555` for remote clients (via the edge, TCP only).
  Remote clients try the candidate over UDP first, get no answer (only TCP is forwarded),
  and ICE falls back to TCP on the same candidate.

## Config

Frigate's config (`/mnt/frigate/config/config.yaml` on the CIFS share, `/config` in the
container) is **owned by this repo**: `templates/config.yaml.j2`, rendered by
`tasks/frigate.yml`. Edits made in Frigate's UI are overwritten on the next run, so change
the template instead. A changed config restarts Frigate (handler); the previous file is kept
beside it as a timestamped backup (`backup: true`). Credentials come from the vault:
`vault_frigate_cam_indoor_stream` / `vault_frigate_cam_outdoor_stream` (full RTSP URLs,
camera logins included), `vault_frigate_mqtt_host`, `vault_frigate_mqtt_user` and
`vault_frigate_mqtt_password`.

## Subnets
- VLAN 3 -> backend (mgmt + web UIs); LXC at `fd5a:715f:1edc:a703::22`
- VLAN 4 -> iot (for connecting to cameras)
- VLAN 6 -> dmz (WebRTC media / port 8555 only); LXC at `fd5a:715f:1edc:a706::22`
  - `frigate-webrtc.us.example.org` is a CNAME to the BunkerWeb edge, not this guest (see above)

NOTE: in multi-interface host, the DHCP server (`odhcpd`) uses both DUID and MAC to distinguish interfaces