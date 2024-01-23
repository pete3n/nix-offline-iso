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
    systems = [
      "aarch64-linux"
      "x86_64-linux"
    ];

    in rec {
    nixosConfigurationsForAllSystems = system: {
      "offline-installer-${system}" = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        inherit system;
        modules = [
          ./nix-cfg/configuration.nix
          inputs.home-manager.nixosModules.default
          ({ pkgs, lib, ... }: {
            nixpkgs.overlays = [
              (self: super: {
                calamares-nixos-extensions = super.calamares-nixos-extensions.overrideAttrs (oldAttrs: rec {
                  patches = oldAttrs.patches or [] ++ [ 
                    ./patches/welcome.patch 
                    ./patches/nixos.patch
                  ];
                });
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
