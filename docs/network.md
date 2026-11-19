# Network Configuration
It has 2 1G NIC: `eno1` (`vmbr0`) and `enp3s0` (`vmbr1`).
`enp3s0` has native VLAN of 1 (default) and used as a communication for the various VMs.
`eno1` has native VLAN of 3 and used as a communication for the hypervisor itself.

## Subnets
- The ISP has a /56 prefix delegation, which is divided this way:
  - 1 (default VLAN) -> infra
  - 2 -> internal
  - 3 -> backend (also the Thread border router's backbone: CT112 `iot`)
  - 4 -> iot
  - 5 -> guest
  - 6 -> dmz
- IPv6 only, with exceptions
  - Backend, because of Windows
  - IoT, because of switches
  - Guest, just to be nice

## In-container Networking
- Centralize address provisioning in DHCP server (in router)
- Debian's built-in container networking is buggy for DHCPv6
  - It's supposed to use `ifupdown` with `dhclient`, but it doesn't mask `systemd-networkd.socket`, making a conflict and rendering DHCPv6 not functional sometimes.
  - The current solution is to let `networkd` take control by setting `ifupdown` as `manual`.
- In the future, I plan to deploy a local DNS nameserver that supports dynamic DNS, so that each client could do whatever they want (e.g., SLAAC) but the resulting address is still recorded centrally.
For now, DHCP is the database.
  - This is more elegant and circumvent the need to wait for the DHCP assigned address to settle.
  - If IPv4 is needed, port-forward it from the router's public IPv4, or use a proxy (Cloudflare L7 or Fly.io L4)

## On Docker Networking
- Docker networking has a central problem of inability to do dynamic IPAM (i.e., its container can't change address mid flight).
  - This makes it hard to rotate IPv6 prefix (GUA).
  - This is perhaps rooted in IPv4 based design, where there's always a NAT.
- However, it is still usable for static ULA (for ocal access).
- Due to this, if Docker is used, nest it inside an LXC container, and use one LXC container for a single routable logical project (e.g., Nextcloud, Frigate).
  - Duplicate Docker runtime is fine for now, since it's pretty light anyway.

## IPv4 Proxy
- Three alternatives for proxy that does not terminate TLS (L4)
  - Fly.io -> $2 per address + compute
  - Cloudflare Spectrum -> enterprise only
  - VPN
  - Full VM

## Public ingress
- WAN -> DMZ is closed by default; only explicitly named hosts are opened (`host_vars/prydwen.yml`).
- HTTP(S) services (`*.us`) are CNAMEs to `edge.us`, the BunkerWeb edge (CT110,
  `roles/tenant/bunkerweb`). IPv6 reaches the edge's GUA directly (`Allow-BunkerWeb`); IPv4
  arrives on the router's public wan4 address, is DNATed into the Jool NAT64 namespace and
  mapped by static NAT64 entries to the edge's ULA (the dmz stays IPv6-only; clients appear
  as `64:ff9b::<their IPv4>`). The edge terminates TLS with a
  wildcard certificate (DNS-01) and proxies to each origin's dmz ULA.
- Frigate's WebRTC media (TCP 8555) takes the same path; the edge relays it to go2rtc at L4.
- Exception reached directly, IPv6 only: Home Assistant (backend). Nextcloud (CT103) is shut down and no longer exposed; it is not managed by Ansible.
