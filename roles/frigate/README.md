# Frigate

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
| 8555/tcp+udp | all IPv6 (`[::]`) | **dmz (VLAN 6)** | **WebRTC media** (DMZ ULA + public GUA) |

- Caddy bridges IPv6 -> IPv4 because Frigate's web UI binds IPv4 only.
- Frigate's nginx UIs (5000, 8971) are IPv4-only inside the container; go2rtc (1984, 8554, 8555) is IPv6-capable. That's why the UIs go via loopback/Caddy while go2rtc ports bind IPv6 directly.
- 8555 is published on all interfaces (to serve both the DMZ ULA and eth6's dynamic
  GUA) and kept off the backend by a **PVE firewall rule dropping 8555 on eth3**.
- WebRTC ICE **candidates** must be set in go2rtc config (`/mnt/frigate/config/config.yml`)
  to the DMZ ULA + public domain — under NAT the container can't self-discover them.

## Subnets
- VLAN 3 -> backend (mgmt + web UIs); LXC at `fd5a:715f:1edc:a703::22`
- VLAN 4 -> iot (for connecting to cameras)
- VLAN 6 -> dmz (WebRTC media / port 8555 only); LXC at `fd5a:715f:1edc:a706::22`
  - `frigate-webrtc.us.example.org`