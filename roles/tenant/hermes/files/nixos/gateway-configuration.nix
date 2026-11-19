{ config, pkgs, ... }:

let
  # Public identity, rendered from the vault by Ansible (roles/tenant/hermes/
  # templates/site.nix.j2) into the build/deploy copy of this tree; never committed.
  site = import ./site.nix;
  gatewayAddress = "fd5a:715f:1edc:a706::29";
  agentAddress = "fd5a:715f:1edc:a703::28";
  homeserverName = site.matrixHostName;
  # The public edge (roles/tenant/bunkerweb): terminates TLS for every *.us hostname,
  # including the homeserver's, and is the only client allowed on this guest's port 80.
  edgeAddress = site.edgeAddress;
  publicName = site.hermesHostName;
  stateDir = "/var/lib/hermes";
  backupPath = "/mnt/hermes-gateway-backup";
in
{
  proxmoxLXC.enable = true;

  systemd.network.networks."10-eth6" = {
    matchConfig.Name = "eth6";
    networkConfig = {
      DHCP = "ipv6";
      IPv6AcceptRA = true;
    };
    dhcpV6Config = {
      DUIDType = "vendor";
      DUIDRawData = "00:00:ab:11:68:65:72:6d:67:77:00:6c";
      IAID = 1752000375; # 0x686d6777
    };
  };

  networking = {
    # No hosts pin for the homeserver: matrix (CT106) no longer serves TLS, so the Matrix
    # client follows public DNS to the edge like every other client and gets the real
    # *.us certificate.
    # Port 80 (the plain-HTTP origin) is open to the edge only; nixos-fw is rebuilt on
    # every firewall (re)start, so -A stays idempotent.
    firewall.extraCommands = ''
      ip6tables -A nixos-fw -p tcp --dport 80 -s ${edgeAddress} -j nixos-fw-accept
    '';
  };

  # No inbound SSH; managed with `pct exec` from the Proxmox host, like hermes.
  services.openssh.enable = false;
  environment.systemPackages = [ pkgs.python3 ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  services.hermes-agent = {
    enable = true;
    inherit stateDir;
    extraDependencyGroups = [ "matrix" ];
    addToSystemPackages = true;
    backend.mode = "none";
    environmentFiles = [ "${stateDir}/secrets.env" ];
    environment = {
      MATRIX_HOMESERVER = "https://${homeserverName}";
      MATRIX_USER_ID = "@hermes:${site.matrixServerName}";
      MATRIX_DEVICE_ID = "HERMESGW01";
      MATRIX_ALLOWED_USERS = site.matrixAllowedUsers;
      MATRIX_E2EE_MODE = "required";
      MATRIX_REQUIRE_MENTION = "true";
      MATRIX_DM_AUTO_THREAD = "true";
      GATEWAY_PROXY_URL = "http://[${agentAddress}]:8642";
    };
  };
  # The image may boot before the E2EE store is copied. Activation and secrets
  # deployment can happen safely; the gateway joins Matrix only after cutover.
  systemd.services.hermes-agent.unitConfig.ConditionPathExists =
    "${stateDir}/matrix-cutover-ready";

  # Keep the Matrix crypto store on this guest. The unprivileged LXC maps this
  # service uid to host uid 101000; no host uid passthrough is granted.
  users.users.hermes.uid = 1000;
  users.groups.hermes.gid = 1000;

  # Plain-HTTP origin for the edge, which terminates TLS (*.us wildcard). [::] rather
  # than the ULA because the DHCPv6 address may not exist yet when nginx starts; the
  # firewall above limits the listener to the edge.
  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    virtualHosts.${publicName} = {
      listen = [
        { addr = "[::]"; port = 80; }
      ];
      locations."/" = {
        proxyPass = "http://[${agentAddress}]:9119";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_read_timeout 3600s;
          client_max_body_size 20M;
        '';
      };
    };
  };

  # An offline archive is essential for retaining the Matrix device's E2EE
  # sessions. Hermes snapshots SQLite files safely while its gateway is running.
  systemd.services.hermes-gateway-backup = {
    description = "Weekly Hermes Matrix gateway backup";
    unitConfig.ConditionPathIsMountPoint = backupPath;
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      Environment = [
        "HERMES_HOME=${stateDir}/.hermes"
        "HOME=${stateDir}"
      ];
      ProtectSystem = "strict";
      ReadWritePaths = [ stateDir "-${backupPath}" ];
      PrivateTmp = true;
      ExecStart = pkgs.writeShellScript "hermes-gateway-backup" ''
        set -eu
        # Nix store files copied into HERMES_HOME have epoch-1970 mtimes, which
        # Python's ZIP writer refuses to archive. Clamp only unrepresentable
        # file times; Hermes still takes its own WAL-safe SQLite snapshots.
        ${pkgs.findutils}/bin/find ${stateDir}/.hermes -type f ! -newermt '1980-01-01' \
          -exec ${pkgs.coreutils}/bin/touch -d '1980-01-01 UTC' {} +
        ${config.services.hermes-agent.package}/bin/hermes backup -o ${backupPath}
        ${pkgs.findutils}/bin/find ${backupPath} -maxdepth 1 -type f \
          -name 'hermes-backup-*.zip' -printf '%T@ %p\n' \
          | ${pkgs.coreutils}/bin/sort -rn \
          | ${pkgs.coreutils}/bin/tail -n +5 \
          | ${pkgs.coreutils}/bin/cut -d' ' -f2- \
          | ${pkgs.findutils}/bin/xargs -r ${pkgs.coreutils}/bin/rm -f
      '';
    };
  };
  systemd.timers.hermes-gateway-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 05:30:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };

  system.stateVersion = "26.11";
}
