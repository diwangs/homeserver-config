# CLAT (Jool SIIT)

Shared outbound IPv4 for containers on this all-IPv6 hypervisor. Matrix's
container has zero IPv4 route by design; this gives it (and any future
container that opts in) real outbound reachability to genuinely IPv4-only
destinations, without making any container privileged.

This is the **CLAT** half of a 464XLAT pair. The router (`prydwen`) already runs
the **PLAT** half — a stateful NAT64 Jool instance in its own `jool` netns
(`roles/host/prydwen/templates/setupjool.sh.j2`). Read that file first; this role
mirrors its shape closely, adapted for Debian instead of OpenWrt and for SIIT
instead of stateful NAT64.

## Why this exists — and why not the alternatives

Explored first: `systemd-networkd` has no 464XLAT support (an open,
unimplemented feature request); nftables/iptables alone can't do family
translation (SIIT needs a real translator underneath, this isn't a rule you can
write); the kernel-native `ipxlat` netdevice is real but still RFC-stage
(submitted March 2026, unmerged, explicitly incomplete) — years from usable.
Jool's `jool_siit --netfilter` mode is the only real, shipping, TUN-less CLAT
today. `jool-dkms`/`jool-tools` are in Debian trixie's own `main` — no
third-party repo needed.

The alternative that needed no new infrastructure at all — adding a container a
second, plain DHCPv4 netif on the DMZ's existing `dmz4` VLAN, NAT44'd via the
router's existing WAN masquerade — was rejected in favor of this because the
project explicitly wants to scale to *multiple* future containers, and Jool's
EAMT aggregates: one route, one EAM entry, covers every container on the CLAT
bridge forever, vs. a NAT44 netif that would need to be added per container.

## Topology

```
Proxmox host (sentinel-lp)
│
├── vmbr2 — bare L2 bridge, no address of its own
│     containers' second netif attaches here (see "Enabling a container" below)
│
├── clat-lan ─╮ (LAN-facing veth, bridged onto vmbr2, no address)
│             │
│        [ netns: clat ]
│             │
│             ├─ clat-veth0 — 10.64.0.1/24 (containers' gateway)
│             ├─ jool_siit instance (--netfilter, pool6 64:ff9b::/96)
│             ├─ EAM: 10.64.0.0/24 <-> fd5a:715f:1edc:a746::/64
│             └─ clat-veth1 — fe80::4646, default route via fe80::46
│             │
├── clat-wan ─╯ (WAN-facing veth, fe80::46, point-to-point — NOT bridged)
│
└── existing default route (vmbr0, toward prydwen) — carries the now-translated
    IPv6 packet the rest of the way, same as any other outbound traffic
```

Two veth pairs, not one, unlike PLAT. PLAT's single veth carries both
directions because the traffic that needs translating is identified by a fixed
*destination* (`64:ff9b::/96`) — the router's own routing table sends it into
the netns, and the netns's own default route (via the same veth) is how the
now-real-IPv4 packet gets back out, since by then it's just normal internet
traffic. CLAT has no fixed destination to route on — the traffic needing
translation is identified by *source* (anything on the CLAT bridge), which
containers reach by plain L2 adjacency. That fully consumes the LAN-facing
interface being the containers' gateway; it has no spare capacity to also be
the way out, hence the second, WAN-facing pair.

### The bug this shape fixes (found and confirmed during the build)

Building the mirror image of PLAT's `route_nat64` is not optional. `route_nat64`
tells the router's main namespace "route `64:ff9b::/96` into the PLAT netns" —
the router's *way in*. This role initially built only the netns's own default
route (the *way out*) and skipped the equivalent way in: an explicit route on
**sentinel-lp's own main namespace** for `clat_eam_ipv6_prefix`, into the netns.

Without it, any packet destined for the EAM prefix — a reply, or the PLAT's own
state-tracking traffic — falls through to sentinel-lp's *default* route, which
points straight at the router. The router (correctly routing via its own
`route_clat`) sends it right back to sentinel-lp. Sentinel-lp, still missing the
specific route, sends it to its default route again. This is a genuine two-node
ping-pong, confirmed live: `tcpdump` showed the SYN and an immediate ICMPv6
"time exceeded", sourced from sentinel-lp itself, repeating for every
retransmission — the hop limit (starting at 62 after translation) burning down
to zero in about a dozen milliseconds of pure LAN-speed bouncing. The fix is the
route in `templates/setupclat.sh.j2` right after the netns setup:

```sh
ip -6 route add {{ clat_eam_ipv6_prefix }} via {{ clat_ns_wan_link_local }} dev "$wan_host"
```

## Two upstream Jool bugs, patched locally

Debian trixie ships `jool-dkms` 4.1.13-1.1, which fails to build on any kernel
new enough to have dropped two compat wrappers — including this host's PVE
7.0.x kernel:

1. `struct flowi4.flowi4_tos` renamed to `flowi4_dscp` — [NICMx/Jool#441](https://github.com/NICMx/Jool/pull/441),
   [Debian #1120527](https://bugs.debian.org/1120527), fixed upstream in jool 4.1.15.
2. `del_timer_sync` renamed `timer_delete_sync` — [Debian #1106551](https://bugs.debian.org/1106551),
   fixed upstream in jool 4.1.14.

Neither fix is in trixie yet, and jool-dkms isn't in trixie-backports either
(checked at build time). Rather than pull a newer package from `testing`/`sid`
and mix Debian suites on a production hypervisor, both fixes are applied as
patches (`files/jool-flowi4-dscp.patch`, `files/jool-timer-delete-sync.patch`)
onto the installed 4.1.13 source at `/usr/src/jool-4.1.13/` — the same tree DKMS
copies from for *every* kernel, current and future, so this is a one-time fix
that also covers any later kernel update on this host automatically.

**Remove `tasks/packages.yml`'s patch steps once Debian trixie ships
`jool-dkms >= 4.1.15`.** At that point `apt install` will just succeed on the
first attempt and both `ansible.posix.patch` tasks will report nothing to do —
this is designed to degrade gracefully, but the dead code is worth deleting once
the package catches up.

## First Ansible-managed change to sentinel-lp's own network config

`vmbr0`/`vmbr1` were provisioned out-of-band (the PVE installer, plus manual
VLAN config) — nothing else in this repo touches host networking. Confirmed at
build time: PVE does not read `/etc/network/interfaces.d/*` drop-ins (the GUI
itself stages into `/etc/network/interfaces.new` and won't pick up sourced
files), so `tasks/bridge.yml` goes through PVE's own network API instead —
`pvesh create` (staged write) then `pvesh set` (the same "Apply Configuration"
the GUI performs), applied live via `ifreload -a`, no reboot.

The bridge itself carries no address (`vmbr2`, plain — not `vmbr-clat`; PVE's
own iface-name validation rejects dashes on bridge-type interfaces, confirmed
at build time, so the plain numeric convention `vmbr0`/`vmbr1` already use is
the only broadly-supported form).

Also new: `net.ipv4.conf.all.forwarding` / `net.ipv6.conf.all.forwarding`,
turned on host-wide. Confirmed both read `0` before this — Proxmox never
needed forwarding before, since guest traffic is bridged at L2 straight to the
router, which does the actual routing. The WAN-facing veth pair relies on the
main namespace forwarding translated packets on toward its own existing
default route.

## Router-side prerequisite (`host_vars/prydwen.yml`)

A dedicated `/64` for the EAM mapping, plus an explicit route to sentinel-lp —
see the comment above `route_clat` in that file for why this needed a plain
static route rather than the usual `ip6assign`/`ip6hint` pattern (nothing here
is ever assigned to a router-local interface). Confirmed at build time: the
router holds a `/56` (`fd5a:715f:1edc:a700::/56`), of which only 7 of 256
possible `/64`s were in use — no new ISP delegation was needed.

## Enabling a container

This role only builds the host-side infrastructure — it doesn't touch any
tenant. A container opts in with a second, ordinary netif on `vmbr2`, using the
pattern roles/host/proxmox_lxc already provides for adding a NIC to an
already-created container: add it to `proxmox_lxc.netif` and set
`reconcile_netif: true` (`community.proxmox.proxmox` + `update: true` + a restart
on change). See `host_vars/matrix.yml` (net7) for the reference implementation. No LXC feature flags,
no capability grants, no change to `unprivileged: true` — it's the same
mechanism as any other `netN`.

**One thing that consumer needs to get right on its own side**: a resolver
configured to look up A records for destinations with no AAAA. Tuwunel's
`ip_lookup_strategy` had been set to `2` (Ipv6Only) as an earlier, narrower fix
for outbound federation — that setting never even attempts an A lookup, so it
would silently never use this new path at all. It needs to move to `4`
(Ipv6thenIpv4): try AAAA first (still correct and preferred for dual-stack
destinations — no reason to pay the CLAT/PLAT translation cost when native IPv6
already works), fall through to A only when there's truly no AAAA.

## Verification

```sh
# Host side
pvesh get /nodes/sentinel-lp/network            # vmbr2 listed
ip -4 addr show vmbr2                           # no address — bare L2 bridge
lsmod | grep jool_siit
ip netns list                                   # "clat"
ip netns exec clat jool_siit instance display   # pool6 64:ff9b::/96
ip netns exec clat jool_siit eamt display       # 10.64.0.0/24 <-> fd5a:715f:1edc:a746::/64
ip -6 route show fd5a:715f:1edc:a746::/64       # via fe80::4646 dev clat-wan — the fix above

# From inside an opted-in container
ip -4 addr show eth46                           # 10.64.0.x, gateway 10.64.0.1
curl -4 http://<a genuinely IPv4-only host>/     # should succeed
```

Confirmed working end-to-end during the build, from a temporary network
namespace simulating a container (`10.64.0.50`, default route via `10.64.0.1`):
a raw `curl -4` to a real, DNS-confirmed IPv4-only address succeeded
(`http=200`), with `tcpdump` at each hop (`clat-lan` → `clat-veth0` →
`clat-veth1`/`clat-wan` → `vmbr0`) showing the exact expected translation:
`10.64.0.50 → 104.16.185.241` (raw IPv4, as sent) became
`fd5a:715f:1edc:a746:3200:: → 64:ff9b::6810:b9f1` (translated IPv6, EAM and
pool6 both correctly applied) by the time it reached the real uplink.
