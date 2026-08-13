{
  description = "NixOS installer ISOs — offline and LAN-proxied installs, upstream and Determinate Nix";

  # One builder flake for the whole product matrix (ADR 0008). Each offline
  # product's example target is a path-input subflake with its own committed
  # lock; production ISOs point the input at a private flake instead:
  #   nix build .#installer-iso-determinate-cli-offline \
  #     --override-input target-determinate-cli-offline path:/your/flake
  # The proxied products deliberately have no target input — they bake
  # nothing (ADR 0003).
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Determinate Nix for the determinate products' live installers (their
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

      # Instantiate every product's wiring for one system. Explicit rather
      # than looped: five products, five lines, greppable.
      productsFor = system: {
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
      # ISO images: nix build .#installer-iso-<product>
      # The nixos-*-offline products also ship the channels-target shape as
      # installer-iso-<product>-channels.
      packages = shared.forAllSystems (
        system:
        let
          products = productsFor system;
        in
        {
          installer-iso-nixos-cli-offline = products.nixos-cli-offline.isos.flake;
          installer-iso-nixos-cli-offline-channels = products.nixos-cli-offline.isos.channels;
          installer-iso-nixos-graphical-offline = products.nixos-graphical-offline.isos.flake;
          installer-iso-nixos-graphical-offline-channels = products.nixos-graphical-offline.isos.channels;
          installer-iso-determinate-cli-offline = products.determinate-cli-offline.isos.flake;
          installer-iso-determinate-cli-proxied = products.determinate-cli-proxied.isos.proxied;
          installer-iso-nixos-graphical-proxied = products.nixos-graphical-proxied.isos.proxied;
        }
      );

      # The installer systems behind the ISOs, for inspection and debugging:
      # nix eval .#nixosConfigurations.<product>-<shape>-<system>.config...
      nixosConfigurations = nixpkgs.lib.mergeAttrsList (
        map (
          system:
          let
            products = productsFor system;
          in
          nixpkgs.lib.concatMapAttrs (
            productName: product:
            nixpkgs.lib.mapAttrs' (
              shapeName: installerConfig:
              nixpkgs.lib.nameValuePair "${productName}-${shapeName}-${system}" installerConfig
            ) product.configs
          ) products
        ) shared.systems
      );
    };
}
