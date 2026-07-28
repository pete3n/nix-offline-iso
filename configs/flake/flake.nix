{
  description = "Example offline flake target configuration";

  inputs = {
		# Indirect nixpkgs reference resolved via flake registry
    nixpkgs.url = "nixpkgs";
  };

  outputs =
    { nixpkgs, ... }:
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
        ];
      };
    };
}
