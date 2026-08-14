# nixos-graphical-offline: stock Calamares (GNOME) installer, upstream Nix,
# zero network attempts at install time. Supports the flake target (baked
# path-pinned lock; Calamares' nixos module is injected with config-copy.py
# to install the pre-built system) and the channels target (merged into the
# installer system so isoImage.includeSystemBuildDependencies carries its
# build deps). Ported from the nixos-26.05-graphical branch's flake; the
# flake-target bake is the determinate line's newer copy (ADR 0008).
{
  nixpkgs,
  targetFlake,
  shared,
  system,
}:
let
  calamaresOverlay = final: prev: {
    calamares-nixos-extensions = prev.calamares-nixos-extensions.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        # 1. Disable the online check.
        cp ${../../calamares/welcome-offline.conf} $out/etc/calamares/modules/welcome.conf

        main=$out/lib/calamares/modules/nixos/main.py

        # 2. Inject the user-config copy + flake detection.
        awk 'FNR==NR { block = block $0 ORS; next }
        		 /# build nixos-install command/ && !done { printf "%s", block; done = 1 }
        		 { print }' \
        	${../../calamares/inject/config-copy.py} "$main" > "$main.new"
        grep -q "offline-iso: copy user-provided configuration" "$main.new" \
        	|| { echo "ERROR: config-copy anchor missing in main.py"; exit 1; }
        mv "$main.new" "$main"

        # 3. For a flake install, pass the PRE-BUILT system path via
        # --system (config-copy.py builds it in the live store first).
        sed -i 's|^\([ \t]*\)"nixos-install",|\1"nixos-install",\n\1*(["--system", offline_system_path, "--no-channel-copy"] if offline_system_path else []),|' "$main"
        grep -q -- '"--system", offline_system_path' "$main" \
        	|| { echo "ERROR: nixos-install anchor missing in main.py"; exit 1; }

        # 4. Strip the Calamares pages/jobs whose choices the
        # user-provided configuration overrides.
        settings=$out/etc/calamares/settings.conf
        for anchor in users packagechooser 'notesqml@unfree'; do
        	grep -qE "^[[:space:]]*-[[:space:]]*$anchor[[:space:]]*\$" "$settings" \
        		|| { echo "ERROR: expected a '$anchor' entry in settings.conf sequence"; exit 1; }
        done
        awk '
        	/^[[:space:]]*-[[:space:]]*users[[:space:]]*$/ { next }
        	/^[[:space:]]*-[[:space:]]*packagechooser[[:space:]]*$/ { next }
        	/^[[:space:]]*-[[:space:]]*notesqml@unfree[[:space:]]*$/ { next }
        	{ print }
        ' "$settings" > "$settings.new"
        # Guard: all three must now be gone from the sequence. Anything
        # left means the sequence changed upstream — fail loudly.
        for anchor in users packagechooser 'notesqml@unfree'; do
        	grep -qE "^[[:space:]]*-[[:space:]]*$anchor[[:space:]]*\$" "$settings.new" \
        		&& { echo "ERROR: '$anchor' still present in settings.conf sequence"; exit 1; }
        done
        mv "$settings.new" "$settings"
      '';
    });
  };

  zfsWarningFix = {
    boot.zfs.forceImportRoot = false;
  };

  bake = shared.mkFlakeTargetBake {
    inherit system targetFlake;
    variantName = "nixos-graphical-offline";
  };

  flakeInstaller = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.overlays = [ calamaresOverlay ]; }
      shared.offlineNixModule
      zfsWarningFix
      shared.baseGraphicalInstaller
      (shared.mkIsoModule {
        # Bake the path-pinned copy (not the raw target) so the installed
        # flake resolves nixpkgs from the store offline.
        cfgDir = bake.flakeCfgDir;
        extraStoreContents = bake.extraStoreContents;
      })
    ];
  };

  # Channels installer. The target configuration.nix is merged into the
  # installer system itself so `system.build.toplevel` contains the target's
  # full closure, and includeSystemBuildDependencies carries its build deps.
  channelsInstaller = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.overlays = [ calamaresOverlay ]; }
      shared.offlineNixModule
      zfsWarningFix
      shared.baseGraphicalInstaller
      ./configs/channels/configuration.nix
      (
        { lib, ... }:
        {
          users.users.root.initialHashedPassword = lib.mkForce null;
        }
      )
      (shared.mkIsoModule {
        cfgDir = ./configs/channels;
        # The merged installer+target system's build closure is the only
        # mechanism that carries the channels target's build deps.
        includeSystemBuildDependencies = true;
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
