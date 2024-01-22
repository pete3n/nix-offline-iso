{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager/release-23.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    ...
  } @ inputs: let
    inherit (self) outputs;
    # Supported systems for your flake packages, shell, etc.
    systems = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    # This is a function that generates an attribute by calling a function you
    # pass to it, with each system as an argument
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in rec {
    # Your custom packages
    # Accessible through 'nix build', 'nix shell', etc
    packages = forAllSystems (system: import ./nix-cfg/pkgs nixpkgs.legacyPackages.${system});
    # Formatter for your nix files, available through 'nix fmt'
    # Other options beside 'alejandra' include 'nixpkgs-fmt'
    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);

    # Your custom packages and modifications, exported as overlays
    overlays = import ./nix-cfg/overlays {inherit inputs;};
    # Reusable nixos modules you might want to export
    # These are usually stuff you would upstream into nixpkgs
    nixosModules = import ./nix-cfg/modules/nixos;
    # Reusable home-manager modules you might want to export
    # These are usually stuff you would upstream into home-manager
    homeManagerModules = import ./nix-cfg/modules/home-manager;

    nixosConfigurationsForAllSystems = system: {
      "offline-installer-${system}" = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        inherit system;
        modules = [
          ./nix-cfg/nixos/configuration.nix
          inputs.home-manager.nixosModules.default
          ({ pkgs, lib, ... }: {
            nixpkgs.overlays = [
              (self: super: {
                calamares-nixos-extensions = super.callPackage ./pkgs/calamares-nixos-extensions-offline { };
              })
            ];
          })
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
          ({ pkgs, config, ... }: {
            isoImage = {
              contents = [
                {
                    source = ./nix-cfg;
                    target = "/nix-cfg";
                }
              ];
              storeContents = [ 
                config.system.build.toplevel
              ];
              includeSystemBuildDependencies = true;
              squashfsCompression = "gzip -Xcompression-level 1";
            };
          })
        ];
      };
    };

    # Generate nixosConfigurations for each system
    nixosConfigurations = builtins.foldl' (acc: system: acc // (nixosConfigurationsForAllSystems system)) { } systems;

    # Generate iso configurations for each system
    iso = builtins.mapAttrs (name: config: config.config.system.build.isoImage) nixosConfigurations;
  };
}
