{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Public identity, image pin and upstream addresses, rendered by Ansible
  # (templates/site.nix.j2) into the build/deploy copy of this tree; never committed.
  # Secrets are NOT in here: everything a Nix expression touches ends up in /nix/store,
  # which is world-readable.
  site = import ./site.nix;

  # Runtime-only credential (the Cloudflare DNS-01 token), written by Ansible
  # (tasks/secrets.yml) as root:root 0400 from the vault and passed to
  # `docker run --env-file`, so it never appears in a unit file, the Nix store or
  # the image. A plain string on purpose: a Nix `path` literal would be copied into
  # the store.
  secretsDir = "/var/lib/bunkerweb/secrets";
  schedulerEnvFile = "${secretsDir}/scheduler.env";
  # Admin login for the web UI (ADMIN_USERNAME / ADMIN_PASSWORD), same handling.
  uiEnvFile = "${secretsDir}/ui.env";
  # The UI is published on this guest's own dmz ULA only (never the public 80/443, and no
  # router rule forwards 7000 from wan), so it is reachable from the LAN and nowhere else.
  # Plain HTTP: the admin password crosses the LAN in the clear, see the README.
  uiBindAddress = site.uiBindAddress;

  # WebRTC media for Frigate (frigate-webrtc.us:8555, TCP only), relayed at L4 by a host
  # nginx stream server, because a kernel DNAT cannot cross into go2rtc's IPv6 listener from
  # a different guest. BunkerWeb is not involved (it is not HTTP).
  webrtcPort = 8555;
  webrtcUpstream = site.frigateWebrtcUpstream;

  # Private bridge shared by the two containers. The IPv4 subnet is pinned as well as
  # the IPv6 one because the scheduler reaches the instance's API (port 5000) by
  # container name, which resolves to both families, and API_WHITELIST_IP has to name
  # whichever source address it ends up using.
  network = {
    name = "bw-net";
    subnet4 = "10.110.0.0/24";
    subnet6 = "fd00:b0b0:5e::/64"; # container-internal, NAT66'd to the host
  };
  apiWhitelist = "127.0.0.0/8 ${network.subnet4} ${network.subnet6}";

  # BunkerWeb's multisite settings are `<server name>_<SETTING>`; this prefixes a whole
  # attrset of per-site settings with its server name.
  perSite = host: lib.mapAttrs' (k: v: lib.nameValuePair "${host}_${k}" v);

  # Shared by every site.
  common = {
    USE_REVERSE_PROXY = "yes";
    REVERSE_PROXY_URL = "/";
    MODSECURITY_SEC_RULE_ENGINE = site.modsecurityEngine;
    LIMIT_REQ_URL = "/";
    LIMIT_REQ_RATE = "20r/s";
    # 401/403/404/429 are routine answers from these APIs (expired tokens, missing
    # media, federation probes, sync clients), not evidence of scanning.
    BAD_BEHAVIOR_STATUS_CODES = "400 405 444";
  };

  sites = {
    # Client-server and federation API. tuwunel's max_request_size is 20 MB.
    ${site.matrixHostName} = common // {
      REVERSE_PROXY_HOST = "http://[${site.matrixUpstream}]";
      ALLOWED_METHODS = "GET|POST|HEAD|PUT|DELETE|OPTIONS";
      MAX_CLIENT_SIZE = "20m";
      # /sync long-polls for up to 30 s by default.
      REVERSE_PROXY_READ_TIMEOUT = "120s";
    };

    # Hermes dashboard (via hermes-gateway's nginx). Websockets, long-lived sessions.
    ${site.hermesHostName} = common // {
      REVERSE_PROXY_HOST = "http://[${site.hermesUpstream}]";
      REVERSE_PROXY_WS = "yes";
      ALLOWED_METHODS = "GET|POST|HEAD|PUT|PATCH|DELETE|OPTIONS";
      MAX_CLIENT_SIZE = "20m";
      REVERSE_PROXY_READ_TIMEOUT = "3600s";
      REVERSE_PROXY_SEND_TIMEOUT = "3600s";
    };

    # Seafile: seahub on /, the file server on /seafhttp. No upload limit (the old Caddy
    # front had none). File transfers are streamed, not buffered, and skip ModSecurity:
    # the CRS cannot usefully inspect encrypted blocks and would cap the body size.
    # X-Forwarded-Protocol is dropped (a header listed here replaces BunkerWeb's default,
    # and an empty value makes nginx omit it): BunkerWeb sends it as "https" next to
    # X-Forwarded-Proto, and seahub's gunicorn expects "ssl" for that header, so it
    # rejects every request with 400 "Contradictory scheme headers".
    ${site.seafileHostName} = common // {
      REVERSE_PROXY_HOST = "http://[${site.seafileUpstream}]";
      REVERSE_PROXY_HEADERS = "X-Forwarded-Protocol \"\"";
      REVERSE_PROXY_HEADERS_1 = "X-Forwarded-Protocol \"\"";
      ALLOWED_METHODS = "GET|POST|HEAD|PUT|PATCH|DELETE|OPTIONS";
      MAX_CLIENT_SIZE = "0";
      # Sync clients (SeaDrive/desktop) burst check-blocks and block PUTs in parallel and
      # exceeded the shared 20r/s, getting 429s that surface as "Unknown Error".
      LIMIT_REQ_RATE = "200r/s";
      REVERSE_PROXY_READ_TIMEOUT = "1200s";
      REVERSE_PROXY_SEND_TIMEOUT = "1200s";
      REVERSE_PROXY_URL_1 = "/seafhttp";
      REVERSE_PROXY_HOST_1 = "http://[${site.seafileUpstream}]";
      REVERSE_PROXY_MODSECURITY_1 = "no";
      REVERSE_PROXY_REQUEST_BUFFERING_1 = "no";
      REVERSE_PROXY_BUFFERING_1 = "no";
      REVERSE_PROXY_READ_TIMEOUT_1 = "1200s";
      REVERSE_PROXY_SEND_TIMEOUT_1 = "1200s";
    };

    # Radicale (CalDAV/CardDAV): WebDAV methods, small bodies (contacts, events, photos
    # inside vCards). 401 is not counted as bad behavior: clients probe unauthenticated
    # before sending credentials. Brute force is slowed by Radicale's own failed-login
    # delay plus the request limit here. The CRS knows nothing about WebDAV, so expect
    # DetectionOnly noise on PROPFIND/REPORT until the engine is switched to On.
    ${site.davHostName} = common // {
      REVERSE_PROXY_HOST = "http://[${site.davUpstream}]";
      ALLOWED_METHODS = "GET|POST|HEAD|PUT|DELETE|OPTIONS|PROPFIND|PROPPATCH|REPORT|MKCOL|MKCALENDAR|COPY|MOVE";
      MAX_CLIENT_SIZE = "50m";
      LIMIT_REQ_RATE = "30r/s";
    };
  };

  # The scheduler is the single configuration source (docker integration without
  # autoconf): it renders nginx config and pushes it to the instance over the API.
  schedulerEnvironment = {
    BUNKERWEB_INSTANCES = "bunkerweb";
    API_WHITELIST_IP = apiWhitelist;
    MULTISITE = "yes";
    SERVER_NAME = lib.concatStringsSep " " (lib.attrNames sites);
    # Unknown Host / missing SNI gets nothing, not a default page.
    DISABLE_DEFAULT_SERVER = "yes";
    SEND_ANONYMOUS_REPORT = "no";

    # One wildcard certificate, *.us.<public_domain>, over Cloudflare DNS-01 — so no
    # inbound port 80 is needed for issuance or renewal. The token itself comes from
    # schedulerEnvFile (LETS_ENCRYPT_DNS_CREDENTIAL_ITEM=api_token ...). Cloudflare
    # tokens can look like base64, which BunkerWeb would otherwise try to decode.
    AUTO_LETS_ENCRYPT = "yes";
    EMAIL_LETS_ENCRYPT = site.acmeEmail;
    LETS_ENCRYPT_CHALLENGE = "dns";
    LETS_ENCRYPT_DNS_PROVIDER = "cloudflare";
    LETS_ENCRYPT_DNS_CREDENTIAL_DECODE_BASE64 = "no";
    USE_LETS_ENCRYPT_WILDCARD = "yes";

    # TCP only: no UDP port is published.
    HTTP3 = "no";

    # BunkerWeb listens on IPv4 only by default; IPv6 clients (published via ip6tables
    # DNAT) are handed to the container's IPv6 address, where nginx would otherwise
    # reset them before TLS even starts. Docker's DNAT keeps real client addresses on
    # both families, so no PROXY protocol or real-IP handling is needed.
    USE_IPV6 = "yes";

    # Spamhaus refuses queries relayed through public resolvers, and this guest's
    # lookups go out through the router's DoH forwarders.
    USE_DNSBL = "no";
  }
  // lib.concatMapAttrs perSite sites;

  # Containers whose unit must not run before Ansible has installed their env file.
  # A failed condition just skips the unit (not a failure), so the first boot of a fresh
  # image is quiet; Ansible starts the stack once the credential exists.
  whenSecrets = files: { ConditionPathExists = files; };

  # Created by the network unit below; both containers wait for it.
  networkUnit = "bunkerweb-docker-network.service";

  # Fields shared by both containers: private bridge, restart handled by systemd
  # (Restart=on-failure from the oci-containers module), logs to Docker's rotated
  # json-file store (see daemon settings) rather than the journal.
  containerDefaults = {
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
  # eth6 is the dmz NIC (VLAN 6), addressed by networkd only (ip6=manual on the netif).
  # networkd processes RAs in userspace and installs the default route itself, which
  # matters here: Docker turns this guest into a forwarding host and the kernel then
  # ignores RAs (docker/for-linux#844).
  systemd.network.networks."10-eth6" = {
    matchConfig.Name = "eth6";
    networkConfig = {
      DHCP = "ipv6";
      IPv6AcceptRA = true;
    };
    # Pin the DHCPv6 client identity so the router's static lease (host_bunkerweb in
    # host_vars/prydwen.yml) can be written before this container has ever booted,
    # exactly as for matrix and seafile. DUIDType=vendor prepends the type ("00:02") and
    # this data supplies the enterprise number (00:00:ab:11 = 43793, systemd's) plus an
    # 8-byte identifier, giving DUID 00020000ab1162756e6b6572006e. The identifier is
    # "bunker" in ASCII followed by 0x006e (110, the vmid). IAID 0x62756e6b ("bunk") is
    # pinned for the same reason; odhcpd records it as the %-suffix on the lease's duid.
    dhcpV6Config = {
      DUIDType = "vendor";
      DUIDRawData = "00:00:ab:11:62:75:6e:6b:65:72:00:6e";
      IAID = 1651863147; # 0x62756e6b, the "%62756e6b" suffix on the lease's duid
    };
  };

  # ── Exposure ──────────────────────────────────────────────────────────────
  # BunkerWeb's ports are published by Docker (DNAT, bypassing nixos-fw); what reaches
  # them is decided by the router (Allow-BunkerWeb for IPv6, DNAT-BunkerWeb for IPv4).
  # Only the WebRTC relay is a host listener, so it is opened here.
  networking.firewall.allowedTCPPorts = [ webrtcPort ];

  services.nginx = {
    enable = true;
    streamConfig = ''
      server {
        listen [::]:${toString webrtcPort};
        proxy_pass [${webrtcUpstream}]:${toString webrtcPort};
        proxy_timeout 1h;
      }
    '';
  };

  # ── Access ────────────────────────────────────────────────────────────────
  # No inbound SSH: Ansible manages this guest through the Proxmox host with
  # `pct exec` (group_vars/tenant_lxc.yml), and an operator gets a root shell with
  # `pct enter 110`. Overrides proxmox-lxc.nix's default of a socket-activated sshd.
  services.openssh.enable = false;

  # Ansible needs an interpreter on the target; NixOS ships none by default.
  environment.systemPackages = [ pkgs.python3 ];

  # ── Nix ───────────────────────────────────────────────────────────────────
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # ── Docker ────────────────────────────────────────────────────────────────
  # Same daemon settings as seafile and the Debian guests (roles/common/docker_host):
  # NAT66 via ip6tables, IPv6 on the bridges, and per-container log rotation. With
  # ip6tables, published ports are DNATed, so BunkerWeb sees the real client address.
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
    "d /var/lib/bunkerweb 0755 root root -"
    "d ${secretsDir} 0700 root root -"
  ];

  # ── BunkerWeb ─────────────────────────────────────────────────────────────
  # Follows upstream's misc/integrations/docker.yml at the pinned bunkerweb_version:
  # an instance plus a scheduler, no autoconf and no web UI — so nothing on this
  # internet-facing guest gets /var/run/docker.sock (root on the guest), and there is
  # no admin surface. Configuration changes go through this file and a rebuild.
  virtualisation.oci-containers.containers = {
    # Runs unprivileged inside the image, hence 8080/8443.
    bunkerweb = containerDefaults // {
      image = "bunkerity/bunkerweb:${site.bunkerwebVersion}";
      ports = [
        "80:8080"
        "443:8443"
      ];
      environment.API_WHITELIST_IP = apiWhitelist;
    };

    # Holds the settings DB (SQLite) and the certificates in bw-storage; losing the
    # volume only means re-issuing the wildcard.
    bunkerweb-scheduler = containerDefaults // {
      image = "bunkerity/bunkerweb-scheduler:${site.bunkerwebVersion}";
      dependsOn = [ "bunkerweb" ];
      volumes = [ "bw-storage:/data" ];
      environment = schedulerEnvironment;
      environmentFiles = [ schedulerEnvFile ];
    };

    # Web UI. Reads and writes the scheduler's SQLite database (the default DATABASE_URI is
    # the same path in both images), so it mounts the same volume; the Flask/Biscuit/TOTP
    # secrets it generates live there too (/data/lib), which keeps 2FA enrolments across
    # recreations. No Docker socket, like everything here. Listens on 7000 in the container.
    bunkerweb-ui = containerDefaults // {
      image = "bunkerity/bunkerweb-ui:${site.bunkerwebVersion}";
      dependsOn = [ "bunkerweb-scheduler" ];
      ports = [ "[${uiBindAddress}]:7000:7000" ];
      volumes = [ "bw-storage:/data" ];
      environment = {
        API_WHITELIST_IP = apiWhitelist;
        # The UI listens on 0.0.0.0 by default (IPv4 only), but an IPv6 publish is DNATed to
        # the container's IPv6 address, where nothing would answer. "[::]" accepts both. The
        # brackets are required: the entrypoint joins address and port as `addr:port`, and a
        # bare "::" makes that ":::7000" ("'' is not a valid port number").
        UI_LISTEN_ADDR = "[::]";
        UI_LISTEN_PORT = "7000";
      };
      environmentFiles = [ uiEnvFile ];
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
      # The dual-stack bridge both containers share. Created once; a changed subnet
      # needs the network removed by hand, like any Docker network.
      bunkerweb-docker-network = {
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
            || docker network create --driver bridge --ipv6 \
              --subnet ${network.subnet4} --subnet ${network.subnet6} ${network.name}
        '';
      };

      docker-bunkerweb = onNetwork // {
        unitConfig = whenSecrets [ schedulerEnvFile ];
      };

      docker-bunkerweb-scheduler = onNetwork // {
        unitConfig = whenSecrets [ schedulerEnvFile ];
      };

      docker-bunkerweb-ui = onNetwork // {
        unitConfig = whenSecrets [
          schedulerEnvFile
          uiEnvFile
        ];
      };
    };

  # The release this container was first built against; do not bump on upgrade.
  system.stateVersion = "26.11";
}
