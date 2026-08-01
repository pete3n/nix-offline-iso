{
  description = "NixOS proxied-install ISO builder (stock Calamares installer behind a LAN cache proxy)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Prefilled into the Proxy screen's Cache URL field; operators can
      # replace it per install. Consumed by the proxy-screen package
      # (phase 2 of docs/plan.md). See CONTEXT.md for the term.
      cacheUrlDefault = "http://nix-cache.nxs.lan";

      calamaresOverlay = final: prev: {
        calamares-nixos-extensions = prev.calamares-nixos-extensions.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            # Drop the stock startup internet requirement. It probes
            # geoip.kde.org and cache.nixos.org directly — both unreachable
            # behind the Cache proxy — and it runs at startup, before any
            # screen could collect the Cache URL. The Proxy screen's
            # Reachability probe replaces it (docs/adr/0002).
            cp ${./calamares/welcome.conf} $out/etc/calamares/modules/welcome.conf
          '';
        });
      };

      zfsWarningFix = {
        boot.zfs.forceImportRoot = false;
      };

      # The stock graphical Calamares (GNOME) installer, plus the overlay.
      # Unlike the offline branches, nothing is baked in and the live
      # environment keeps stock nix settings: the Proxy screen reroutes
      # substitution at runtime only when the operator chooses a Proxied
      # install.
      mkProxyInstaller =
        system:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.overlays = [ calamaresOverlay ]; }
            zfsWarningFix
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
          ];
        };

      proxyConfigs = forAllSystems (system: mkProxyInstaller system);
    in
    {
      nixosConfigurations = nixpkgs.lib.mapAttrs' (
        system: cfg: nixpkgs.lib.nameValuePair "proxy-${system}" cfg
      ) proxyConfigs;

      # ISO images:
      #   nix build .#iso.proxy-x86_64-linux
      iso = nixpkgs.lib.mapAttrs' (
        system: cfg: nixpkgs.lib.nameValuePair "proxy-${system}" cfg.config.system.build.isoImage
      ) proxyConfigs;
    };
}
