# determinate-cli-proxied: minimal console installer, Determinate Nix,
# for networks whose only route to the internet is a filtering LAN cache
# appliance. The ISO is thin — no target configuration, no baked closure,
# no URLs (ADR 0003): the Flake target is cloned from a LAN Config repo at
# install time and every fetch rides the Cache proxy.
# Ported from the nixos-26.05-cli-determinate-proxy branch's flake.
{
  nixpkgs,
  determinate,
  shared,
  system,
}:
let
  # The ISO's `determinate` lock identity, exposed on the live env for the
  # Pin match check (see docs/proxied/CONTEXT.md): a Config repo pinning
  # this narHash installs Determinate's nix straight from the installer's
  # store. The narHash is the identity — tarball lock nodes carry no git
  # rev, and the URL may legitimately differ (e.g. appliance-routed) while
  # the content matches. Read from the repo's root lock, where the shared
  # `determinate` input is pinned.
  rootLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  determinatePin =
    # A directly-declared input, so the root node maps it to a node name
    # (follows-lists only appear for overridden inputs).
    rootLock.nodes.${rootLock.nodes.${rootLock.root}.inputs.determinate}.locked;

  # The CLI installer: gate on proxy-setup's recorded Cache URL, run the
  # pre-flight checks (Pin match, declared substituters), then build the
  # cloned Flake target through the Cache proxy and install it.
  proxiedInstaller =
    pkgs:
    pkgs.writeShellApplication {
      name = "proxied-install";
      # No pkgs.nix here on purpose: the script's `nix` resolves to
      # Determinate's client from the system path, matching the daemon.
      # The upstream client warned "unknown setting" on every run —
      # determinate-nixd writes its own settings (lazy-trees, eval-cores)
      # into the /etc/nix/nix.conf it generates — and never reliably read
      # nix.custom.conf. nixos-install still bundles an upstream nix
      # internally; the script's NIX_CONFIG env covers it.
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.util-linux
        pkgs.parted
        pkgs.dosfstools
        pkgs.e2fsprogs
        pkgs.nixos-install-tools
      ];
      text = builtins.readFile ../../cli/proxied-install.sh;
    };

  # Step 4 of the Proxied install: gate on the Reachability probe and
  # declare the Cache URL as the live env's substituter (see
  # docs/proxied/CONTEXT.md: Proxy setup). proxied-install refuses to run
  # before it.
  proxySetup =
    pkgs:
    pkgs.writeShellApplication {
      name = "proxy-setup";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
      ];
      text = builtins.readFile ../../cli/proxy-setup.sh;
    };

  # A console cheat-sheet of manual partitioning commands (encrypted root +
  # swap). Shipped on the ISO so it is readable offline at the install
  # prompt.
  partitionHelp =
    pkgs:
    pkgs.writeShellApplication {
      name = "partition-help";
      runtimeInputs = [ pkgs.coreutils ];
      text = "cat ${../../cli/partition-help-proxied.txt}";
    };

  installerModule =
    { pkgs, lib, ... }:
    {
      nix.settings = {
        # The install-time `nix eval`/`nix build` calls are flakes-based.
        # Enable the features for every client in the live env — Determinate
        # defaults them on only for its own client, and the install script
        # also drives the upstream nix from its runtimeInputs.
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        # Empty until `proxy-setup` declares the Cache URL: on the filtered
        # network the stock default (cache.nixos.org) is a blackhole, so a
        # nix command run before setup should fail fast, not hang. This is
        # route ownership, not the offline products' guard idiom — the
        # Target's substituters come from its own Config repo. mkForce
        # because list settings merge: a bare [] concatenates with the
        # default definition instead of replacing it.
        substituters = lib.mkForce [ ];
      };

      environment.systemPackages = [
        (proxiedInstaller pkgs)
        (proxySetup pkgs)
        (partitionHelp pkgs)
        pkgs.cryptsetup
        pkgs.lvm2
        pkgs.tmux
        pkgs.fh
        # The Config-repo flow: clone over LAN git/SSH, then edit on the
        # spot (nano is present via its default-enabled NixOS module).
        pkgs.git
        pkgs.openssh
        pkgs.vim
      ];

      boot.zfs.forceImportRoot = false;
      networking.wireless.enable = lib.mkForce false;
      networking.networkmanager.enable = true;

      # Builder prefill (ADR 0009): an ISO built through tools/build-iso.sh
      # may carry the builder's own Cache URL; proxy-setup reads this file
      # for its prompt prefill — and only the prefill, the Reachability
      # probe still gates. Absent on a default build. `cat` it on a live
      # ISO to see exactly what was baked.
      environment.etc."installer-prefills" = lib.mkIf (shared.builderPrefills.cacheUrl != null) {
        text = ''
          ISO_CACHE_URL=${shared.builderPrefills.cacheUrl}
        '';
      };

      # Shown at the console login of the live installer.
      users.motd = lib.mkForce ''
	NixOS proxied installer (Determinate Nix)

	Keyboard not US-QWERTY? Change the console layout, e.g. loadkeys dvorak
	(back to QWERTY: loadkeys us  |  list layouts: localectl list-keymaps)

	1. Partition, format and mount your target at /mnt
		- For help with manual partitioning commands run: partition-help
		- Or skip this step: --disk auto-partitions a basic Linux layout
		 (EFI, swap, root), and a disko config partitions itself at install

	2. Clone your configuration:  git clone <your-repo-url> /tmp/nix-cfg

	3. Edit /tmp/nix-cfg if needed (hardware, hostname, LUKS device)

	4. Point Nix at the Cache proxy:  sudo proxy-setup

	5. Install:  sudo proxied-install
		- auto-partition + install:  sudo proxied-install --disk /dev/sdX
		- pick a config by name:  sudo proxied-install --host <name>
		- Flake-ref install (skips steps 2-3; installs a committed rev,
		 hardware config or disko layout must be committed for this host):
		 sudo proxied-install --flake 'git+ssh://<host>/<repo>.git'
		 For SSH refs put the key in root's ~/.ssh/config (a Host entry
		 with IdentityFile); nix ignores GIT_SSH_COMMAND.

	This ISO's Determinate pin is at /etc/determinate-pin — your config's
	flake.lock should pin the same narHash, or the install compiles Nix
	from source through the proxy.
      '';

      # The ISO's determinate pin, readable at the prompt and parseable by
      # the installer's Pin match check.
      environment.etc."determinate-pin".text = ''
        # The `determinate` input this ISO was built with. A Config repo
        # whose flake.lock pins the same narHash installs Determinate's nix
        # from this ISO's store; any other pin compiles it from source
        # through the Cache proxy (long build).
        narHash: ${determinatePin.narHash}
        url: ${determinatePin.url}
      '';

      # Allow SSH in to run the installer. The stock installer
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

  # ISO image tuning. The image carries only the live installer system —
  # no target closure, no baked config; the explicit storeContents just
  # restates the default (the live toplevel) for clarity.
  isoImageModule =
    { config, ... }:
    {
      isoImage = {
        storeContents = [ config.system.build.toplevel ];
        includeSystemBuildDependencies = false;
        squashfsCompression = "gzip -Xcompression-level 1";
      };
    };

  installer = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      # Determinate Nix in the live installer: replaces nix-daemon with
      # determinate-nixd so install-time builds run through Determinate.
      determinate.nixosModules.default
      # The Sentry/IDS endpoints are unreachable on the filtered network;
      # disable the attempts (runtime policy — see the module's comment).
      shared.determinateTelemetryOff
      installerModule
      shared.baseCliInstaller
      isoImageModule
    ];
  };
in
{
  configs.proxied = installer;
  isos.proxied = installer.config.system.build.isoImage;
}
