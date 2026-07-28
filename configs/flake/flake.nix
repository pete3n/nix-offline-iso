{
  description = "Example offline flake target configuration";

  inputs = {
		# Indirect nixpkgs reference resolved via flake registry
    nixpkgs.url = "nixpkgs";
  };

  outputs =
    { nixpkgs, ... }:
    {
      # The offline installer auto-selects this attribute: it uses the sole
      # nixosConfigurations entry if there is exactly one, otherwise it looks
      # for one named "nixos". Keep a single entry (or name it "nixos").
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
        ];
      };
    };
}
