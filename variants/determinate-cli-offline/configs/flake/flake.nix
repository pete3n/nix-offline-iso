{
  description = "Example offline flake target configuration (Determinate Nix)";

  inputs = {
    # Indirect nixpkgs reference resolved via flake registry
    nixpkgs.url = "nixpkgs";

    # Determinate Nix pinned to major version 3.
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
  };

  outputs =
    { nixpkgs, determinate, ... }:
    {
      # The offline installer auto-selects this attribute: it uses the sole
      # nixosConfigurations entry if there is exactly one, otherwise it looks
      # for one named "nixos". Keep a single entry (or name it "nixos").
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          # Determinate Nix (patched daemon/binary + determinate-nixd). This is
          # what makes the installed system run Determinate Nix rather than
          # upstream Nix.
          determinate.nixosModules.default
          ./configuration.nix
        ];
      };
    };
}
