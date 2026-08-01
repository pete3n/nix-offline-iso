{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = true;
  };

  # Test credentials only
  users.users.root.initialPassword = "test";
  users.users.tester = {
    isNormalUser = true;
    initialPassword = "test";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
  };

  environment.systemPackages = with pkgs; [
    tmux
    vim
    git
  ];

  # Offline-rebuild dependencies. Carrying the OUTPUTS of these build tools in
  # the system closure is what lets this machine run `nixos-rebuild switch` for
  # a CONFIG change (a password, an option, a timezone) with no network: every
  # config change re-runs the small "assembly" derivations (/etc, users/groups,
  # activation scripts, the toplevel itself), and these are the tools those
  # derivations run. It must live in the committed config (not be injected at
  # install time) so the ISO bakes, the installer installs, and this machine
  # later re-evaluates the *same* toplevel — a no-change rebuild stays a no-op.
  #
  # Declared as an /etc file on purpose. Interpolating the store paths into a
  # file that lands in /etc makes them references of the system closure BY
  # CONSTRUCTION — guaranteed baked into the ISO, copied by nixos-install, and
  # GC-rooted while the generation lives. (`system.extraDependencies` attaches
  # them only to the toplevel *derivation*; whether they reach the built
  # *output* — which is all the ISO and nixos-install carry — is a nixpkgs
  # implementation detail, and betting on it is how an offline rebuild ended up
  # trying to compile Python from source.) Bonus: the file self-documents on
  # the installed system — cat /etc/nixos/offline-rebuild-deps.
  #
  # stdenvNoCC matters: writeText/runCommand build nearly every assembly
  # derivation and reference it, and nothing else in the system retains it.
  # Adding a genuinely NEW package/service still needs the network — its build
  # inputs were never baked. Tune this list only against
  # tools/test-offline-rebuild.sh (seconds per iteration), not ISO+VM cycles.
  environment.etc."nixos/offline-rebuild-deps".text =
    lib.concatMapStringsSep "\n" toString (
      with pkgs;
      [
        stdenv
        stdenvNoCC
        perl
        python3
        bash
        binutils
        bison
        bzip2
        gnu-config
        # The systemd-boot install script is re-generated AND type-checked with
        # mypy whenever a boot.loader.* option changes, so mypy's output must be
        # on the target. Without it, a one-line configurationLimit change
        # planned 854 from-source derivations: with no substituters, even
        # *downloading* a source tarball is a derivation needing curl's output,
        # so one missing tool recursed into building the world.
        mypy
        # Toggling a service whose package rides in systemPackages (e.g.
        # disabling services.openssh) is the config-change class that alters
        # system-path *membership*, so system-path itself rebuilds. Its
        # post-build hook (environment.extraSetup) runs install-info,
        # update-mime-database and update-desktop-database by absolute path;
        # the hook text lives only in the derivation, never in the built
        # output, so nothing else retains these tools. Note the system carries
        # texinfoInteractive — the hook runs *plain* texinfo, a different
        # derivation. /etc/dbus-1 embeds the system-path store path in its
        # config, so it rebuilds in the same cone and runs xsltproc (libxslt's
        # bin output) at build time.
        texinfo
        shared-mime-info
        desktop-file-utils
        (lib.getBin libxslt)
        # Two more build-only tools of the assembly layer, surfaced by the
        # first on-target sshd test: every toplevel build pipes bootspec and
        # systemd-generator-environment.json through jq, and the
        # systemd-units / user-units / tmpfiles.d trees are assembled with
        # lndir. Neither is referenced by the built system, so they must be
        # pinned here.
        #
        # jq needs TWO outputs pinned. The toplevel invokes jq.bin directly,
        # but systemd-generator-environment.json.drv lists jq in its
        # nativeBuildInputs, and nixpkgs resolves dependency-list entries of
        # multi-output packages to their *dev* output (dev then drags bin in
        # via its nix-support propagation). Nix schedules a derivation when
        # ANY wanted output is missing, so baking bin alone still sent the
        # rebuild off to compile jq — and with it fetchurl's own curl and the
        # entire stage0→gcc bootstrap — from source.
        (lib.getBin jq)
        jq.dev
        lndir
      ]
    )
    + "\n";

  # nix-command and flakes are enabled by default under Determinate Nix (pulled
  # in via determinate.nixosModules.default in flake.nix), so no manual
  # nix.settings.experimental-features is needed here.

  system.stateVersion = "26.05";
}
