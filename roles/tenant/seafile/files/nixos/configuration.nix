{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Public identity and the pinned image tags, rendered by Ansible (templates/site.nix.j2)
  # into the build/deploy copy of this tree; never committed. Secrets are NOT in here:
  # everything a Nix expression touches ends up in /nix/store, which is world-readable.
  site = import ./site.nix;

  hostName = site.hostName;

  # Host bind mounts from the Proxmox side (mp0/mp1 in host_vars/seafile.yml). Keep in
  # step with those lines.
  dataDir = "/mnt/seafile"; # library blocks, config, avatars (ZFS)
  backupDir = "/mnt/seafile-backup"; # nightly SQL dumps (ZFS)

  # Runtime-only credentials, written by Ansible (tasks/secrets.yml) as root:root 0400
  # from the vault. Passed to `docker run --env-file`, so the values never appear in a
  # unit file, the Nix store, or the image. They are plain strings on purpose: a Nix
  # `path` literal would be copied into the store.
  secretsDir = "/var/lib/seafile/secrets";
  mysqlEnvFile = "${secretsDir}/mysql.env"; # MYSQL_ROOT_PASSWORD
  seafileEnvFile = "${secretsDir}/seafile.env"; # DB/JWT/admin credentials

  # Name is fixed by upstream's compose files (seafile-net).
  network = {
    name = "seafile-net";
    subnet = "fd00:5ea4:11::/64"; # container-internal, NAT66'd to the host
  };

  # Seafile CE needs these on seafile-net; the container names are the DNS names the
  # upstream docker/ce stack uses, so they are kept.
  dbHost = "seafile-mysql";
  redisHost = "seafile-redis";

  # Static TLS front instead of upstream's caddy-docker-proxy, so the one container
  # exposed to the internet does not get /var/run/docker.sock (root on the guest).
  # Caddy obtains and renews the certificate itself (ACME HTTP-01 / TLS-ALPN-01, both
  # reach this guest directly or through the Fly IPv4 proxy, which passes TLS through).
  # Seafile's own nginx stays plain HTTP on seafile-net.
  caddyfile = pkgs.writeText "Caddyfile" ''
    {
      email ${site.acmeEmail}
    }

    ${hostName} {
      reverse_proxy seafile:80
    }
  '';

  # Containers whose unit must not run before Ansible has installed their env file.
  # A failed condition just skips the unit (not a failure), so the first boot of a fresh
  # image is quiet; Ansible starts the stack once the credentials exist.
  whenSecrets = files: { ConditionPathExists = files; };

  # Compose's `depends_on: condition: service_healthy`, which systemd ordering alone
  # (what oci-containers' dependsOn gives) does not express: "started" there only means
  # `docker run` was launched, not that MariaDB accepts connections.
  waitHealthy = pkgs.writeShellApplication {
    name = "seafile-wait-healthy";
    runtimeInputs = [
      config.virtualisation.docker.package
      pkgs.coreutils
    ];
    text = ''
      name=$1
      for _ in $(seq 1 120); do
        status=$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || true)
        [ "$status" = healthy ] && exit 0
        sleep 5
      done
      echo "$name did not become healthy within 10 minutes" >&2
      exit 1
    '';
  };

  # Refuse to start rather than let Docker create a missing bind source on the rootfs
  # and put the library there (mp0 is a Proxmox bind mount, invisible to systemd).
  requireMount = pkgs.writeShellApplication {
    name = "seafile-require-mount";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      mountpoint -q "$1" || { echo "$1 is not a mountpoint" >&2; exit 1; }
    '';
  };

  dbDump = pkgs.writeShellApplication {
    name = "seafile-db-dump";
    runtimeInputs = [
      config.virtualisation.docker.package
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gzip
      pkgs.util-linux
    ];
    text = builtins.readFile ./seafile-db-dump.sh;
  };

  # Created by the network unit below; everything on seafile-net waits for it.
  networkUnit = "seafile-docker-network.service";

  # Fields shared by every container: private bridge, restart handled by systemd
  # (Restart=on-failure from the oci-containers module), logs to Docker's rotated
  # json-file store (see daemon settings) rather than the journal. The database and
  # cache always start; the application pair is held back while site.startApp is false
  # (a migration restores the dump into the empty database first, see README).
  common = {
    log-driver = "json-file";
    networks = [ network.name ];
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
    # Pin the DHCPv6 client identity so the router's static lease (host_seafile in
    # host_vars/prydwen.yml) can be written before this container has ever booted,
    # exactly as for matrix. DUIDType=vendor prepends the type ("00:02") and this data
    # supplies the enterprise number (00:00:ab:11 = 43793, systemd's) plus an 8-byte
    # identifier, giving DUID 00020000ab1173656166696c006d. The identifier is "seafil"
    # in ASCII followed by 0x006d (109, the vmid). IAID 0x73656166 ("seaf") is pinned
    # for the same reason; odhcpd records it as the %-suffix on the lease's duid.
    dhcpV6Config = {
      DUIDType = "vendor";
      DUIDRawData = "00:00:ab:11:73:65:61:66:69:6c:00:6d";
      IAID = 1936023910; # 0x73656166, the "%73656166" suffix on the lease's duid
    };
  };

  # 443 serves Seafile; 80 is the ACME challenge + redirect. Docker's published ports
  # are DNATed in the nat table and bypass this INPUT filter, but the userland proxy
  # and local clients still arrive here, so open them like matrix does.
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  # ── Access ────────────────────────────────────────────────────────────────
  # No inbound SSH: Ansible manages this guest through the Proxmox host with
  # `pct exec` (group_vars/tenant_lxc.yml), and an operator gets a root shell with
  # `pct enter 109`. Overrides proxmox-lxc.nix's default of a socket-activated sshd.
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
    "d /var/lib/seafile 0755 root root -"
    "d ${secretsDir} 0700 root root -"
  ];

  # ── Seafile stack ─────────────────────────────────────────────────────────
  # Follows upstream's docker/ce compose files (.env, seafile-server.yml, caddy.yml)
  # at the pinned seafile_version; compare them when upgrading. Only seafile-caddy
  # publishes ports. SeaDoc, the notification server, Seafile AI and the metadata
  # server are optional upstream extensions and are not deployed.
  virtualisation.oci-containers.containers = {
    ${dbHost} = common // {
      image = site.dbImage;
      # Database files stay in a named volume on the Optane rootfs: constant small
      # writes stay off the HDDs, and MariaDB manages its own ownership.
      volumes = [ "seafile_db:/var/lib/mysql" ];
      environment = {
        MYSQL_LOG_CONSOLE = "true";
        MARIADB_AUTO_UPGRADE = "1";
      };
      environmentFiles = [ mysqlEnvFile ];
      extraOptions = [
        "--health-cmd=/usr/local/bin/healthcheck.sh --connect --mariadbupgrade --innodb_initialized"
        "--health-interval=20s"
        "--health-timeout=5s"
        "--health-retries=10"
        "--health-start-period=30s"
      ];
    };

    # Upstream sets requirepass from an empty REDIS_PASSWORD by default and relies on
    # the private Docker network; nothing publishes this port. Persistence is off
    # upstream too (cache only).
    ${redisHost} = common // {
      image = site.redisImage;
      cmd = [
        "redis-server"
        "--save"
        ""
        "--appendonly"
        "no"
      ];
    };

    # INIT_* values only matter on the very first start, while the data dir is empty.
    # After that, change the admin password in the web UI; changing it does nothing.
    seafile = common // {
      image = "seafileltd/seafile-mc:${site.seafileVersion}";
      autoStart = site.startApp;
      dependsOn = [
        dbHost
        redisHost
      ];
      volumes = [ "${dataDir}:/shared" ]; # library blocks, config, avatars on ZFS (mp0)
      environment = {
        SEAFILE_MYSQL_DB_HOST = dbHost;
        SEAFILE_MYSQL_DB_PORT = "3306";
        SEAFILE_MYSQL_DB_USER = site.dbUsername;
        SEAFILE_MYSQL_DB_CCNET_DB_NAME = "ccnet_db";
        SEAFILE_MYSQL_DB_SEAFILE_DB_NAME = "seafile_db";
        SEAFILE_MYSQL_DB_SEAHUB_DB_NAME = "seahub_db";
        TIME_ZONE = site.timeZone;
        SEAFILE_SERVER_HOSTNAME = hostName;
        SEAFILE_SERVER_PROTOCOL = "https";
        SITE_ROOT = "/";
        NON_ROOT = "false";
        # Logs go to the (size-rotated) docker log rather than waking the HDDs via /shared/logs.
        SEAFILE_LOG_TO_STDOUT = "true";
        ENABLE_GO_FILESERVER = "true";
        # Upstream enables SeaDoc by default; none of the extensions are deployed.
        ENABLE_SEADOC = "false";
        ENABLE_NOTIFICATION_SERVER = "false";
        ENABLE_SEAFILE_AI = "false";
        ENABLE_FACE_RECOGNITION = "false";
        CACHE_PROVIDER = "redis";
        REDIS_HOST = redisHost;
        REDIS_PORT = "6379";
        REDIS_PASSWORD = "";
      };
      environmentFiles = [ seafileEnvFile ];
      extraOptions = [
        "--health-cmd=curl -f http://localhost:80 || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
        "--health-start-period=60s"
      ];
    };

    # Ports are published on the guest's own addresses (NAT66 via the bridge); the
    # guest's dmz GUA is what ddns publishes. No UDP/443: the IPv4 proxy is TCP-only.
    seafile-caddy = common // {
      image = site.caddyImage;
      autoStart = site.startApp;
      dependsOn = [ "seafile" ];
      ports = [
        "80:80"
        "443:443"
      ];
      volumes = [
        "${caddyfile}:/etc/caddy/Caddyfile:ro"
        "seafile_caddy_data:/data" # certificates; losing it only means re-issuing
      ];
    };
  };

  systemd.services =
    let
      onNetwork = {
        after = [ networkUnit ];
        requires = [ networkUnit ];
      };
    in
    {
      # The IPv6-enabled bridge all four containers share. Created once; a changed subnet
      # needs the network removed by hand, like any Docker network.
      seafile-docker-network = {
        description = "Docker network ${network.name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "docker.service" ];
        requires = [ "docker.service" ];
        path = [ config.virtualisation.docker.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          docker network inspect ${network.name} >/dev/null 2>&1 \
            || docker network create --driver bridge --ipv6 --subnet ${network.subnet} ${network.name}
        '';
      };

      docker-seafile-mysql = onNetwork // {
        unitConfig = whenSecrets [ mysqlEnvFile ];
      };

      docker-seafile-redis = onNetwork;

      docker-seafile = onNetwork // {
        unitConfig = whenSecrets [
          mysqlEnvFile
          seafileEnvFile
        ];
        serviceConfig.ExecStartPre = lib.mkAfter [
          "${requireMount}/bin/seafile-require-mount ${dataDir}"
          "${waitHealthy}/bin/seafile-wait-healthy ${dbHost}"
        ];
      };

      docker-seafile-caddy = onNetwork // {
        unitConfig = whenSecrets [
          mysqlEnvFile
          seafileEnvFile
        ];
      };

      # ── Nightly database dump ───────────────────────────────────────────────
      # Logical dump of the three Seafile databases onto the backup mount (ZFS, mp1).
      # It runs inside the db container with the root password it already has in its
      # environment, so no credential is written to the host. Seafile's own docs say to
      # dump the database *before* copying data, so a restore never has a DB that
      # references blocks the data copy lacks. See README.
      seafile-db-dump = {
        description = "Dump the Seafile databases";
        after = [ "docker.service" ];
        requires = [ "docker.service" ];
        environment = {
          SEAFILE_BACKUP_DIR = backupDir;
          SEAFILE_BACKUP_KEEP = "14";
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${dbDump}/bin/seafile-db-dump";
        };
      };
    };

  systemd.timers.seafile-db-dump = {
    description = "Nightly Seafile database dump";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      RandomizedDelaySec = "15m";
      Persistent = true; # catch up if the host was down at 02:30
    };
  };
}
