{ config, lib, pkgs, ... }:

let
  # Public identity, rendered from the vault by Ansible (templates/site.nix.j2)
  # into the build/deploy copy of this tree; never committed.
  site = import ./site.nix;

  # Static DHCPv6 leases on prydwen.
  hermesAddress = "fd5a:715f:1edc:a703::28";
  gatewayAddress = "fd5a:715f:1edc:a706::29";

  # Bind mount of /mnt/frontpanel-pool/frontpanel-dataset/Backup/hermes on the
  # Proxmox host; see roles/hermes/tasks/config_lxc.yml.
  backupPath = "/mnt/hermes-backup";
  # Roughly a month at the weekly cadence below, matching tuwunel's
  # database_backups_to_keep = 4.
  backupsToKeep = 4;

  stateDir = "/var/lib/hermes";
  hermesHome = "${stateDir}/.hermes";
  # Written by roles/hermes/tasks/config_hermes.yml, not by Nix. Everything in a
  # Nix expression lands in /nix/store, which is world-readable; the module types
  # environmentFiles as `str` rather than `path` precisely so this stays a runtime
  # path that the store never sees.
  secretsFile = "${stateDir}/secrets.env";

  # ── Linear Kanban workers ────────────────────────────────────────────────
  # Bot credentials, written by tasks/main.yml from the vault (0400, hermes).
  # Files rather than environment variables: Hermes strips credentials from the
  # environment of the commands an agent runs, so a token in an env var would
  # not reach `gh` or `claude` inside a Kanban worker anyway.
  credentialsDir = "${stateDir}/credentials";
  # Per-issue clones the poller creates; each is one card's workspace.
  workDir = "${stateDir}/work";
  pollerEnvFile = "${stateDir}/linear-poller.env";

  # gh and Claude Code read their tokens from the environment, so these wrappers
  # take the place of the real binaries on the agent's PATH and export the token
  # from its file first. An already-set variable wins, which keeps the Kanban
  # completion gate's own GH_TOKEN (from the worker profile's .env) in charge.
  gh = pkgs.writeShellScriptBin "gh" ''
    if [ -z "''${GH_TOKEN:-}" ] && [ -r ${credentialsDir}/github-token ]; then
      GH_TOKEN=$(cat ${credentialsDir}/github-token)
      export GH_TOKEN
    fi
    exec ${pkgs.gh}/bin/gh "$@"
  '';
  claude = pkgs.writeShellScriptBin "claude" ''
    if [ -z "''${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r ${credentialsDir}/claude-code-oauth-token ]; then
      CLAUDE_CODE_OAUTH_TOKEN=$(cat ${credentialsDir}/claude-code-oauth-token)
      export CLAUDE_CODE_OAUTH_TOKEN
    fi
    exec ${pkgs.claude-code}/bin/claude "$@"
  '';
in
{
  # Defaults are what we want: manageNetwork = false leaves systemd-networkd
  # enabled (we add the eth3 config below) and manageHostName = false picks the
  # hostname up from the /etc/hostname Proxmox writes.
  proxmoxLXC.enable = true;

  # ── Networking ────────────────────────────────────────────────────────────
  # eth3 is the backend NIC (VLAN 3). The netif is created with ip6=manual, so
  # nothing addresses the interface until networkd does. Declaring it here replaces
  # the `pct exec … printf > /etc/systemd/network/…` dance the Debian roles need.
  # The 10- prefix sorts ahead of anything Proxmox drops in; networkd takes the
  # first matching file.
  systemd.network.networks."10-eth3" = {
    matchConfig.Name = "eth3";
    networkConfig = {
      DHCP = "ipv6";
      IPv6AcceptRA = true;
    };
    # Pin the DHCPv6 client identity so the router's static lease can be written
    # before this container has ever booted — the same trick roles/matrix uses, and
    # for the same reason: a NixOS guest carries its network config in the image
    # rather than receiving it over SSH afterwards, so the DUID can be *assigned*
    # instead of discovered. That is what lets this tenant skip the manual
    # mid-provisioning lease pause init_proxmox.yml documents.
    #
    # DUIDType=vendor prepends the type ("00:02") and this data supplies the
    # enterprise number (00:00:ab:11 = 43793, systemd's) plus an 8-byte identifier,
    # giving DUID 00020000ab116865726d6573006b — the same 14-byte DUID-EN shape the
    # other systemd guests produce. The identifier is "hermes" in ASCII followed by
    # 0x006b (107, the vmid), so it is self-evidently assigned rather than random.
    # IAID 0x6865726d ("herm") is pinned for the same reason; odhcpd records it as
    # the `%`-suffix on the lease's duid.
    dhcpV6Config = {
      DUIDType = "vendor";
      DUIDRawData = "00:00:ab:11:68:65:72:6d:65:73:00:6b";
      IAID = 1751478893; # 0x6865726d, the "%6865726d" suffix on the lease's duid
    };
  };

  networking = {
    # Keep agent API and dashboard reachable only from the gateway and trusted
    # management network. The router's existing broad forwarding remains intact.
    firewall.extraCommands = ''
      ip6tables -A nixos-fw -s ${gatewayAddress} -p tcp --dport 8642 -j nixos-fw-accept
      ip6tables -A nixos-fw -s ${gatewayAddress} -p tcp --dport 9119 -j nixos-fw-accept
      ip6tables -A nixos-fw -s fd5a:715f:1edc:a702::/64 -p tcp --dport 9119 -j nixos-fw-accept
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
  };

  # Claude Code is the only unfree package on this guest; allow it by name rather
  # than flipping allowUnfree for the whole closure.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

  # ── Hermes Agent ──────────────────────────────────────────────────────────
  services.hermes-agent = {
    enable = true;
    inherit stateDir;

    # Matrix and its E2EE dependency group live only on CT108.
    extraDependencyGroups = [ ];

    # Puts the hermes CLI on PATH *and* exports HERMES_HOME system-wide, so an
    # interactive `hermes …` shares state with the gateway service instead of
    # quietly creating a second ~/.hermes. Required for the one-time
    # `hermes auth add openai-codex` step in the README.
    addToSystemPackages = true;

    # The dashboard stays with the agent; CT108 only terminates HTTPS and
    # proxies browser requests to this address.
    backend = {
      mode = "dashboard";
      host = hermesAddress;
      port = 9119;
    };

    # Secrets. A path that cannot be read is a warning, not an error, in the
    # module's activation script (nix/moduleCommon.nix, mkEnvScript), so the first
    # boot straight from the image succeeds and the unit merely restarts until
    # config_hermes.yml has written this file.
    environmentFiles = [ secretsFile ];

    # On the agent's PATH (and the hermes user's profile) for Kanban workers. git
    # is already there from the module. These are the credential wrappers above,
    # not the bare packages, so the tools find the bot's tokens.
    extraPackages = [ gh claude ];

    # The gateway process here serves the authenticated agent API only.
    environment = {
      API_SERVER_ENABLED = "true";
      API_SERVER_HOST = hermesAddress;
      API_SERVER_PORT = "8642";
      HERMES_DASHBOARD_PUBLIC_URL = "https://${site.hermesHostName}";
      HERMES_DASHBOARD_OAUTH_CLIENT_ID = "agent:cmuqdu4i60002qe06c1a72bve";
    };

    settings = {
      dashboard.trusted_proxies = [ gatewayAddress ];
      mcp_servers.obs = {
        # Kept for re-enabling; Hermes skips servers with enabled = false.
        enabled = false;
        url = "http://[fd5a:715f:1edc:a702::10]:6006/mcp";
        tools = {
          include = [ "get_current_frame" ];
          prompts = false;
          resources = false;
        };
      };
      model = {
        # Existing ChatGPT subscription credentials remain on CT107.
        provider = "openai-codex";
        default = "gpt-6.1-sol";
      };
      # The gateway's built-in dispatcher starts a worker for each ready card.
      # Two at a time is what 2 cores and 8 GiB can carry with Claude Code's Node
      # process beside each Hermes worker. dispatch_profiles keeps this home from
      # claiming cards for any other assignee.
      kanban = {
        max_in_progress = 2;
        dispatch_profiles = [ "coder-claude-code" ];
      };
    };

    hermesHomeFiles."skills/explain-code/SKILL.md" = ./skills/explain-code/SKILL.md;
  };

  # Pin the service uid so the host-side LXC idmap (u 1000 1000 1, see
  # tasks/init_passthrough_hermes_user.yml) lines up and the backup archives land
  # owned by `diwangs` on the ZFS pool rather than by some arbitrary high uid. Same
  # problem roles/matrix solves for tuwunel; simpler here, because the hermes
  # module creates an ordinary system user rather than using DynamicUser.
  users.users.hermes.uid = 1000;
  users.groups.hermes.gid = 1000;

  # ── Weekly backup ─────────────────────────────────────────────────────────
  # Hermes backs itself up: `hermes backup` walks $HERMES_HOME, safe-copies the
  # SQLite databases with an integrity check, skips caches, and writes one verified
  # zip. So this is the same division of labour as tuwunel's RocksDB backups —
  # Ansible provides the mount, the application does the work, and there is no borg
  # here. Restore with `hermes import <archive>`.
  #
  # Note what this does *not* cover: /var/lib/hermes/workspace (the agent's working
  # directory) and /var/lib/hermes/home are outside HERMES_HOME and are not in the
  # archive. That is deliberate upstream — the workspace is scratch, the identity
  # and memory are what matter.
  systemd.services.hermes-backup = {
    description = "Weekly Hermes Agent home backup";
    # Skip the run rather than fail it when the pool is not mounted. mp0 only
    # appears after a container restart, and the ZFS pool behind it is TPM-unlocked
    # at boot (see the repo README).
    unitConfig.ConditionPathIsMountPoint = backupPath;
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      Environment = [
        "HERMES_HOME=${hermesHome}"
        "HOME=${stateDir}"
      ];
      ProtectSystem = "strict";
      # The state dir is writable because `hermes backup` takes a lock file inside
      # HERMES_HOME and stages the zip before moving it into place, so this is not
      # a read-only operation on its own state.
      # The "-" prefix on the backup path makes a missing mount non-fatal at
      # *namespace setup* time. Without it systemd cannot build the mount
      # namespace and the unit dies with 226/NAMESPACE before ConditionPath is
      # even relevant — the exact failure roles/matrix hit on tuwunel's first boot.
      ReadWritePaths = [
        stateDir
        "-${backupPath}"
      ];
      PrivateTmp = true;
      ExecStart = pkgs.writeShellScript "hermes-backup" ''
        set -eu

        # Nix store files copied into HERMES_HOME have epoch-1970 mtimes,
        # earlier than Python's ZIP format supports.
        ${pkgs.findutils}/bin/find ${hermesHome} -type f ! -newermt '1980-01-01' \
          -exec ${pkgs.coreutils}/bin/touch -d '1980-01-01 UTC' {} +

        # -o with a directory makes hermes name the file hermes-backup-<stamp>.zip.
        ${config.services.hermes-agent.package}/bin/hermes backup -o ${backupPath}

        # `hermes backup` has no retention of its own (unlike its internal
        # pre-update snapshots, which do prune), so the rotation lives here.
        # find/sort rather than `ls -t`: this stays quiet and exits clean when the
        # directory is still empty, which it is on the very first run.
        ${pkgs.findutils}/bin/find ${backupPath} -maxdepth 1 -type f \
            -name 'hermes-backup-*.zip' -printf '%T@ %p\n' \
          | ${pkgs.coreutils}/bin/sort -rn \
          | ${pkgs.coreutils}/bin/tail -n +${toString (backupsToKeep + 1)} \
          | ${pkgs.coreutils}/bin/cut -d' ' -f2- \
          | ${pkgs.findutils}/bin/xargs -r ${pkgs.coreutils}/bin/rm -f
      '';
    };
  };

  # ── Linear poller ─────────────────────────────────────────────────────────
  # Turns Linear issues delegated to the Hermes OAuth app into Kanban cards;
  # see linear-poller.py. Polling, not a webhook: nothing on the internet can
  # reach this container, and this keeps it that way. Inert until
  # tasks/main.yml has written the poller's env file, which it does only once
  # the app's client credentials are in the vault.
  systemd.services.hermes-linear-poller = {
    description = "Queue Linear issues as Hermes Kanban cards";
    after = [ "network-online.target" "hermes-agent.service" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = pollerEnvFile;
    path = [ config.services.hermes-agent.package pkgs.git gh ];
    environment = {
      HERMES_HOME = hermesHome;
      HOME = stateDir;
      LINEAR_POLLER_STATE_DIR = stateDir;
      LINEAR_POLLER_WORK_DIR = workDir;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      EnvironmentFile = pollerEnvFile;
      ExecStart = "${pkgs.python3}/bin/python3 ${./linear-poller.py}";
      ProtectSystem = "strict";
      # Writes the board DB and the worker profile's .env under HERMES_HOME,
      # the app token under credentialsDir and the clones under workDir.
      ReadWritePaths = [ stateDir ];
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  systemd.timers.hermes-linear-poller = {
    description = "Poll Linear for Hermes Kanban work";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
    };
  };

  systemd.timers.hermes-backup = {
    description = "Weekly Hermes Agent backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # An hour after tuwunel's 04:00, so the two tenants do not spin the pool up
      # at the same moment.
      OnCalendar = "Sun *-*-* 05:00:00";
      Persistent = true; # catch up if the host was down at 05:00
      RandomizedDelaySec = "15m";
    };
  };

  # The release this container was first built against; do not bump on upgrade.
  # FlakeHub "0.1" currently resolves to the 26.11 unstable line.
  system.stateVersion = "26.11";
}
