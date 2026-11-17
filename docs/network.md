# Network Configuration
It has 2 1G NIC: `eno1` (`vmbr0`) and `enp3s0` (`vmbr1`).
`enp3s0` has native VLAN of 1 (default) and used as a communication for the various VMs.
`eno1` has native VLAN of 3 and used as a communication for the hypervisor itself.

## Subnets
- The ISP has a /56 prefix delegation, which is divided this way:
  - 1 (default VLAN) -> infra
  - 2 -> internal
  - 3 -> backend
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
  - If IPv4 is needed, use a proxy (Cloudflare L7 or Fly.io L4)

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