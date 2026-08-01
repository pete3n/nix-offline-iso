{
  description = "NixOS offline ISO builder — minimal CLI installer (channels + flake targets)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # The flake target, included as an input so its system closure and input
    # source trees can be pulled into the ISO store for offline install.
    # The target pins its own nixpkgs (and any other inputs) via its
    # committed flake.lock which gets baked into the ISO.
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
          text = "cat ${./cli/partition-help.txt}";
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
	NixOS offline installer

	Keyboard not US-QWERTY? Change the console layout, e.g. loadkeys dvorak
	(back to QWERTY: loadkeys us  |  list layouts: localectl list-keymaps)

	1. Partition and mount your target at /mnt
		- For help with partitioning commands run: partition-help
		- Let the installer auto-partition a basic Linux layout 
		 (EFI, swap, root partition) with: sudo offline-install --disk /dev/sdX
		- If disko has been configured, just run: sudo offline-install --host <name>

	2. Edit /tmp/nix-cfg/configuration.nix if needed (e.g. for LUKS device)

	3. Run: sudo offline-install

	The target host configuration is located at: /tmp/nix-cfg
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

      # Flake installer. Bakes a copy of the target flake whose every input is
      # pinned to a store path (via a rewritten lock) so it evaluates offline,
      # plus the target's built + derivation closures and each input's source.
      #
      # Reads the target's own committed flake.lock and, for each input,
      # swaps its `locked` ref for the store path of that input's source.
      mkFlakeInstaller =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Pick which nixosConfiguration's closure to bake. At install time the
          # script selects a config by hostname (--host), but the ISO must bake
          # exactly one config's closure so the offline build finds its store
          # paths.
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

          targetToplevel =
            (targetConfig.extendModules {
              modules = [ { system.includeBuildDependencies = true; } ];
            }).config.system.build.toplevel;

          # If the target declares a disko layout, bake its partition/format/mount
          # script (and its runtime closure) into the ISO store so offline-install
          # can partition the disk fully offline. `system.build.diskoScript` only
          # exists when the disko module is imported, so guard on its presence and
          # contribute nothing for a plain (non-disko) target.
          diskoStoreContents =
            if targetConfig.config.system.build ? diskoScript then
              [ targetConfig.config.system.build.diskoScript ]
            else
              [ ];

          # The target flake must ship a committed lock and must fetch the revs.
          # It must also be git-tracked to be visible to Nix.
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
          # `locked` ref to that store path. `lastModified` is stripped from the
          # fetch args (it is an output of fetchTree, not an accepted input) but
          # kept in the rewritten node.
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
              ]
              ++ diskoStoreContents
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
