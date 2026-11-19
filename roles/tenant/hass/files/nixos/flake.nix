{
  description = "Home Assistant Docker tenant for sentinel-lp (LXC 113, backend)";

  inputs = {
    # FlakeHub semver: "0.1" is the newest *unstable* nixpkgs ("0" would be the
    # newest stable). The exact revision is pinned by flake.lock, which is
    # committed alongside this file — tracking unstable does not mean re-resolving
    # on every build. Bump deliberately with `nix flake update`.
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      # Build the LXC image from the same nixpkgs the running system rebuilds
      # against, so the template and `nixos-rebuild switch` can never diverge.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-generators,
      ...
    }:
    let
      system = "x86_64-linux";

      modules = [
        # Provides the proxmoxLXC.* options and the container plumbing (isContainer,
        # /sbin/init, networkd handoff). Pulled in explicitly rather than relying on
        # the nixos-generators format, so `nixos-rebuild switch` inside the running
        # container evaluates the same module set the image was built from.
        "${nixpkgs}/nixos/modules/virtualisation/proxmox-lxc.nix"
        ./configuration.nix
      ];
    in
    {
      # Used in-container by `nixos-rebuild switch --flake /etc/nixos#hass`.
      nixosConfigurations.hass = nixpkgs.lib.nixosSystem {
        inherit system modules;
      };

      # Used on the workstation by roles/tenant/hass/tasks/build_template.yml to produce
      # the vztmpl tarball uploaded to Proxmox.
      packages.${system}.proxmox-lxc = nixos-generators.nixosGenerate {
        inherit system modules;
        format = "proxmox-lxc";
      };
    };
}
