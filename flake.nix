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
            # 1. Drop the stock startup internet requirement. It probes
            # geoip.kde.org and cache.nixos.org directly — both unreachable
            # behind the Cache proxy — and it runs at startup, before any
            # screen could collect the Cache URL. The Proxy screen's
            # Reachability probe replaces it (docs/adr/0002).
            cp ${./calamares/welcome.conf} $out/etc/calamares/modules/welcome.conf

            # 2. Drop the locale page's GeoIP lookup: geoip.kde.org is also
            # unreachable, so it could only fail (or stall) before falling
            # back to manual timezone selection — make manual selection the
            # deterministic behavior. The stock installPhase substituted
            # @glibcLocales@ before postInstall runs, so our replacement has
            # to be substituted again here.
            cp ${./calamares/locale.conf} $out/etc/calamares/modules/locale.conf
            substituteInPlace $out/etc/calamares/modules/locale.conf \
            	--replace-fail '@glibcLocales@' '${final.glibcLocales}'

            main=$out/lib/calamares/modules/nixos/main.py

            # 3. Persist the Cache URL into the generated configuration.nix.
            # Insert before `cfg += cfgtail` closes the generated attrset —
            # the write-site comment further down is too late, cfgtail has
            # already appended the closing brace by then.
            awk 'FNR==NR { block = block $0 ORS; next }
            		 /^[[:space:]]*cfg \+= cfgtail[[:space:]]*$/ && !done { printf "%s", block; done = 1 }
            		 { print }' \
            	${./calamares/inject/proxy-persist.py} "$main" > "$main.new"
            grep -q "proxied-iso: persist the Cache URL" "$main.new" \
            	|| { echo "ERROR: proxy-persist anchor (cfg += cfgtail) missing in main.py"; exit 1; }
            mv "$main.new" "$main"
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
