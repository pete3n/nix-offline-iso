{
  description = "Example offline flake target configuration";

  inputs = {
    # INDIRECT ref (resolved via the flake registry), deliberately NOT a
    # github: URL. Three contexts, all handled:
    #   - ISO build: ../../flake.nix consumes this with
    #     `inputs.nixpkgs.follows = "nixpkgs"`, so it uses the ISO's nixpkgs.
    #   - Offline install: the installer pins `nixpkgs` in its system registry
    #     to the nixpkgs source baked into the ISO store, so this resolves to a
    #     local path with NO network and NO committed lock required.
    #   - Standalone (on a normal machine): resolves via your machine registry.
    #
    # Do NOT commit a flake.lock here that pins nixpkgs to github — a github
    # lock overrides the registry and reintroduces the offline fetch failure.
    nixpkgs.url = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, ... }:
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
