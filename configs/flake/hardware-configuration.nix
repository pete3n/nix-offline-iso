# PLACEHOLDER hardware-configuration.nix — vendor-neutral on purpose.
#
# This file only exists so the target system can be evaluated at ISO-build time.
# At install time the real `nixos-generate-config` scan regenerates it for the
# actual machine and the installer restores that generated copy — so nothing
# here needs to match your hardware.
#
# Do NOT hard-code CPU-specific force-loaded modules (e.g. kvm-intel/kvm-amd)
# here; a force-loaded kvm-intel makes systemd-modules-load fail with "Operation
# not supported" on hosts/VMs without that CPU's virtualization exposed.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/12345678-90ab-cdef-0123-4567890abcde";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/A1B2-C345";
    fsType = "vfat";
  };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  # Microcode / CPU-vendor specifics intentionally omitted from the placeholder;
  # the real scan adds them at install time.
}
