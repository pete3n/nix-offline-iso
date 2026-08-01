{
  description = "NixOS offline ISO builder (channels + flake targets)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # The flake target, included as an input so its system closure and input
    # source trees can be pulled into the ISO store for offline install. The
    # target pins its own nixpkgs (and any other inputs) via its committed
    # flake.lock.
    target-flake.url = "path:./configs/flake";
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
          postInstall = (old.postInstall or "") + ''
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
            sed -i 's|^\([ \t]*\)"nixos-install",|\1"nixos-install",\n\1*(["--system", offline_system_path, "--no-channel-copy"] if offline_system_path else []),|' "$main"
            grep -q -- '"--system", offline_system_path\]' "$main" \
            	|| { echo "ERROR: nixos-install anchor missing in main.py"; exit 1; }

            # 4. Strip the Calamares pages/jobs whose choices the
            # user-provided configuration overrides. 
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
            zfsWarningFix
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
            ./configs/channels/configuration.nix
            (
              { lib, ... }:
              {
                users.users.root.initialHashedPassword = lib.mkForce null;
              }
            )
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

          # Pick which nixosConfiguration's closure to bake. The Calamares flake
          # install auto-selects the same attribute at install time (see
          # calamares/inject/config-copy.py), so the ISO must bake exactly one
          # config's closure: prefer one named "nixos", else the sole entry.
          targetConfigs = target-flake.nixosConfigurations;
          targetNames = builtins.attrNames targetConfigs;
          targetConfig =
            if targetConfigs ? nixos then
              targetConfigs.nixos
            else if builtins.length targetNames == 1 then
              targetConfigs.${builtins.head targetNames}
            else
              throw ''
                nix-offline-iso: configs/flake exposes multiple nixosConfigurations
                (${builtins.concatStringsSep ", " targetNames}) and none named "nixos".
                The ISO bakes exactly one config's closure, so name your install
                target "nixos" or expose a single configuration.
              '';

          # Build the flake target WITH build dependencies in the toplevel
          # closure (Linus Heckemann's include-build-dependencies technique) so
          # the offline install can re-build the target after
          # nixos-generate-config regenerates hardware-configuration.nix, which
          # makes the installed system differ slightly from the pre-baked one.
          targetToplevel =
            (targetConfig.extendModules {
              modules = [ { system.includeBuildDependencies = true; } ];
            }).config.system.build.toplevel;

          # The target flake must ship a committed, git-tracked lock so its input
          # revisions can be pinned into the ISO for offline evaluation.
          targetLockPath = ./configs/flake/flake.lock;
          rawLock =
            if builtins.pathExists targetLockPath then
              builtins.fromJSON (builtins.readFile targetLockPath)
            else
              throw ''
                nix-offline-iso: configs/flake/flake.lock is missing. The flake
                target must carry a committed, git-tracked lock so its inputs can
                be pinned into the ISO for offline install. Generate it with:
                  nix flake lock ./configs/flake && git add configs/flake/flake.lock
              '';

          # Fetch each input's source (online, at ISO-build time) and repin its
          # `locked` ref to that store path, leaving `original` and flake.nix
          # untouched.
          pinNode =
            _name: node:
            if node ? locked then
              let
                fetched = fetchTree (removeAttrs node.locked [ "lastModified" ]);
              in
              {
                value = node // {
                  locked = {
                    type = "path";
                    path = fetched.outPath;
                    narHash = fetched.narHash;
                  }
                  // (if node.locked ? lastModified then { inherit (node.locked) lastModified; } else { })
                  # Carry rev/revCount through the repin (path refs accept
                  # them). nixpkgs derives system.nixos.versionSuffix from
                  # self.shortRev, falling back to "dirty" — dropping rev made
                  # the installed target evaluate a *different* toplevel
                  # (…-dirty) than the ISO baked (…-<rev>), so every rebuild,
                  # no-ops included, re-built the whole version-suffix cone.
                  // (if node.locked ? rev then { inherit (node.locked) rev; } else { })
                  // (if node.locked ? revCount then { inherit (node.locked) revCount; } else { });
                };
                source = fetched.outPath;
              }
            else
              {
                value = node;
                source = null;
              };

          pinned = builtins.mapAttrs pinNode rawLock.nodes;
          offlineLock = builtins.toJSON (
            rawLock // { nodes = builtins.mapAttrs (_name: entry: entry.value) pinned; }
          );
          # Every input source, to seed into the ISO store for the offline build.
          inputSources = builtins.filter (path: path != null) (
            map (entry: entry.source) (builtins.attrValues pinned)
          );

          flakeCfgDir = pkgs.runCommand "offline-flake-cfg" { } ''
            cp -r ${./configs/flake} $out
            chmod -R u+w $out
            cp ${pkgs.writeText "flake.lock" offlineLock} $out/flake.lock
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
            zfsWarningFix
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
              ]
              # Every flake input's source (nixpkgs + any others), so the baked
              # path-pinned lock resolves entirely from the store offline.
              ++ inputSources;
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
