# Example TARGET system config — channels style (no flake).
#
# This whole directory is copied to /iso/nix-cfg on the ISO, and the installer
# copies it into /etc/nixos on the target before running `nixos-install`. The
# ISO build also puts this system's closure into the store so the install works
# fully offline.
#
# Kept deliberately minimal (no desktop) so the ISO stays small and builds fast
# for testing. SSH is enabled so the installed VM can be reached over localhost.
{ config, pkgs, ... }:

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

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.stateVersion = "26.05";

  # Include build deps so the installed system can be rebuilt offline too.
  # (See Linus Heckemann's "include-build-dependencies" write-up.)
  # system.includeBuildDependencies = true;
}
