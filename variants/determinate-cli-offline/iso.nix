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
    productName = "determinate-cli-offline";
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
