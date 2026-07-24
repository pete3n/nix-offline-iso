{
  description = "NixOS offline ISO builder (channels + flake targets)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Example flake target which is included as an input so its system closure
		# and input source trees can be pulled for offline install.
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

              # 3. For a flake install, pass the PRE-BUILT system path via
              # --system (config-copy.py builds it in the live store first).
              sed -i 's|^\([ \t]*\)"nixos-install",|\1"nixos-install",\n\1*(["--system", offline_system_path] if offline_system_path else []),|' "$main"
              grep -q -- '"--system", offline_system_path\]' "$main" \
                || { echo "ERROR: nixos-install anchor missing in main.py"; exit 1; }

              # 4. Remove the user configuraiton step from the Calamares install process.
              # The user provided config sets users and passwords.
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

      # Force the installer's nix to run offline. Without this, the
      # nixos-install pipeline reaches out to:
      #   - cache.nixos.org/nix-cache-info      (binary-cache substituter probe)
      #   - channels.nixos.org/flake-registry.json (global flake registry)
      offlineNixModule =
        { lib, ... }:
        {
          nix.settings = {
            # Required so `nixos-install --flake` works. 
						# The channels installer inherits this from the merged target config. 
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

      # NixOS channel configuration installer. The target configuration.nix is merged into
      # the installer system itself so `system.build.toplevel` contains the target's full closure.
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

      # NixOS flake configuration installer. Pull the built toplevel + input source
      # trees into the ISO store. The source trees (flake + nixpkgs) are what an
      # offline `nixos-install --flake ... --offline` needs to evaluate.
      mkFlakeInstaller =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Build the flake target WITH its build dependencies included in the
          # toplevel closure (Linus Heckemann's include-build-dependencies
          # technique). Because the offline install disables the binary cache,
          # the store must be able to re-build the target after
          # nixos-generate-config regenerates hardware-configuration.nix, which
          # makes the installed system differ slightly from the pre-baked one.
          # The channel's target gets this via isoImage.includeSystemBuildDependencies;
          # for the external flake it gets injected with extendModules.
          targetToplevel =
            (target-flake.nixosConfigurations.nixos.extendModules {
              modules = [ { system.includeBuildDependencies = true; } ];
            }).config.system.build.toplevel;

          # A pre-computed flake.lock that pins the copied flake's `nixpkgs`
          # input to the nixpkgs source path in the ISO store.
          targetLock = builtins.toJSON {
            version = 7;
            root = "root";
            nodes = {
              root = {
                inputs = {
                  nixpkgs = "nixpkgs";
                };
              };
              nixpkgs = {
                original = {
                  type = "path";
                  path = "${nixpkgs}";
                };
                locked = {
                  type = "path";
                  path = "${nixpkgs}";
                  narHash = nixpkgs.narHash;
                  lastModified = nixpkgs.lastModified;
                };
              };
            };
          };

          flakeCfgDir = pkgs.runCommand "offline-flake-cfg" { } ''
            cp -r ${./configs/flake} $out
            chmod -R u+w $out
            substituteInPlace $out/flake.nix \
              --replace-fail 'nixpkgs.url = "nixpkgs";' 'nixpkgs.url = "path:${nixpkgs}";'
            cp ${pkgs.writeText "flake.lock" targetLock} $out/flake.lock
            # Keep it writable in case nix ever wants to touch it on the target.
            chmod u+w $out/flake.lock
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
              extraStoreContents = [
                # Built target system (runtime closure).
								# Unchanged parts are a store copy.
                targetToplevel
                # The target's derivation closure: .drvs + source tarballs, so
                # the parts that differ from the pre-baked build (because
                # nixos-generate-config regenerates hardware-configuration.nix)
                # can be rebuilt offline from source. This is what
                # `isoImage.includeSystemBuildDependencies` bakes for the
                # channels target; without it, offline rebuild fails for flakes.
                targetToplevel.drvPath
                # nixpkgs source path for the copied flake.
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
