{
  description = "NixOS offline ISO builder (channels + flake targets)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # The example flake target is consumed as an input so we can (a) pull its
    # built system closure into the ISO store and (b) pull its input SOURCE
    # trees in too, which is what a later offline `nixos-install --flake` needs
    # to evaluate. `follows` unifies nixpkgs so there is only one copy.
    target-flake = {
      url = "path:./configs/flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      target-flake,
      ...
    }@inputs:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # --- Robust overlay ------------------------------------------------------
      # Re-seats the two offline-install changes on stable seams instead of the
      # old context-diff patches (which broke on every upstream rewrite):
      #   1. welcome.conf shipped wholesale (drops the `internet` requirement).
      #   2. main.py transformed with anchored awk/sed inserts:
      #      - user-config copy injected before `# build nixos-install command`,
      #      - `--flake`/`--offline` args added to the nixos-install list when a
      #        flake was copied to the target.
      # Each transform has a grep guard that FAILS the build if its anchor ever
      # disappears, so an upstream change can never silently ship a no-op.
      calamaresOverlay = final: prev: {
        calamares-nixos-extensions = prev.calamares-nixos-extensions.overrideAttrs (old: {
          postInstall =
            (old.postInstall or "")
            + ''
              # 1. Disable the online check.
              cp ${./calamares/welcome.conf} $out/etc/calamares/modules/welcome.conf

              main=$out/lib/calamares/modules/nixos/main.py

              # 2. Inject the user-config copy + flake detection.
              awk 'FNR==NR { block = block $0 ORS; next }
                   /# build nixos-install command/ && !done { printf "%s", block; done = 1 }
                   { print }' \
                ${./calamares/inject/config-copy.py} "$main" > "$main.new"
              grep -q "offline-iso: copy user-provided configuration" "$main.new" \
                || { echo "ERROR: config-copy anchor missing in main.py"; exit 1; }
              mv "$main.new" "$main"

              # 3. Add --flake to nixos-install when a flake was copied. (No
              # --offline: nixos-install is a wrapper that rejects unknown
              # flags. Offline behavior comes from the installer's nix.conf
              # -- substituters=[] and flake-registry="" -- plus the nixpkgs
              # input source being present in the ISO store.)
              sed -i 's|^\([ \t]*\)"nixos-install",|\1"nixos-install",\n\1*(["--flake", offline_flake_ref] if offline_flake_ref else []),|' "$main"
              grep -q -- '"--flake", offline_flake_ref\]' "$main" \
                || { echo "ERROR: nixos-install anchor missing in main.py"; exit 1; }

              # 4. Drop the imperative `users` step from the exec sequence.
              # The user's declarative config owns users AND passwords
              # (initialPassword / hashedPassword), so Calamares' post-install
              # `usermod` password step is redundant — and it FAILS (usermod
              # exit 6, "user does not exist") whenever the GUI username differs
              # from the one your config declares. Remove it from `exec` only;
              # the users PAGE stays in `show` (its job simply isn't enqueued).
              settings=$out/etc/calamares/settings.conf
              awk '
                /^- exec:/ { in_exec = 1 }
                /^- show:/ { in_exec = 0 }
                in_exec && /^[[:space:]]*-[[:space:]]*users[[:space:]]*$/ { next }
                { print }
              ' "$settings" > "$settings.new"
              # Guard: exactly one `- users` (the show page) must remain. If the
              # count is wrong the sequence changed upstream — fail loudly.
              [ "$(grep -cE '^[[:space:]]*-[[:space:]]*users[[:space:]]*$' "$settings.new")" = 1 ] \
                || { echo "ERROR: unexpected 'users' count in settings.conf exec sequence"; exit 1; }
              mv "$settings.new" "$settings"
            '';
        });
      };

      # Force the installer's nix to run FULLY OFFLINE. Without this, the
      # nixos-install pipeline reaches out to:
      #   - cache.nixos.org/nix-cache-info      (binary-cache substituter probe)
      #   - channels.nixos.org/flake-registry.json (global flake registry)
      # and fails the moment there is no network — which is the entire point of
      # this ISO. Baked into the installer environment so every nix invocation
      # nixos-install makes inherits it.
      offlineNixModule =
        { lib, ... }:
        {
          nix.settings = {
            # Required so `nixos-install --flake` works AND so the
            # `flake-registry` setting below is accepted (nix rejects it, and
            # thus fails nix.conf validation at build time, unless `flakes` is
            # enabled). The channels installer inherits this from the merged
            # target config; the flake installer merges no config, so set it
            # here for both.
            experimental-features = [
              "nix-command"
              "flakes"
            ];
            substituters = lib.mkForce [ ];
            trusted-substituters = lib.mkForce [ ];
            # Empty string disables fetching the global flake registry.
            flake-registry = "";
          };
        };

      # Shared ISO image module. `cfgDir` is copied to /iso/nix-cfg; the
      # installer copies it into /etc/nixos at install time.
      isoModule =
        {
          cfgDir,
          extraStoreContents,
        }:
        (
          { config, ... }:
          {
            isoImage = {
              contents = [
                {
                  source = cfgDir;
                  target = "/nix-cfg";
                }
              ];
              storeContents = [ config.system.build.toplevel ] ++ extraStoreContents;
              includeSystemBuildDependencies = true;
              squashfsCompression = "gzip -Xcompression-level 1";
            };
          }
        );

      # A channels-style installer. The target configuration.nix is merged into
      # the installer system itself so `system.build.toplevel` (and thus the ISO
      # store) contains the target's full closure — the mechanism that makes the
      # offline install work.
      mkChannelsInstaller =
        system:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            { nixpkgs.overlays = [ calamaresOverlay ]; }
            offlineNixModule
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
            ./configs/channels/configuration.nix
            (isoModule {
              cfgDir = ./configs/channels;
              extraStoreContents = [ ];
            })
          ];
        };

      # A flake-style installer. Here the target system is a SEPARATE flake, so
      # instead of merging it we pull its built toplevel + its input source
      # trees into the ISO store. The source trees (flake + nixpkgs) are what an
      # offline `nixos-install --flake ... --offline` needs to evaluate.
      mkFlakeInstaller =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Build the flake target WITH its build dependencies included in the
          # toplevel closure (Linus Heckemann's include-build-dependencies
          # technique). Because the offline install disables the binary cache,
          # the store must be able to (re)build the target — e.g. after
          # nixos-generate-config regenerates hardware-configuration.nix, which
          # makes the installed system differ slightly from the pre-baked one.
          # The channels target gets this via isoImage.includeSystemBuildDependencies;
          # for the external flake we inject it with extendModules.
          targetToplevel =
            (target-flake.nixosConfigurations.nixos.extendModules {
              modules = [ { system.includeBuildDependencies = true; } ];
            }).config.system.build.toplevel;

          # The copy of the flake that gets baked onto the ISO and installed to
          # the target. We rewrite its `nixpkgs` input from the indirect
          # `"nixpkgs"` to a `path:` pointing at the nixpkgs source already in
          # the ISO store. A path: input needs NO flake-registry lookup and NO
          # network — nix locks it locally and evaluates offline. This is the
          # reliable fix: registry resolution of an indirect input fails during
          # `nixos-install --flake` (we disable the global registry, and system
          # registry entries aren't consulted for input locking), and a locked
          # github: input can't be resolved from the store offline (nix#8953).
          # The repo's configs/flake/flake.nix stays clean (indirect); only this
          # baked copy carries the store path. Users repoint it to a normal
          # github ref after install for online rebuilds (see README).
          flakeCfgDir = pkgs.runCommand "offline-flake-cfg" { } ''
            cp -r ${./configs/flake} $out
            chmod -R u+w $out
            substituteInPlace $out/flake.nix \
              --replace-fail 'nixpkgs.url = "nixpkgs";' 'nixpkgs.url = "path:${nixpkgs}";'
          '';
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            { nixpkgs.overlays = [ calamaresOverlay ]; }
            offlineNixModule
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
            (isoModule {
              # Bake the path-pinned copy (not ./configs/flake) so the installed
              # flake resolves nixpkgs from the store offline.
              cfgDir = flakeCfgDir;
              # target system closure (build is a store copy, not a rebuild) +
              # flake source + nixpkgs source (the path: input target).
              extraStoreContents = [
                targetToplevel
                target-flake.outPath
                nixpkgs.outPath
              ];
            })
          ];
        };

      channelsConfigs = forAllSystems (system: mkChannelsInstaller system);
      flakeConfigs = forAllSystems (system: mkFlakeInstaller system);
    in
    {
      # nixosConfigurations for both variants, per system.
      nixosConfigurations =
        (nixpkgs.lib.mapAttrs' (
          system: cfg: nixpkgs.lib.nameValuePair "channels-${system}" cfg
        ) channelsConfigs)
        // (nixpkgs.lib.mapAttrs' (
          system: cfg: nixpkgs.lib.nameValuePair "flake-${system}" cfg
        ) flakeConfigs);

      # ISO images:
      #   nix build .#iso.channels-x86_64-linux
      #   nix build .#iso.flake-x86_64-linux
      iso =
        (nixpkgs.lib.mapAttrs' (
          system: cfg: nixpkgs.lib.nameValuePair "channels-${system}" cfg.config.system.build.isoImage
        ) channelsConfigs)
        // (nixpkgs.lib.mapAttrs' (
          system: cfg: nixpkgs.lib.nameValuePair "flake-${system}" cfg.config.system.build.isoImage
        ) flakeConfigs);
    };
}
