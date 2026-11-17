{ hermes-agent }:
final: _prev:
{
  # Keep upstream's locked package set and dependency-group override support.
  # The final derivation only assembles wrappers; patching it would leave the
  # Python wheel unchanged. Intercept the Python builder's source instead.
  hermes-agent = hermes-agent.packages.${final.stdenv.hostPlatform.system}.default.override (original: {
    # Upstream's flake never passes a version, so the install stamp, /api/status
    # and Hermes Desktop all report 0.0.0. Keep this in step with the tag that
    # flake.nix pins hermes-agent to.
    version = "0.23.0";
    callPackage = path: args:
      original.callPackage path (
        args
        // final.lib.optionalAttrs (builtins.baseNameOf (toString path) == "python.nix") {
          pythonSrc = final.applyPatches {
            name = "hermes-matrix-proxy-source";
            src = args.pythonSrc;
            patches = [ ./patches/matrix-proxy-origin.patch ];
          };
        }
      );
  });
}
