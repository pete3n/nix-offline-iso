# Example TARGET system config — flake style (imported by ./flake.nix).
#
# Identical intent to the channels example, but consumed through a flake so we
# can exercise offline `nixos-install --flake`. Kept minimal; SSH enabled.
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
}
