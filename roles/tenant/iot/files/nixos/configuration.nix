{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Addresses, the pinned image, the radio and the (non-secret) Zigbee network identity,
  # rendered by Ansible (templates/site.nix.j2) into the build/deploy copy of this tree;
  # never committed. Secrets are NOT in here: everything a Nix expression touches ends
  # up in /nix/store, which is world-readable.
  site = import ./site.nix;

  # ── State ─────────────────────────────────────────────────────────────────
  # Keep in step with roles/tenant/iot/vars/main.yml (tests/ checks them).
  stateDir = "/var/lib/iot";
  # Written once the Zigbee state is in place (it was moved here from HAOS once; see the
  # README for restoring). Until then neither the radio stack nor Zigbee2MQTT may start:
  # zigbeed with an empty working directory would bring up a blank Zigbee stack, and Z2M
  # facing parameters the stack does not have would form a NEW network — which would
  # orphan every paired device.
  migratedMarker = "${stateDir}/migrated";
  # Runtime-only credentials (tasks/secrets.yml), root-only. Plain strings on purpose:
  # a Nix `path` literal would be copied into the store.
  secretsDir = "${stateDir}/secrets";
  multipanDir = "/var/lib/multipan";
  zigbeedDir = "${multipanDir}/zigbeed"; # the Zigbee network itself (key, PAN, frame counter)
  threadDir = "${multipanDir}/thread"; # otbr-agent settings (Thread dataset)
  z2mDir = config.services.zigbee2mqtt.dataDir;

  # The radio as the container sees it (multipan-run.sh checks for it). It must keep its
  # CT path: runc in this user namespace cannot mknod, so it bind-mounts the node from the
  # *container* path, and a renamed --device (src:/dev/other) fails with ENOENT.
  radioInContainer = site.radioDevice;
  # zigbeed's EZSP socket. All addresses inside the CT (as in the add-on), closed by
  # nixos-fw; Zigbee2MQTT connects over loopback.
  ezspPort = 9999;
  mqttPort = 1883;
  z2mFrontendPort = 8080;
  otbrRestPort = 8081; # fixed by otbr-agent; the HA OTBR integration talks to it

  # Same keys and values as the add-on's /usr/local/share/cpcd.conf template, filled in
  # with what its cpcd-config-up script would have rendered.
  cpcdConf = pkgs.writeText "cpcd.conf" ''
    instance_name: cpcd_0
    bus_type: UART
    uart_device_file: ${radioInContainer}
    uart_device_baud: ${toString site.radioBaudrate}
    uart_hardflow: ${lib.boolToString site.radioFlowControl}
    bootloader_recovery_pins_enabled: false
    stdout_trace: false
    trace_to_file: false
    traces_folder: /dev/shm/cpcd-traces
    enable_frame_trace: false
    rlimit_nofile: 2000
    disable_encryption: true
    binding_key_file: /etc/binding-key.key
  '';

  # Refuse to start the radio stack on an empty zigbeed directory even if the marker is
  # there (e.g. the state was wiped by hand).
  requireZigbeedState = pkgs.writeShellApplication {
    name = "iot-require-zigbeed-state";
    runtimeInputs = [ pkgs.findutils ];
    text = ''
      if [ -z "$(find ${zigbeedDir} -mindepth 1 -print -quit 2>/dev/null)" ]; then
        echo "${zigbeedDir} is empty: refusing to start zigbeed without the migrated network" >&2
        exit 1
      fi
    '';
  };
in
{
  # Defaults are what we want: manageNetwork = false leaves systemd-networkd
  # enabled (we add the eth3 config below) and manageHostName = false picks the
  # hostname up from the /etc/hostname Proxmox writes.
  proxmoxLXC.enable = true;

  # ── Networking ────────────────────────────────────────────────────────────
  # eth3 is the backend NIC (VLAN 3) — the same link as Home Assistant (and its Matter
  # server) and Frigate, which is also the Thread border router's backbone: Thread
  # routes are advertised there by RA. ip6=manual, so networkd owns addressing. The
  # 10- prefix sorts ahead of anything Proxmox drops in. networkd processes RAs in
  # userspace, which keeps working with forwarding enabled below (the kernel would
  # ignore RAs on a forwarding host).
  systemd.network.networks."10-eth3" = {
    matchConfig.Name = "eth3";
    networkConfig = {
      DHCP = "ipv6";
      IPv6AcceptRA = true;
    };
    # Pinned DHCPv6 client identity, so the router's static lease (host_iot in
    # host_vars/prydwen.yml) exists before the container first boots (as for dav).
    # DUIDType=vendor prepends "00:02"; 00:00:ab:11 is systemd's enterprise number
    # (43793), then "iotlxc" in ASCII and 0x0070 (112, the vmid), giving DUID
    # 00020000ab11696f746c78630070. IAID 0x696f746c ("iotl") is the %-suffix odhcpd
    # records on the lease's duid.
    dhcpV6Config = {
      DUIDType = "vendor";
      DUIDRawData = "00:00:ab:11:69:6f:74:6c:78:63:00:70";
      IAID = 1768911980; # 0x696f746c
    };
  };

  # otbr-agent routes between the Thread mesh (wpan0) and the backbone.
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.forwarding" = 1;
    "net.ipv4.conf.all.forwarding" = 0;
  };

  networking.firewall = {
    # The Thread mesh: MLE, CoAP, SRP and the like arrive on wpan0 from Thread devices.
    # Forwarded traffic is filtered by the OTBR chains multipan-run.sh installs, as in
    # the add-on.
    trustedInterfaces = [ "wpan0" ];
    # mDNS: otbr-agent advertises the border router (_meshcop._udp) and SRP-registered
    # services on the backbone.
    interfaces.eth3.allowedUDPPorts = [ 5353 ];
    # nixos-fw is rebuilt on every firewall (re)start, so -A stays idempotent.
    #  - MQTT from the backend (Home Assistant, Frigate)
    #  - the Zigbee2MQTT frontend from the home ULA range (token-protected)
    #  - the OTBR REST API, which has no authentication, from Home Assistant only
    # Nothing admits the EZSP port: Zigbee2MQTT uses loopback.
    extraCommands = ''
      ip6tables -A nixos-fw -p tcp --dport ${toString mqttPort} -s ${site.backendPrefix} -j nixos-fw-accept
      ip6tables -A nixos-fw -p tcp --dport ${toString z2mFrontendPort} -s ${site.lanPrefix} -j nixos-fw-accept
      ip6tables -A nixos-fw -p tcp --dport ${toString otbrRestPort} -s ${site.hassAddress} -j nixos-fw-accept
    '';
  };

  # ── Access ────────────────────────────────────────────────────────────────
  # No inbound SSH: Ansible manages this guest through the Proxmox host with
  # `pct exec` (group_vars/tenant_lxc.yml), and an operator gets a root shell with
  # `pct enter 112`. Overrides proxmox-lxc.nix's default of a socket-activated sshd.
  services.openssh.enable = false;

  # Ansible needs an interpreter on the target; NixOS ships none by default. The
  # mosquitto clients are for checking the broker by hand.
  environment.systemPackages = [
    pkgs.python3
    pkgs.mosquitto
  ];

  # ── Nix ───────────────────────────────────────────────────────────────────
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 root root -"
    "d ${secretsDir} 0700 root root -"
    "d ${multipanDir} 0700 root root -"
    "d ${zigbeedDir} 0700 root root -"
    "d ${threadDir} 0700 root root -"
  ];

  # ── Docker (radio stack only) ─────────────────────────────────────────────
  # Its one container uses the host (= this CT's) network, so Docker needs no bridge or
  # NAT. With iptables management off it also never switches FORWARD to DROP, which
  # would cut the Thread mesh off from the backbone. Log rotation as on the other guests.
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      iptables = false;
      ip6tables = false;
      bridge = "none";
      log-driver = "json-file";
      log-opts = {
        max-size = "50m";
        max-file = "3";
      };
    };
  };

  virtualisation.oci-containers.backend = "docker";

  # ── Multiprotocol radio stack ─────────────────────────────────────────────
  # cpcd + zigbeed + otbr-agent + mdnsd from the deprecated Silicon Labs Multiprotocol
  # add-on image, pinned by digest: nixpkgs has no cpcd/zigbeed, and its OTBR is not
  # built for CPC. The radio keeps the add-on's RCP firmware; the image's own versions
  # of cpcd/zigbeed/otbr are the ones that match it. The add-on's s6 tree cannot run
  # outside HAOS (it reads everything from the Supervisor API), so files/nixos/
  # multipan-run.sh replaces it. Never runs the image's firmware flasher.
  virtualisation.oci-containers.containers.multipan = {
    image = site.multipanImage;
    log-driver = "json-file";
    entrypoint = "/bin/bash";
    cmd = [ "/opt/iot/multipan-run.sh" ];
    environment = {
      BACKBONE_IF = "eth3";
      OTBR_LOG_LEVEL = "5"; # notice, the add-on default
    };
    volumes = [
      "${./multipan-run.sh}:/opt/iot/multipan-run.sh:ro"
      "${cpcdConf}:/usr/local/etc/cpcd.conf:ro"
      "${zigbeedDir}:/data/zigbeed"
      "${threadDir}:/var/lib/thread"
    ];
    extraOptions = [
      "--network=host"
      "--stop-timeout=30"
    ]
    # The add-on's grants: the radio, a TUN device for wpan0, and the network/IPC
    # capabilities otbr-agent needs. --privileged is the fallback for when Docker
    # cannot apply device rules inside this unprivileged CT; it stays bounded by the CT.
    ++ (
      if site.multipanPrivileged then
        [ "--privileged" ]
      else
        [
          "--device=${radioInContainer}"
          "--device=/dev/net/tun"
          "--cap-add=NET_ADMIN"
          "--cap-add=NET_RAW"
          "--cap-add=IPC_LOCK"
        ]
    );
  };

  systemd.services.docker-multipan = {
    unitConfig.ConditionPathExists = migratedMarker;
    serviceConfig.ExecStartPre = lib.mkAfter [
      "${requireZigbeedState}/bin/iot-require-zigbeed-state"
    ];
  };

  # ── MQTT broker ───────────────────────────────────────────────────────────
  # Replaces the Mosquitto add-on, whose logins came from Home Assistant through the
  # Supervisor. One user per client; plaintext passwords are read from root-only files
  # through LoadCredential and hashed by the module at start.
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        address = "::";
        port = mqttPort;
        users = {
          z2m = {
            passwordFile = "${secretsDir}/mqtt-z2m";
            acl = [
              "readwrite zigbee2mqtt/#"
              "readwrite homeassistant/#" # discovery out, HA's birth message in
            ];
          };
          hass = {
            passwordFile = "${secretsDir}/mqtt-hass";
            acl = [ "readwrite #" ];
          };
          frigate = {
            passwordFile = "${secretsDir}/mqtt-frigate";
            acl = [ "readwrite frigate/#" ];
          };
        };
      }
    ];
  };

  # The first boot of a fresh image has no password files yet; skip rather than fail.
  # Ansible starts the broker once tasks/secrets.yml has written them.
  systemd.services.mosquitto.unitConfig.ConditionPathExists = map (u: "${secretsDir}/mqtt-${u}") [
    "z2m"
    "hass"
    "frigate"
  ];

  # ── Zigbee2MQTT ───────────────────────────────────────────────────────────
  # The module copies these settings over ${z2mDir}/configuration.yaml on every start,
  # so this is the whole configuration. Secrets are `!secret <key>` references into
  # ${z2mDir}/secret.yaml (tasks/secrets.yml); Z2M resolves those only for mqtt.server/
  # user/password, advanced.network_key and frontend.auth_token, so the PAN IDs and the
  # channel are literal — they are broadcast over the air anyway. Devices and groups
  # live in devices.yaml/groups.yaml (module defaults), written by the migration.
  services.zigbee2mqtt = {
    enable = true;
    settings = lib.recursiveUpdate site.z2mExtraSettings {
      # Settings schema of Z2M 2.14 (lib/util/settings.ts CURRENT_VERSION). Without it
      # Z2M would rerun its config migrations on every start.
      version = 5;
      homeassistant.enabled = true;
      mqtt = {
        server = "mqtt://localhost:${toString mqttPort}";
        base_topic = "zigbee2mqtt";
        user = "z2m";
        password = "!secret mqtt_password";
      };
      # zigbeed speaks EZSP, as it did to the add-on's Z2M. Same driver as before the
      # migration; moving to `ember` is a separate, later change.
      serial = {
        port = "tcp://127.0.0.1:${toString ezspPort}";
        adapter = "ezsp";
      };
      # Must equal what zigbeed holds (they were checked against the HAOS config and the
      # coordinator backup when the state moved here).
      advanced = {
        network_key = "!secret network_key";
        pan_id = site.zigbee.panId;
        ext_pan_id = site.zigbee.extPanId;
        channel = site.zigbee.channel;
      };
      frontend = {
        enabled = true;
        host = "::";
        port = z2mFrontendPort;
        auth_token = "!secret frontend_token";
      };
    };
  };

  systemd.services.zigbee2mqtt = {
    # zigbeed comes up a few seconds after the container; until then Z2M fails to
    # connect and the module's Restart=on-failure retries every 10 s.
    wants = [
      "docker-multipan.service"
      "mosquitto.service"
    ];
    after = [
      "docker-multipan.service"
      "mosquitto.service"
    ];
    unitConfig.ConditionPathExists = [
      migratedMarker
      "${z2mDir}/secret.yaml"
    ];
  };
}
