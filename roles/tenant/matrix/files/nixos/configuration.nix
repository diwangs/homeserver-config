{ config, lib, pkgs, ... }:

let
  # Public identity, rendered from the vault by Ansible (templates/site.nix.j2)
  # into the build/deploy copy of this tree; never committed.
  site = import ./site.nix;

  # server_name is the Matrix identity suffix (@user:<serverName>). It is baked into
  # the database and cannot be changed without a wipe — deliberately changed once
  # already, from the hosting zone, while the server held no real data.
  serverName = site.serverName;
  # The host that actually runs the homeserver. Distinct from serverName: the apex
  # delegates here via /.well-known/matrix/server, which is served out-of-band by
  # Cloudflare — see roles/matrix/README.md. Changing this is safe (it is only where
  # the server is reached); changing serverName above is not.
  hostName = site.hostName;

  # The public edge (roles/tenant/bunkerweb, CT110): terminates TLS for the hostname and
  # is the only client allowed to reach the plain-HTTP origin below.
  edgeAddress = site.edgeAddress;

  # Bind mount of /mnt/frontpanel-pool/frontpanel-dataset/Backup/matrix on the
  # Proxmox host; see roles/matrix/tasks/config_lxc.yml.
  backupPath = "/mnt/matrix-backup";
in
{
  # Defaults are what we want: manageNetwork = false leaves systemd-networkd
  # enabled (we add the eth6 config below) and manageHostName = false picks the
  # hostname up from the /etc/hostname Proxmox writes.
  proxmoxLXC.enable = true;

  # ── Networking ────────────────────────────────────────────────────────────
  # eth6 is the dmz NIC (VLAN 6). The netif is created with ip6=manual, so nothing
  # addresses the interface until networkd does. Declaring it here replaces the
  # `pct exec … printf > /etc/systemd/network/…` dance the Debian roles need, since
  # Proxmox cannot write NixOS network config the way it writes /etc/network/interfaces.
  # The 10- prefix sorts ahead of anything Proxmox drops in; networkd takes the
  # first matching file.
  systemd.network.networks."10-eth6" = {
    matchConfig.Name = "eth6";
    networkConfig = {
      DHCP = "ipv6";
      IPv6AcceptRA = true;
    };
    # Pin the DHCPv6 client identity so the router's static lease can be written
    # before this container has ever booted. Every other tenant's lease holds a
    # *discovered* DUID: theirs is derived from a random machine-id, so the guest
    # has to boot and be observed first — and it is only reachable once the lease
    # exists. That chicken-and-egg is why init_proxmox.yml documents the lease as a
    # manual step. It does not apply here, because a NixOS guest carries its network
    # config in the image rather than receiving it over SSH afterwards.
    #
    # DUIDType=vendor prepends the type ("00:02") and this data supplies the
    # enterprise number (00:00:ab:11 = 43793, systemd's) plus an 8-byte identifier,
    # giving DUID 00020000ab116d6174726978006a — same 14-byte DUID-EN shape the
    # other systemd guests produce. The identifier is "matrix" in ASCII followed by
    # 0x006a (106, the vmid), so it is self-evidently assigned rather than random.
    # IAID 0x6d617472 ("matr") is pinned for the same reason; odhcpd records it as
    # the `%`-suffix on the lease's duid.
    dhcpV6Config = {
      DUIDType = "vendor";
      DUIDRawData = "00:00:ab:11:6d:61:74:72:69:78:00:6a";
      IAID = 1835103346; # 0x6d617472, the "%6d617472" suffix on the lease's duid
    };
  };

  # eth46 (464XLAT): outbound-only IPv4 for genuinely IPv4-only destinations, via
  # the CLAT built in roles/clat/ (see that role's README). Static, not DHCP —
  # nothing serves DHCP on this bridge, by design; it's a small, fixed set of
  # containers, not a dynamic network. .10 has no significance beyond being an
  # address distinct from the gateway (.1).
  systemd.network.networks."10-eth46" = {
    matchConfig.Name = "eth46";
    address = [ "10.64.0.10/24" ];
    gateway = [ "10.64.0.1" ];
  };

  networking = {
    domain = serverName;
    # Port 80 (the plain-HTTP origin) is open to the edge only. Nothing else listens;
    # TLS, :443 and the public address all belong to roles/tenant/bunkerweb. nixos-fw
    # is flushed and rebuilt on every firewall (re)start, so -A stays idempotent.
    firewall.extraCommands = ''
      ip6tables -A nixos-fw -p tcp --dport 80 -s ${edgeAddress} -j nixos-fw-accept
    '';
  };

  # ── Access ────────────────────────────────────────────────────────────────
  # No inbound SSH: Ansible manages this guest through the Proxmox host with
  # `pct exec` (group_vars/lxc.yml in the Ansible repo), and an operator gets a root
  # shell with `pct enter <vmid>`. Overrides proxmox-lxc.nix's default of a
  # socket-activated sshd.
  services.openssh.enable = false;

  # Ansible needs an interpreter on the target; NixOS ships none by default.
  environment.systemPackages = [ pkgs.python3 ];

  # ── Nix ───────────────────────────────────────────────────────────────────
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    # Tuwunel is a large Rust build; without this the container compiles it itself.
    extra-substituters = [ "https://cache.tuwunel.chat" ];
    extra-trusted-public-keys = [
      "cache.tuwunel.chat-1:ZafUaXiRMozDa9N2SWim6EdzH0EEjWjwfvlTxXvcjLA="
    ];
  };

  # ── Tuwunel ───────────────────────────────────────────────────────────────
  services.matrix-tuwunel = {
    enable = true;
    settings.global = {
      server_name = serverName;
      # Loopback only — nginx below is the origin the edge proxies to.
      address = [ "::1" "127.0.0.1" ];
      port = [ 6167 ];

      allow_federation = true;
      allow_registration = false;

      # Tuwunel's default (5, Ipv4thenIpv6) resolves the A record and uses it
      # whenever one exists, only falling back to AAAA if the A *lookup* fails —
      # not if connecting to it fails. Before eth46/CLAT existed, this made
      # outbound federation to any dual-stack or IPv4-only remote fail with
      # "Network unreachable" even when perfectly reachable over IPv6, since
      # tuwunel never tried the AAAA record at all (confirmed via `debug ping
      # matrix.org`: failed under the default, succeeded under Ipv6Only).
      #
      # Now that eth46 gives real outbound IPv4 (see roles/clat/README.md),
      # Ipv6Only would be a strict regression: it never attempts an A lookup at
      # all, so tuwunel would never even discover that a genuinely IPv4-only
      # destination needs that path. Ipv6thenIpv4 keeps AAAA preferred (no reason
      # to pay the CLAT/PLAT translation cost when native IPv6 already works)
      # while letting true IPv4-only destinations fall through correctly.
      ip_lookup_strategy = 4; # Ipv6thenIpv4

      # RocksDB online backups land on the encrypted RAID-Z pool via the bind mount.
      # NOTE: database_path is set by the module itself from stateDirectory and must
      # not be overridden here — the module asserts on it.
      database_backup_path = backupPath;
      database_backups_to_keep = 4; # weekly cadence -> ~1 month of history

      # Run on SIGUSR2. This is what makes a scheduled backup possible at all:
      # tuwunel has no internal scheduler, and admin commands otherwise require
      # posting into the admin room with an access token.
      admin_signal_execute = [ "server backup-database" ];

      well_known = {
        client = "https://${hostName}";
        server = "${hostName}:443";
      };
    };
  };

  # The upstream unit is hardened with ProtectSystem = "strict", which makes the
  # whole filesystem read-only apart from its StateDirectory. Without this the
  # backup fails at write time rather than at startup, so it would look healthy
  # right up until the first Sunday.
  systemd.services.tuwunel.serviceConfig = {
    # The "-" prefix makes a missing path non-fatal. Without it systemd cannot set
    # up the namespace and the unit dies with 226/NAMESPACE before it ever runs —
    # so the homeserver would refuse to start whenever the backup mount is absent.
    # That is not hypothetical here: mp0 only appears after the container is
    # restarted, and the ZFS pool behind it is TPM-unlocked at boot (see the repo
    # README). A failed backup is far preferable to a homeserver that will not boot.
    ReadWritePaths = [ "-${backupPath}" ];
    # The upstream module sets DynamicUser = true. A transient uid cannot be
    # expressed in the host-side LXC idmap, so backups would land owned by some
    # arbitrary high uid on the ZFS pool instead of `diwangs`. Everything
    # DynamicUser implies (ProtectSystem=strict, PrivateTmp, RemoveIPC, …) is
    # already set explicitly by the module, so turning it off costs no hardening.
    DynamicUser = lib.mkForce false;
  };

  # Pin the service uid so the host-side idmap (u 1000 1000 1, see
  # tasks/init_passthrough_matrix_user.yml) lines up and backup files land owned by
  # `diwangs` on the host.
  users.users.tuwunel.uid = 1000;
  users.groups.tuwunel.gid = 1000;

  # ── Weekly backup trigger ─────────────────────────────────────────────────
  systemd.services.tuwunel-backup = {
    description = "Trigger a Tuwunel RocksDB online backup";
    # Signalling a stopped server is a no-op that would silently skip the week.
    unitConfig.ConditionPathExists = "/run/tuwunel";
    serviceConfig = {
      Type = "oneshot";
      # --kill-whom=main: the default (all) would signal every process in the
      # cgroup, and only the main process handles SIGUSR2.
      ExecStart = "${pkgs.systemd}/bin/systemctl kill --kill-whom=main --signal=SIGUSR2 tuwunel.service";
    };
  };

  systemd.timers.tuwunel-backup = {
    description = "Weekly Tuwunel database backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:00:00";
      Persistent = true; # catch up if the host was down at 04:00
      RandomizedDelaySec = "15m";
    };
  };

  # ── Origin for the edge ───────────────────────────────────────────────────
  # TLS is terminated by roles/tenant/bunkerweb (one *.us wildcard over DNS-01), which
  # proxies here over plain HTTP on the dmz. So there is no certificate, no ACME and no
  # :443/:8448 on this guest any more. Federation goes through :443 on the edge only:
  # the delegation (.well-known/matrix/server, here and at the apex) already says :443.
  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;

    virtualHosts.${hostName} = {
      # [::] rather than the ULA: the DHCPv6 address may not exist yet when nginx
      # starts. The firewall above is what limits this listener to the edge.
      listen = [
        { addr = "[::]"; port = 80; }
      ];

      locations."/_matrix/" = {
        proxyPass = "http://[::1]:6167";
        extraConfig = ''
          # Must be >= tuwunel's max_request_size (20 MB default) or large media
          # uploads fail at the proxy with 413 before tuwunel ever sees them.
          client_max_body_size 20M;
        '';
      };

      # Served here as well as at the apex, for clients that were handed this host
      # directly rather than following the delegation.
      locations."/.well-known/matrix/server".extraConfig = ''
        default_type application/json;
        return 200 '{"m.server": "${hostName}:443"}';
      '';
      locations."/.well-known/matrix/client".extraConfig = ''
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver": {"base_url": "https://${hostName}"}}';
      '';
    };
  };

  # The release this container was first built against; do not bump on upgrade.
  # FlakeHub "0.1" currently resolves to the 26.11 unstable line.
  system.stateVersion = "26.11";
}
