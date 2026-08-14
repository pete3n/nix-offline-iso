{
  description = "NixOS installer ISO builder for offline and proxied installs.";

  # Each offline variant's example target is a path-input subflake with its own 
	# committed lock; production ISOs point the input at a private flake instead:
  #   nix build .#installer-iso-determinate-cli-offline \
  #     --override-input target-determinate-cli-offline path:/your/flake
  # The proxied variantss deliberately have no target input.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Determinate Nix for the determinate variants' live installers (their
    # targets get Determinate from their own flake's pin). Pinned to major
    # version 3, matching what the example target bakes.
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";

    target-nixos-cli-offline.url = "path:./variants/nixos-cli-offline/configs/flake";
    target-nixos-graphical-offline.url = "path:./variants/nixos-graphical-offline/configs/flake";
    target-determinate-cli-offline.url = "path:./variants/determinate-cli-offline/configs/flake";
  };

  outputs =
    {
      self,
      nixpkgs,
      determinate,
      ...
    }@inputs:
    let
      shared = import ./nix/lib.nix { inherit nixpkgs; };

      # Instantiate every variant's wiring for one system. 
      variantsFor = system: {
        nixos-cli-offline = import ./variants/nixos-cli-offline/iso.nix {
          inherit nixpkgs shared system;
          targetFlake = inputs.target-nixos-cli-offline;
        };
        nixos-graphical-offline = import ./variants/nixos-graphical-offline/iso.nix {
          inherit nixpkgs shared system;
          targetFlake = inputs.target-nixos-graphical-offline;
        };
        determinate-cli-offline = import ./variants/determinate-cli-offline/iso.nix {
          inherit nixpkgs determinate shared system;
          targetFlake = inputs.target-determinate-cli-offline;
        };
        determinate-cli-proxied = import ./variants/determinate-cli-proxied/iso.nix {
          inherit nixpkgs determinate shared system;
        };
        nixos-graphical-proxied = import ./variants/nixos-graphical-proxied/iso.nix {
          inherit nixpkgs shared system;
        };
      };
    in
    {
      # ISO images: nix build .#installer-iso-<variant>
      # The nixos-*-offline variants also ship the channels-target shape as
      # installer-iso-<variant>-channels.
      packages = shared.forAllSystems (
        system:
        let
          variants = variantsFor system;
        in
        {
          installer-iso-nixos-cli-offline = variants.nixos-cli-offline.isos.flake;
          installer-iso-nixos-cli-offline-channels = variants.nixos-cli-offline.isos.channels;
          installer-iso-nixos-graphical-offline = variants.nixos-graphical-offline.isos.flake;
          installer-iso-nixos-graphical-offline-channels = variants.nixos-graphical-offline.isos.channels;
          installer-iso-determinate-cli-offline = variants.determinate-cli-offline.isos.flake;
          installer-iso-determinate-cli-proxied = variants.determinate-cli-proxied.isos.proxied;
          installer-iso-nixos-graphical-proxied = variants.nixos-graphical-proxied.isos.proxied;
        }
      );

      # The installer systems behind the ISOs, for inspection and debugging:
      # nix eval .#nixosConfigurations.<variant>-<shape>-<system>.config...
      nixosConfigurations = nixpkgs.lib.mergeAttrsList (
        map (
          system:
          let
            variants = variantsFor system;
          in
          nixpkgs.lib.concatMapAttrs (
            variantName: variant:
            nixpkgs.lib.mapAttrs' (
              shapeName: installerConfig:
              nixpkgs.lib.nameValuePair "${variantName}-${shapeName}-${system}" installerConfig
            ) variant.configs
          ) variants
        ) shared.systems
      );
    };
}
