{
  description = "Hermes Agent and Gateway for sentinel-lp (LXC 107 and 108)";

  inputs = {
    # Same FlakeHub selector as roles/matrix: "0.1" is the newest *unstable*
    # nixpkgs ("0" would be the newest stable). The exact revision is pinned by
    # flake.lock, which is committed alongside this file — tracking unstable does
    # not mean re-resolving on every build. Bump deliberately with `nix flake update`.
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      # Build the LXC image from the same nixpkgs the running system rebuilds
      # against, so the template and `nixos-rebuild switch` can never diverge.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"`, unlike every other
    # input in this repo. nixos-generators is build machinery, so pointing it at
    # our nixpkgs is right. hermes-agent is a *package*, and its own nix/overlays.nix
    # says the opposite in as many words:
    #
    #   The overlay is a pure alias for this flake's own package — NOT a
    #   re-instantiation against the consumer's nixpkgs. This guarantees
    #   pkgs.hermes-agent, `nix build .#default`, and the NixOS module's default
    #   package are all the exact same locked, tested derivation.
    #
    # The package is built by uv2nix from a uv.lock resolved against *their*
    # nixpkgs, and upstream documents this flake as best-effort maintained. Forcing
    # a follows re-resolves that closure against a nixpkgs nobody tested it on. The
    # price for not doing so is a second nixpkgs in the image; the alternative is a
    # build that breaks on someone else's schedule.
    #
    # Pinned to a stable release tag (not `+canary.*`). To update, change the tag,
    # run `nix flake lock`, update `version` in overlay.nix to match, and rebase
    # patches/matrix-proxy-origin.patch.
    hermes-agent.url = "github:NousResearch/hermes-agent/v0.23.0";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-generators,
      hermes-agent,
      ...
    }:
    let
      system = "x86_64-linux";

      baseModules = [
        # Provides the proxmoxLXC.* options and the container plumbing (isContainer,
        # /sbin/init, networkd handoff). Pulled in explicitly rather than relying on
        # the nixos-generators format, so `nixos-rebuild switch` inside the running
        # container evaluates the same module set the image was built from.
        "${nixpkgs}/nixos/modules/virtualisation/proxmox-lxc.nix"
        # Upstream's module defaults directly to its flake package, so explicitly
        # select our overlaid package for both guests and both image builds.
        hermes-agent.nixosModules.default
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ (import ./overlay.nix { inherit hermes-agent; }) ];
          services.hermes-agent.package = pkgs.hermes-agent;
        })
      ];
    in
    {
      # Used in-container by `nixos-rebuild switch --flake /etc/nixos#hermes`.
      nixosConfigurations.hermes = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = baseModules ++ [ ./configuration.nix ];
      };
      nixosConfigurations.hermes-gateway = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = baseModules ++ [ ./gateway-configuration.nix ];
      };

      # Used on the workstation by roles/hermes/tasks/build_template.yml to produce
      # the vztmpl tarball uploaded to Proxmox.
      packages.${system} = {
        proxmox-lxc = nixos-generators.nixosGenerate {
          inherit system;
          modules = baseModules ++ [ ./configuration.nix ];
          format = "proxmox-lxc";
        };
        gateway-proxmox-lxc = nixos-generators.nixosGenerate {
          inherit system;
          modules = baseModules ++ [ ./gateway-configuration.nix ];
          format = "proxmox-lxc";
        };
      };
    };
}
