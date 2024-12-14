{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
  };

  outputs =
    { nixpkgs, ... }@inputs:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

    in
    rec {
      nixosConfigurationsForAllSystems = system: {
        "offline-installer-${system}" = nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit inputs;
          };
          inherit system;
          modules = [
            ./nix-cfg/configuration.nix
            {
              nixpkgs.overlays = [
                (self: super: {
                  calamares-nixos-extensions = super.calamares-nixos-extensions.overrideAttrs (oldAttrs: {
                    src = super.fetchFromGitHub {
                      owner = "NixOS";
                      repo = "calamares-nixos-extensions";
                      rev = "0.3.19";
                      hash = "sha256-/WdSMqtF8DKplsDx00l8HYijYvOUBb55Opv3Z8+T6QU=";
                    };
                    patches = oldAttrs.patches or [ ] ++ [
                      ./patches/welcome.patch
                      ./patches/main.patch
                    ];
                  });
                })
              ];
            }
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
            (
              { config, ... }:
              {
                isoImage = {
                  contents = [
                    {
                      source = ./nix-cfg;
                      target = "/nix-cfg";
                    }
                  ];
                  storeContents = [ config.system.build.toplevel ];
                  includeSystemBuildDependencies = true;
                  squashfsCompression = "gzip -Xcompression-level 1";
                };
              }
            )
          ];
        };
      };

      # Generate nixosConfigurations for each system
      nixosConfigurations = builtins.foldl' (
        acc: system: acc // (nixosConfigurationsForAllSystems system)
      ) { } systems;

      # Generate iso configurations for each system
      iso = builtins.mapAttrs (name: config: config.config.system.build.isoImage) nixosConfigurations;
    };
}
