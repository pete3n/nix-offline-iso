{
  description = "NixOS offline ISO builder — minimal CLI installer (channels + flake targets)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Example flake target, included as an input so its system closure and input
    # source trees can be pulled into the ISO store for offline install.
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

      # Force the installer's nix to run offline (no cache.nixos.org probe, no
      # global flake-registry fetch), and enable flakes for the flake install.
      offlineNixModule =
        { lib, ... }:
        {
          nix.settings = {
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

      # The CLI installer: the offline-install script + a login hint. Unlike the
      # graphical (Calamares) variant, there is no GUI — the user runs
      # `offline-install` from the console.
      offlineInstaller =
        pkgs:
        pkgs.writeShellApplication {
          name = "offline-install";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.util-linux
            pkgs.parted
            pkgs.dosfstools
            pkgs.e2fsprogs
            pkgs.nixos-install-tools
            pkgs.nix
          ];
          text = builtins.readFile ./cli/offline-install.sh;
        };

      installerModule =
        { pkgs, lib, ... }:
        {
          environment.systemPackages = [ (offlineInstaller pkgs) ];
          # Shown at the console login of the live installer.
          users.motd = lib.mkForce ''

            NixOS offline installer (CLI)

              1. Partition and mount your target at /mnt
                 (or let the installer do one disk: offline-install --disk /dev/sdX)
              2. sudo offline-install

            Baked config: /iso/nix-cfg   (override by editing a copy in /tmp/nix-cfg)
          '';

          # Headless access to the LIVE installer. A minimal (console) image has
          # no GUI, and some VMs (SPICE/quickemu) don't render the framebuffer
          # console, so allow SSH in to run offline-install. The stock installer
          # enables sshd but leaves root key-only with no password; set one here.
          # These credentials are for the throwaway installer environment only.
          services.openssh.enable = true;
          services.openssh.settings.PermitRootLogin = lib.mkForce "yes";
          # `password` (not initialPassword) so it applies regardless of the
          # installer's users.mutableUsers setting. Installer-only, plaintext.
          users.users.root.initialHashedPassword = lib.mkForce null;
          users.users.root.password = "nixos";
          # For anything but a throwaway VM, prefer a key over the password above:
          # users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@host" ];
        };

      # Shared ISO image module. `cfgDir` is copied to /iso/nix-cfg; the
      # offline-install script copies it into /etc/nixos at install time.
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
              # NOT set (prototype): this would bake the *installer's* own
              # build/derivation closure. The offline install only needs the
              # TARGET's build deps, which we bake explicitly via the target's
              # `.drvPath` in extraStoreContents; the installer is never rebuilt.
              # Dropping it avoids shipping the installer's build closure.
              # (Verify offline install still succeeds before relying on this.)
              includeSystemBuildDependencies = false;
              squashfsCompression = "gzip -Xcompression-level 1";
            };
          }
        );

      # Minimal (console-only) installer base — no desktop, no Calamares.
      baseInstaller = "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix";

      # Channels installer. The target is built SEPARATELY (not merged into the
      # installer, which would risk config conflicts with the minimal CD) and its
      # closure + derivation closure are baked into the ISO store so the install
      # can rebuild the hardware-config diff offline. `<nixpkgs>` on the installer
      # resolves to this same nixpkgs (flake setNixPath), so the pre-baked build
      # and the install-time build match.
      mkChannelsInstaller =
        system:
        let
          channelsToplevel =
            (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                ./configs/channels/configuration.nix
                { system.includeBuildDependencies = true; }
              ];
            }).config.system.build.toplevel;
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            offlineNixModule
            installerModule
            baseInstaller
            (isoModule {
              cfgDir = ./configs/channels;
              extraStoreContents = [
                channelsToplevel
                channelsToplevel.drvPath
                nixpkgs.outPath
              ];
            })
          ];
        };

      # Flake installer. Bakes a path-pinned copy of the flake (nixpkgs rewritten
      # to a store path + a matching complete lock) so it evaluates offline, plus
      # the target's built + derivation closures.
      mkFlakeInstaller =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          targetToplevel =
            (target-flake.nixosConfigurations.nixos.extendModules {
              modules = [ { system.includeBuildDependencies = true; } ];
            }).config.system.build.toplevel;

          # Complete flake.lock pinning the copied flake's `nixpkgs` to the store
          # path, so nix resolves nothing and never rewrites the lock (which for a
          # path: flake would mutate the dir mid-eval and cause a NAR mismatch).
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
            chmod u+w $out/flake.lock
          '';
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            offlineNixModule
            installerModule
            baseInstaller
            (isoModule {
              cfgDir = flakeCfgDir;
              extraStoreContents = [
                targetToplevel
                targetToplevel.drvPath
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
