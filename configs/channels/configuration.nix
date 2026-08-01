{
  config,
  lib,
  pkgs,
  ...
}:

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

  # Offline-rebuild dependencies. Carrying the outputs of these build tools in
  # the system closure is what lets the installed machine run
  # `nixos-rebuild switch` for a config change (a password, an option, a
  # timezone) with no network: every config change re-runs the small "assembly"
  # derivations (/etc, users/groups, activation scripts, the toplevel itself),
  # and these are the tools those derivations run.
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
