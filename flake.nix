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

      # The CLI installer: the offline-install script + a login hint.
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

      # A console cheat-sheet of manual partitioning commands (encrypted root +
      # swap). Shipped on the ISO so it is readable offline at the install
      # prompt.
      partitionHelp =
        pkgs:
        pkgs.writeShellApplication {
          name = "partition-help";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''cat ${./cli/partition-help.txt}'';
        };

      installerModule =
        { pkgs, lib, ... }:
        {
          environment.systemPackages = [
            (offlineInstaller pkgs)
            (partitionHelp pkgs)
            pkgs.cryptsetup
            pkgs.lvm2
            pkgs.tmux
          ];

          boot.zfs.forceImportRoot = false;

          # Seed a writable copy of the baked config into /tmp/nix-cfg at boot.
          systemd.services.seed-nix-cfg = {
            description = "Seed an editable config copy into /tmp/nix-cfg";
            wantedBy = [ "multi-user.target" ];
            path = [ pkgs.coreutils ];
            unitConfig = {
              RequiresMountsFor = "/iso";
              ConditionPathExists = [
                "/iso/nix-cfg"
                "!/tmp/nix-cfg"
              ];
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              cp -rT /iso/nix-cfg /tmp/nix-cfg
              chmod -R u+w /tmp/nix-cfg
            '';
          };

          # Shown at the console login of the live installer.
          users.motd = lib.mkForce ''

            NixOS offline installer (CLI)

            Keyboard not US-QWERTY? Change the console layout, e.g. loadkeys dvorak
            (back to QWERTY: loadkeys us  |  list layouts: localectl list-keymaps)

              1. Partition and mount your target at /mnt
                 (or let the installer do one disk: offline-install --disk /dev/sdX)
                 Encrypted or manual layout? Run: partition-help
              2. Edit /tmp/nix-cfg/configuration.nix if needed (e.g. LUKS device)
              3. sudo offline-install

            Config to install: /tmp/nix-cfg  (editable copy of baked /iso/nix-cfg)
          '';

          # Allow SSH in to run offline-install. The stock installer
          # enables sshd but leaves root key-only with no password; set one here.
          # These credentials are for the throwaway installer environment only.
          services.openssh.enable = true;
          services.openssh.settings.PermitRootLogin = lib.mkForce "yes";
          # `password` (not initialPassword) so it applies regardless of the
          # installer's users.mutableUsers setting. Installer-only, plaintext.
          users.users.root.initialHashedPassword = lib.mkForce null;
          users.users.root.password = "nixos";
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
              includeSystemBuildDependencies = false;
              squashfsCompression = "gzip -Xcompression-level 1";
            };
          }
        );

      # Minimal (console-only) installer base — no desktop, no Calamares.
      baseInstaller = "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix";

      # Channels installer. The target is built separately and its
      # closure + derivation closure are baked into the ISO store so the install
      # can rebuild the hardware-config diff offline.
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
