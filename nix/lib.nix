# Machinery shared across the product matrix (ADR 0008). Everything here
# came from the pre-flatten branches; where they had diverged, the
# determinate line's copy won. Per-product wiring lives in
# variants/<product>/iso.nix — this file holds only what at least two
# products genuinely share.
{ nixpkgs }:
rec {
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
  forAllSystems = nixpkgs.lib.genAttrs systems;

  baseCliInstaller = "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix";
  baseGraphicalInstaller = "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix";

  # Force the installer's nix to run offline (no cache.nixos.org probe, no
  # global flake-registry fetch), and enable flakes for the flake install.
  # nix.registry is forced empty for both ecosystems: Determinate's module
  # pins a FlakeHub `nixpkgs` registry entry and stock NixOS pins one to the
  # system nixpkgs — either is a bare-flakeref resolution path the offline
  # contract must not depend on.
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
      nix.registry = lib.mkForce { };
    };

  # Shared ISO image module. `cfgDir` is copied to /iso/nix-cfg; the
  # installer copies it into /etc/nixos at install time.
  #
  # `includeSystemBuildDependencies` bakes the *installer system's own*
  # build/derivation closure into the ISO store. Only the graphical channels
  # installer needs it: its target config is merged into the installer
  # system, so the installer's build closure is how the target's build deps
  # get baked. Every flake installer bakes the target's build deps
  # explicitly (targetToplevel.drvPath) instead — the installer itself is
  # throwaway and never rebuilt, so shipping its build closure would only
  # bloat the ISO.
  mkIsoModule =
    {
      cfgDir,
      extraStoreContents ? [ ],
      includeSystemBuildDependencies ? false,
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
          inherit includeSystemBuildDependencies;
          squashfsCompression = "gzip -Xcompression-level 1";
        };
      }
    );

  # The console offline installer environment, shared by the CLI offline
  # products (nixos-cli-offline, determinate-cli-offline).
  mkOfflineCliInstallerModule =
    {
      extraPackages ? (pkgs: [ ]),
    }:
    (
      { pkgs, lib, ... }:
      let
        # The CLI installer: the offline-install script + a login hint.
        offlineInstaller = pkgs.writeShellApplication {
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
          text = builtins.readFile ../cli/offline-install.sh;
        };

        # A console cheat-sheet of manual partitioning commands (encrypted
        # root + swap). Shipped on the ISO so it is readable offline at the
        # install prompt.
        partitionHelp = pkgs.writeShellApplication {
          name = "partition-help";
          runtimeInputs = [ pkgs.coreutils ];
          text = "cat ${../cli/partition-help.txt}";
        };
      in
      {
        environment.systemPackages = [
          offlineInstaller
          partitionHelp
          pkgs.cryptsetup
          pkgs.lvm2
          pkgs.tmux
        ]
        ++ extraPackages pkgs;

        boot.zfs.forceImportRoot = false;
        networking.wireless.enable = lib.mkForce false;
        networking.networkmanager.enable = true;

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
      }
    );

  # The flake-target bake: everything an offline flake install needs in the
  # ISO store, derived from the target flake INPUT (so a production build
  # can point it at a private flake with
  # `--override-input target-<product> path:/your/flake` and this tree is
  # never edited). Reads the lock from the input's own source — not a
  # hardcoded repo path — which is what makes the override work.
  mkFlakeTargetBake =
    {
      system,
      targetFlake,
      productName,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # Pick which nixosConfiguration's closure to bake. At install time the
      # script selects a config by hostname (--host), but the ISO must bake
      # exactly one config's closure so the offline build finds its store
      # paths.
      targetConfigs = targetFlake.nixosConfigurations;
      targetNames = builtins.attrNames targetConfigs;
      targetConfig =
        if targetConfigs ? nixos then
          targetConfigs.nixos
        else if builtins.length targetNames == 1 then
          targetConfigs.${builtins.head targetNames}
        else
          throw ''
            nix-offline-iso (${productName}): the target flake exposes multiple
            nixosConfigurations (${builtins.concatStringsSep ", " targetNames})
            and none named "nixos". The ISO bakes exactly one config's closure,
            so name your install target "nixos" or expose a single
            configuration.
          '';

      targetToplevel = targetConfig.config.system.build.toplevel;

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

      # The target flake must ship a committed lock. Read from the input's
      # source, so --override-input targets bring their own.
      targetLockPath = "${targetFlake}/flake.lock";
      rawLock =
        if builtins.pathExists targetLockPath then
          builtins.fromJSON (builtins.readFile targetLockPath)
        else
          throw ''
            nix-offline-iso (${productName}): the target flake carries no
            flake.lock. The flake target must ship a committed, git-tracked
            lock so its inputs can be pinned into the ISO for offline install.
            Generate it with:
              nix flake lock <your-target-flake> && git add flake.lock
          '';

      # Fetch each input's source (online, at ISO-build time) and repin its
      # `locked` ref to that store path. `lastModified` is stripped from the
      # fetch args (it is an output of fetchTree, not an accepted input) but
      # kept in the rewritten node.
      pinNode =
        _name: node:
        if node ? locked then
          let
            fetched = builtins.fetchTree (removeAttrs node.locked [ "lastModified" ]);
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
              # them).
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
        cp -r ${targetFlake} $out
        chmod -R u+w $out
        cp ${pkgs.writeText "flake.lock" offlineLock} $out/flake.lock
        # Keep it writable in case nix ever wants to touch it on the target.
        chmod u+w $out/flake.lock
      '';
    in
    {
      inherit flakeCfgDir targetToplevel;
      extraStoreContents = [
        # Built target system (runtime closure).
        targetToplevel
        # The target's derivation closure: .drvs + source tarballs, so the
        # parts that differ from the pre-baked build (because
        # nixos-generate-config regenerates hardware-configuration.nix) can
        # be rebuilt offline from source.
        targetToplevel.drvPath
      ]
      ++ diskoStoreContents
      # Every flake input's source, so the baked path-pinned lock resolves
      # entirely from the store offline.
      ++ inputSources;
    };
}
