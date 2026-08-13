# nixos-cli-offline: minimal console installer, upstream Nix, zero network
# attempts at install time. Supports both target shapes: the flake target
# (path-pinned lock bake) and the channels target (configuration.nix whose
# build deps bake via an explicit derivation-closure walk).
# Ported from the nixos-26.05-cli branch's flake; the flake-target bake and
# the installer script are the determinate line's newer copies (ADR 0008
# precedence rule) — the old extendModules/includeBuildDependencies bake is
# replaced by the offline-rebuild-deps anchoring contract (ADR 0001), which
# this variant's example configs already declare.
{
  nixpkgs,
  targetFlake,
  shared,
  system,
}:
let
  bake = shared.mkFlakeTargetBake {
    inherit system targetFlake;
    productName = "nixos-cli-offline";
  };

  installerModule = shared.mkOfflineCliInstallerModule { };

  flakeInstaller = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      shared.offlineNixModule
      installerModule
      shared.baseCliInstaller
      (shared.mkIsoModule {
        cfgDir = bake.flakeCfgDir;
        extraStoreContents = bake.extraStoreContents;
      })
    ];
  };

  # Channels installer. The target is built separately and its closure +
  # derivation closure are baked into the ISO store so the install can
  # rebuild the hardware-config diff offline.
  channelsToplevel =
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./configs/channels/configuration.nix
        { system.includeBuildDependencies = true; }
      ];
    }).config.system.build.toplevel;

  channelsInstaller = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      shared.offlineNixModule
      installerModule
      shared.baseCliInstaller
      (shared.mkIsoModule {
        cfgDir = ./configs/channels;
        extraStoreContents = [
          channelsToplevel
          channelsToplevel.drvPath
          nixpkgs.outPath
        ];
      })
    ];
  };
in
{
  configs.flake = flakeInstaller;
  configs.channels = channelsInstaller;
  isos.flake = flakeInstaller.config.system.build.isoImage;
  isos.channels = channelsInstaller.config.system.build.isoImage;
}
