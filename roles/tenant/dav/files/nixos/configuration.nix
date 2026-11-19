{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Public identity and the pinned image tag, rendered by Ansible (templates/site.nix.j2)
  # into the build/deploy copy of this tree; never committed. Secrets are NOT in here:
  # everything a Nix expression touches ends up in /nix/store, which is world-readable.
  site = import ./site.nix;

  # Host bind mount from the Proxmox side (mp0 in host_vars/dav.yml). Keep in step with it.
  dataDir = "/mnt/radicale"; # collections (ZFS)

  # Runtime-only credentials, written by Ansible (tasks/secrets.yml) as root:root from
  # the vault. A plain string on purpose: a Nix `path` literal would be copied into the
  # store.
  secretsDir = "/var/lib/dav/secrets";
  usersFile = "${secretsDir}/users"; # htpasswd, bcrypt

  # No TLS front on this guest: the public edge (roles/tenant/bunkerweb, CT110) terminates
  # TLS with the *.us wildcard and proxies to Radicale (plain HTTP, port 80) over the dmz.
  # It is the only client allowed to reach that port (see the firewall).
  edgeAddress = site.edgeAddress;
  # Radicale's container port, published on IPv4 loopback for the host relay below.
  originPort = 5232;

  # The image runs as uid/gid 1000 (`radicale`, upstream Dockerfile), which the
  # unprivileged CT maps to host uid 101000: host_vars/dav.yml owns the dataset to that.
  # Collections live below the image's VOLUME /var/lib/radicale.
  radicaleConfig = pkgs.writeText "radicale-config" ''
    [server]
    hosts = 0.0.0.0:${toString originPort}

    [auth]
    type = htpasswd
    htpasswd_filename = /etc/radicale/users
    htpasswd_encryption = bcrypt
    # Seconds added to every failed login, slowing online guessing (the edge rate limits too).
    delay = 2

    [rights]
    type = owner_only

    [storage]
    filesystem_folder = /var/lib/radicale/collections

    [logging]
    level = info
    mask_passwords = True
  '';

  # Refuse to start rather than let Docker create a missing bind source on the rootfs
  # and put the collections there (mp0 is a Proxmox bind mount, invisible to systemd).
  requireMount = pkgs.writeShellApplication {
    name = "dav-require-mount";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      mountpoint -q "$1" || { echo "$1 is not a mountpoint" >&2; exit 1; }
    '';
  };
in
{
  # Defaults are what we want: manageNetwork = false leaves systemd-networkd
  # enabled (we add the eth6 config below) and manageHostName = false picks the
  # hostname up from the /etc/hostname Proxmox writes.
  proxmoxLXC.enable = true;

  # ── Networking ────────────────────────────────────────────────────────────
  # eth6 is the dmz NIC (VLAN 6). The netif is created with ip6=manual, so nothing
  # addresses the interface until networkd does. Declaring it here replaces the
  # `pct exec … printf > /etc/systemd/network/…` step the Debian roles need. The
  # 10- prefix sorts ahead of anything Proxmox drops in; networkd takes the first
  # matching file. networkd processes RAs in userspace and installs the default route
  # itself, which matters here: Docker turns this guest into a forwarding host and the
  # kernel then ignores RAs (docker/for-linux#844).
  systemd.network.networks."10-eth6" = {
    matchConfig.Name = "eth6";
    networkConfig = {
      DHCP = "ipv6";
      IPv6AcceptRA = true;
    };
    # Pin the DHCPv6 client identity so the router's static lease (host_dav in
    # host_vars/prydwen.yml) can be written before this container has ever booted,
    # exactly as for seafile. DUIDType=vendor prepends the type ("00:02") and this data
    # supplies the enterprise number (00:00:ab:11 = 43793, systemd's) plus an 8-byte
    # identifier, giving DUID 00020000ab11726164696361006f. The identifier is "radica"
    # in ASCII followed by 0x006f (111, the vmid). IAID 0x72616469 ("radi") is pinned
    # for the same reason; odhcpd records it as the %-suffix on the lease's duid.
    dhcpV6Config = {
      DUIDType = "vendor";
      DUIDRawData = "00:00:ab:11:72:61:64:69:63:61:00:6f";
      IAID = 1918985321; # 0x72616469, the "%72616469" suffix on the lease's duid
    };
  };

  # Port 80 is Radicale's plain-HTTP origin, for the edge only. Radicale in the image
  # listens on IPv4 only here, and the edge reaches this guest over IPv6 — Docker would
  # hand an IPv6 publish to the container's IPv6 address, where nothing listens. So the
  # container is published on IPv4 loopback only, and a plain TCP relay on the host (nginx
  # stream, below) bridges [::]:80 to it — the same IPv6 -> IPv4 shape as seafile. Being
  # L4, the relay passes the edge's X-Forwarded-* headers through untouched. As a normal
  # host listener it is covered by nixos-fw, which admits port 80 from the edge's ULA
  # only (nixos-fw is rebuilt on every firewall (re)start, so -A stays idempotent).
  networking.firewall.extraCommands = ''
    ip6tables -A nixos-fw -p tcp --dport 80 -s ${edgeAddress} -j nixos-fw-accept
  '';

  services.nginx = {
    enable = true;
    streamConfig = ''
      server {
        listen [::]:80;
        proxy_pass 127.0.0.1:${toString originPort};
        proxy_timeout 10m;
      }
    '';
  };

  # ── Access ────────────────────────────────────────────────────────────────
  # No inbound SSH: Ansible manages this guest through the Proxmox host with
  # `pct exec` (group_vars/tenant_lxc.yml), and an operator gets a root shell with
  # `pct enter 111`. Overrides proxmox-lxc.nix's default of a socket-activated sshd.
  services.openssh.enable = false;

  # Ansible needs an interpreter on the target; NixOS ships none by default.
  environment.systemPackages = [ pkgs.python3 ];

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
    "d /var/lib/dav 0755 root root -"
    "d ${secretsDir} 0700 root root -"
  ];

  # ── Radicale ──────────────────────────────────────────────────────────────
  # Official upstream image (ghcr.io/kozea/radicale, built from the repository's own
  # Dockerfile, with the bcrypt extra). Only the htpasswd file is secret; the generated
  # config is read-only and holds nothing sensitive.
  virtualisation.oci-containers.containers.radicale = {
    image = "ghcr.io/kozea/radicale:${site.radicaleVersion}";
    log-driver = "json-file";
    cmd = [
      "--config"
      "/etc/radicale/config"
    ];
    volumes = [
      "${dataDir}:/var/lib/radicale" # collections on ZFS (mp0)
      "${radicaleConfig}:/etc/radicale/config:ro"
      "${usersFile}:/etc/radicale/users:ro"
    ];
    # IPv4 loopback only; the host relay (services.nginx.streamConfig) serves [::]:80.
    ports = [ "127.0.0.1:${toString originPort}:${toString originPort}" ];
    extraOptions = [
      "--read-only"
      "--tmpfs=/tmp"
      "--cap-drop=ALL"
      "--security-opt=no-new-privileges"
      "--health-cmd=curl -fsS -o /dev/null http://localhost:${toString originPort}/.web/ || exit 1"
      "--health-interval=30s"
      "--health-timeout=10s"
      "--health-retries=3"
      "--health-start-period=20s"
    ];
  };

  # A failed condition just skips the unit (not a failure), so the first boot of a fresh
  # image is quiet; Ansible starts the container once the users file exists.
  systemd.services.docker-radicale = {
    unitConfig.ConditionPathExists = usersFile;
    serviceConfig.ExecStartPre = lib.mkAfter [
      "${requireMount}/bin/dav-require-mount ${dataDir}"
    ];
  };
}
