# determinate-cli-offline: minimal console installer, Determinate Nix on
# both the Installer and the Target, zero network attempts at install time.
# Ported from the nixos-26.05-cli-determinate branch's flake (ADR 0007).
{
  nixpkgs,
  determinate,
  targetFlake,
  shared,
  system,
}:
let
  bake = shared.mkFlakeTargetBake {
    inherit system targetFlake;
    variantName = "determinate-cli-offline";
    # Unbakeable for Determinate targets: the build graph contains outputs
    # no cache publishes (separateDebugInfo debug outputs) whose rebuild
    # dies on sentry-native's git+submodules fetch. Determinate targets
    # install a committed disko config verbatim (offline-install skips
    # nixos-generate-config; the offline eval reproduces the baked drvs, so
    # nothing rebuilds at install time). Offline rebuilds after install are
    # the target's own job: it must keep the build tools its changes need in
    # its own closure (see README).
    bakeBuildDependencies = false;
  };

  installer = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      # Determinate Nix in the live installer: replaces nix-daemon with
      # determinate-nixd so install-time builds run through Determinate.
      # offlineNixModule comes after so its mkForce offline settings win.
      determinate.nixosModules.default
      shared.offlineNixModule
      # Zero network ATTEMPTS: silence Determinate's telemetry/crash
      # reporting too — the knob ADR 0007's residual was missing (amended).
      shared.determinateTelemetryOff
      (shared.mkOfflineCliInstallerModule {
        # fh (the FlakeHub CLI) ships only on the determinate flavor.
        extraPackages = pkgs: [ pkgs.fh ];
      })
      shared.baseCliInstaller
      (shared.mkIsoModule {
        # Bake the path-pinned copy (not the raw target) so the installed
        # flake resolves its inputs from the store offline.
        cfgDir = bake.flakeCfgDir;
        extraStoreContents = bake.extraStoreContents;
      })
    ];
  };
in
{
  configs.flake = installer;
  isos.flake = installer.config.system.build.isoImage;
}
