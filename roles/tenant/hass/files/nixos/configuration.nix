{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Public identity, client ranges and the pinned image, rendered by Ansible
  # (templates/site.nix.j2) into the build/deploy copy of this tree; never committed.
  # Secrets are NOT in here: everything a Nix expression touches ends up in /nix/store,
  # which is world-readable. HA keeps its own credentials in /config/.storage.
  site = import ./site.nix;

  # ── State ─────────────────────────────────────────────────────────────────
  # Keep in step with roles/tenant/hass/vars/main.yml (tests/ checks them).
  stateDir = "/var/lib/hass";
  # HAOS's /mnt/data/supervisor/homeassistant, copied in once at the migration.
  # On the rootfs (SSD), not ZFS: the recorder writes constantly.
  configDir = "${stateDir}/config";
  # Written by hand once configDir holds real state (README). An empty /config would
  # start onboarding and hand the owner account to whoever reaches the page first.
  migratedMarker = "${stateDir}/migrated";

  # HA's HTTP server, plain HTTP. No TLS on this guest: the public edge
  # (roles/tenant/bunkerweb, CT110) terminates TLS with the *.us wildcard and proxies here
  # over the router's dmz -> backend forwarding. HA trusts X-Forwarded-For from the edge
  # only (http.trusted_proxies in /config/.storage/http).
  httpPort = 8123;

  # Refuse to start on a /config without HA's auth store even if the marker is there
  # (e.g. the directory was wiped by hand): that would be a fresh, unclaimed instance.
  requireConfig = pkgs.writeShellApplication {
    name = "hass-require-config";
    text = ''
      for f in configuration.yaml .storage/auth .storage/core.config; do
        if [ ! -s "${configDir}/$f" ]; then
          echo "${configDir}/$f is missing: refusing to start Home Assistant without the migrated state" >&2
          exit 1
        fi
      done
    '';
  };

  portRules =
    proto: ports:
    lib.concatMapStrings (p: ''
      ip6tables -A nixos-fw -p ${proto} --dport ${toString p} -s ${site.lanPrefix} -j nixos-fw-accept
      iptables -A nixos-fw -p ${proto} --dport ${toString p} -s ${site.lanPrefix4} -j nixos-fw-accept
    '') ports;
in
{
  # Defaults are what we want: manageNetwork = false leaves systemd-networkd
  # enabled (we add the eth3 config below) and manageHostName = false picks the
  # hostname up from the /etc/hostname Proxmox writes.
  proxmoxLXC.enable = true;

  # ── Networking ────────────────────────────────────────────────────────────
  # eth3 is the backend NIC (VLAN 3), dual-stack like the HAOS VM was: the same link as
  # the iot CT (MQTT, the Thread border router, whose routes are advertised here by RA)
  # and Frigate. ip=manual/ip6=manual, so networkd owns addressing. The 10- prefix sorts
  # ahead of anything Proxmox drops in. networkd processes RAs in userspace and installs
  # the default route itself, which matters here: Docker turns this guest into a
  # forwarding host and the kernel then ignores RAs (docker/for-linux#844).
  systemd.network.networks."10-eth3" = {
    matchConfig.Name = "eth3";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    # The router's IPv4 reservation (host_hass_v4) is keyed on the MAC (pinned in
    # host_vars/hass.yml), so identify by it rather than by networkd's default DUID.
    dhcpV4Config.ClientIdentifier = "mac";
    # Pinned DHCPv6 client identity, so the router's static lease (host_hass_v6 in
    # host_vars/prydwen.yml, hostid 24: the address the VM had) can be written before the
    # container first boots, as for dav and iot. DUIDType=vendor prepends "00:02";
    # 00:00:ab:11 is systemd's enterprise number (43793), then "hasslx" in ASCII and
    # 0x0071 (113, the vmid), giving DUID 00020000ab11686173736c780071. IAID 0x68617373
    # ("hass") is the %-suffix odhcpd records on the lease's duid.
    dhcpV6Config = {
      DUIDType = "vendor";
      DUIDRawData = "00:00:ab:11:68:61:73:73:6c:78:00:71";
      IAID = 1751217011; # 0x68617373
    };
  };

  # Home Assistant runs with host networking (mDNS/SSDP/DHCP discovery, the Thread
  # backbone), so its listeners are ordinary host sockets covered by nixos-fw; there is
  # no Docker DNAT to bypass it. nixos-fw is rebuilt on every firewall (re)start, so -A
  # stays idempotent.
  #  - 8123 from the edge (proxied public traffic) and from the home LANs (direct access)
  #  - extra integration ports (HomeKit Bridge and the like) from the home LANs only
  networking.firewall = {
    # mDNS answers (zeroconf discovery, HomeKit/Matter advertisements).
    interfaces.eth3.allowedUDPPorts = [ 5353 ];
    extraCommands =
      ''
        ip6tables -A nixos-fw -p tcp --dport ${toString httpPort} -s ${site.edgeAddress} -j nixos-fw-accept
      ''
      + portRules "tcp" ([ httpPort ] ++ site.extraTcpPorts)
      + portRules "udp" site.extraUdpPorts;
  };

  time.timeZone = "America/New_York";

  # ── Access ────────────────────────────────────────────────────────────────
  # No inbound SSH: Ansible manages this guest through the Proxmox host with
  # `pct exec` (group_vars/tenant_lxc.yml), and an operator gets a root shell with
  # `pct enter 113` (where /config is ${configDir}; HAOS's File editor add-on is gone).
  # Overrides proxmox-lxc.nix's default of a socket-activated sshd.
  services.openssh.enable = false;

  # Ansible needs an interpreter on the target; NixOS ships none by default. curl and
  # sqlite are for checking the API and inspecting the recorder database by hand.
  environment.systemPackages = [
    pkgs.python3
    pkgs.curl
    pkgs.sqlite
  ];

  # ── Nix ───────────────────────────────────────────────────────────────────
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # ── Docker ────────────────────────────────────────────────────────────────
  # Same daemon settings the Debian guests get from roles/common/docker_host:
  # NAT66 via ip6tables, IPv6 on the bridges, and per-container log rotation
  # (Docker's default never rotates; a single container log once filled a rootfs).
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      ip6tables = true;
      default-network-opts.bridge."com.docker.network.enable_ipv6" = "true";
      log-driver = "json-file";
      log-opts = {
        max-size = "50m";
        max-file = "3";
      };
    };
  };

  virtualisation.oci-containers.backend = "docker";

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 root root -"
    "d ${configDir} 0700 root root -"
  ];

  # ── Home Assistant ────────────────────────────────────────────────────────
  # The official Container-mode image, pinned by tag and digest (defaults/main.yml). It
  # runs as root inside the container (an unprivileged CT maps that to host uid 100000).
  # Not --privileged: there is no USB radio or Bluetooth here (the Zigbee/Thread radio is
  # in the iot CT), and Docker's default capabilities include NET_RAW for DHCP discovery
  # and ping.
  virtualisation.oci-containers.containers.homeassistant = {
    image = site.image;
    log-driver = "json-file";
    volumes = [ "${configDir}:/config" ];
    environment.TZ = config.time.timeZone;
    extraOptions = [
      "--network=host"
      "--health-cmd=curl -fsS -o /dev/null http://localhost:${toString httpPort}/manifest.json || exit 1"
      "--health-interval=30s"
      "--health-timeout=10s"
      "--health-retries=3"
      "--health-start-period=300s"
    ];
  };

  # A failed condition just skips the unit (not a failure), so the first boot of a fresh
  # image is quiet; Ansible starts the container once the marker exists.
  systemd.services.docker-homeassistant = {
    unitConfig.ConditionPathExists = migratedMarker;
    serviceConfig.ExecStartPre = lib.mkAfter [ "${requireConfig}/bin/hass-require-config" ];
  };
}
