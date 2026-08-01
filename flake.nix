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
      cacheUrlDefault = "http://nix-proxy.lan";

      calamaresOverlay = final: prev: {
        # The Proxy screen (see CONTEXT.md and docs/adr/0002): a GTK dialog
        # shown before Calamares that collects/probes the Cache URL and, for
        # a Proxied install, reroutes the live environment's substituters.
        proxy-screen =
          let
            pythonEnv = final.python3.withPackages (pythonPackages: [
              pythonPackages.pygobject3
            ]);
          in
          final.stdenv.mkDerivation {
            pname = "proxy-screen";
            version = "0.1.0";
            dontUnpack = true;
            # gobject-introspection's setup hook + wrapGAppsHook3 gather the
            # GI typelibs (Gtk from gtk3, GLib/GObject via pygobject3) into
            # the wrapper's environment.
            nativeBuildInputs = [
              final.wrapGAppsHook3
              final.gobject-introspection
            ];
            buildInputs = [
              final.gtk3
              pythonEnv
            ];
            installPhase = ''
              runHook preInstall
              install -Dm755 ${./calamares/proxy-screen.py} $out/bin/proxy-screen
              sed -i "1s|.*|#!${pythonEnv}/bin/python3|" $out/bin/proxy-screen
              substituteInPlace $out/bin/proxy-screen \
              	--replace-fail '@cacheUrlDefault@' '${cacheUrlDefault}'
              runHook postInstall
            '';
          };

        # Route every launch of the installer through the Proxy screen:
        # capture the stock desktop entry's Exec at build time, generate a
        # launcher that shows the screen and then execs that stock command,
        # and point the desktop entry at the launcher. The ISO's autostart
        # item (makeAutostartItem in installation-cd-graphical-calamares.nix)
        # copies this desktop file verbatim, so autostart and menu launches
        # both pass through the screen.
        calamares-nixos = prev.calamares-nixos.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            desktop=$out/share/applications/calamares.desktop
            [ -f "$desktop" ] \
            	|| { echo "ERROR: calamares.desktop not found in calamares-nixos"; exit 1; }
            origExec=$(sed -n 's/^Exec=//p' "$desktop" | head -n1)
            [ -n "$origExec" ] \
            	|| { echo "ERROR: no Exec= line in calamares.desktop"; exit 1; }
            substitute ${./calamares/proxy-screen-launch.in} $out/bin/proxy-screen-launch \
            	--subst-var-by proxyScreen ${final.proxy-screen}/bin/proxy-screen \
            	--subst-var-by origExec "$origExec"
            chmod +x $out/bin/proxy-screen-launch
            sed -i "s|^Exec=.*|Exec=$out/bin/proxy-screen-launch|" "$desktop"
            grep -q "^Exec=$out/bin/proxy-screen-launch$" "$desktop" \
            	|| { echo "ERROR: failed to rewrite calamares.desktop Exec"; exit 1; }
          '';
        });

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
            (
              { pkgs, ... }:
              {
                # Terminal access to the Proxy screen for debugging; the
                # wrapped desktop entry is the normal path.
                environment.systemPackages = [ pkgs.proxy-screen ];

                # The ISO is built from a flake, so nixpkgs' nixosSystem sets
                # NIX_PATH=nixpkgs=flake:nixpkgs in the live session (see
                # nixpkgs-flake.nix, setNixPath). Resolving a flake: search
                # path entry requires the flakes feature, which installer
                # images leave disabled — nixos-install's
                # nix-build '<nixpkgs/nixos>' dies with "experimental Nix
                # feature 'flakes' is disabled". (Hydra's stock ISO is
                # channel-built and never has that entry.) Enable the
                # features in the LIVE environment only: flake:nixpkgs then
                # resolves via the registry pin to the nixpkgs tree already
                # baked into the ISO, no network involved. The Target is
                # unaffected — its generated config enables nothing.
                nix.settings.experimental-features = [
                  "nix-command"
                  "flakes"
                ];
                # With flakes on, keep the global registry off in the live
                # environment: the nixpkgs pin is local, and
                # channels.nixos.org is unreachable behind the Cache proxy.
                nix.settings.flake-registry = "";
              }
            )
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
