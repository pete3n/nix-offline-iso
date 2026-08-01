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

  # Test credentials only — change for any real use.
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
  # the system closure is what lets the installed machine run
  # `nixos-rebuild switch` for a CONFIG change (a password, an option, a
  # timezone) with no network: every config change re-runs the small "assembly"
  # derivations (/etc, users/groups, activation scripts, the toplevel itself),
  # and these are the tools those derivations run. It must live in the
  # committed config (not be injected at install time) so the ISO bakes, the
  # installer installs, and the machine later re-evaluates the *same* toplevel
  # — a no-change rebuild stays a no-op.
  #
  # Declared as an /etc file on purpose: interpolating the store paths into a
  # file that lands in /etc makes them references of the system closure BY
  # CONSTRUCTION — guaranteed baked into the ISO, copied by nixos-install, and
  # GC-rooted while the generation lives. (`system.extraDependencies` attaches
  # them only to the toplevel *derivation*, which the ISO and nixos-install do
  # not carry; `system.includeBuildDependencies` bakes the recursive build
  # closure — tens of GB.) Bonus: the file self-documents on the installed
  # system — cat /etc/nixos/offline-rebuild-deps.
  #
  # The list was converged with tools/test-offline-rebuild.sh (seconds per
  # iteration — tune with it, never with ISO+VM cycles) on nixpkgs 26.11pre
  # (9bc0289); other pins may need more — the probe names the missing tool.
  # Why each non-obvious entry (details: docs/adr/0001-offline-rebuild-deps.md):
  #  - stdenvNoCC: builds nearly every writeText/runCommand assembly drv.
  #  - mypy: the systemd-boot install script is re-generated AND type-checked
  #    when any boot.loader.* option changes.
  #  - texinfo, shared-mime-info, desktop-file-utils: system-path's post-build
  #    hook runs install-info/update-mime-database/update-desktop-database by
  #    absolute path whenever the package set changes (plain texinfo — a
  #    DIFFERENT derivation from the texinfoInteractive the system carries).
  #  - libxslt.bin: /etc/dbus-1 embeds the system-path store path, so it
  #    rebuilds in the same cone and runs xsltproc at build time.
  #  - jq bin AND dev: the toplevel runs jq.bin (bootspec), while
  #    systemd-generator-environment.json lists jq in nativeBuildInputs, which
  #    nixpkgs resolves to the *dev* output — and Nix schedules a derivation
  #    when ANY wanted output is missing.
  #  - lndir: assembles the systemd-units/user-units/tmpfiles.d trees. The
  #    `or` handles trees from before xorg.lndir was renamed to lndir.
  # Adding a genuinely NEW package or service still needs the network — its
  # build inputs were never baked.
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
        mypy
        texinfo
        shared-mime-info
        desktop-file-utils
        (lib.getBin libxslt)
        (lib.getBin jq)
        jq.dev
        (pkgs.lndir or pkgs.xorg.lndir)
      ]
    )
    + "\n";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.stateVersion = "26.05";

}
