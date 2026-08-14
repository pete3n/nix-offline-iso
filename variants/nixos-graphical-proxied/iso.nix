# nixos-graphical-proxied: the stock graphical (Calamares) installer,
# upstream Nix, modified so the install works on networks whose only route
# to the internet is a filtering LAN cache appliance. Keeps the full online
# install flow — nothing is baked beyond the stock image. The Proxy screen
# (a pre-Calamares dialog, ADR 0002) collects the Cache URL, probes it, and
# persists it into the generated configuration.nix.
# Ported from the nixos-26.05-graphical-proxy branch's flake.
{
  nixpkgs,
  shared,
  system,
}:
let
  # Prefilled into the Proxy screen's Cache URL field. A Builder prefill
  # (ADR 0009) replaces the tracked default when the ISO is built through
  # tools/build-iso.sh with ISO_CACHE_URL set — the prefill only; the
  # screen's Reachability probe still gates.
  cacheUrlDefault =
    if shared.builderPrefills.cacheUrl != null then
      shared.builderPrefills.cacheUrl
    else
      "http://nix-proxy.lan";

  calamaresOverlay = final: prev: {
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
          install -Dm755 ${../../calamares/proxy-screen.py} $out/bin/proxy-screen
          sed -i "1s|.*|#!${pythonEnv}/bin/python3|" $out/bin/proxy-screen
          substituteInPlace $out/bin/proxy-screen \
          	--replace-fail '@cacheUrlDefault@' '${cacheUrlDefault}'
          runHook postInstall
        '';
      };

    # Route every launch of the installer through the Proxy screen:
    # capture the stock desktop entry's Exec at build time, generate a
    # launcher that shows the screen and then execs that stock command,
    # and point the desktop entry at the launcher.
    calamares-nixos = prev.calamares-nixos.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        desktop=$out/share/applications/calamares.desktop
        [ -f "$desktop" ] \
        	|| { echo "ERROR: calamares.desktop not found in calamares-nixos"; exit 1; }
        origExec=$(sed -n 's/^Exec=//p' "$desktop" | head -n1)
        [ -n "$origExec" ] \
        	|| { echo "ERROR: no Exec= line in calamares.desktop"; exit 1; }
        substitute ${../../calamares/proxy-screen-launch.in} $out/bin/proxy-screen-launch \
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
        cp ${../../calamares/welcome-proxied.conf} $out/etc/calamares/modules/welcome.conf

        # 2. Drop the locale page's GeoIP lookup: geoip.kde.org is also
        # unreachable, so it could only fail (or stall) before falling
        # back to manual timezone selection — make manual selection the
        # deterministic behavior. The stock installPhase substituted
        # @glibcLocales@ before postInstall runs, so our replacement has
        # to be substituted again here.
        cp ${../../calamares/locale.conf} $out/etc/calamares/modules/locale.conf
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
        	${../../calamares/inject/proxy-persist.py} "$main" > "$main.new"
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
  installer = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.overlays = [ calamaresOverlay ]; }
      zfsWarningFix
      shared.baseGraphicalInstaller
      (
        { pkgs, lib, ... }:
        {
          # Terminal access to the Proxy screen for debugging; the
          # wrapped desktop entry is the normal path.
          environment.systemPackages = [ pkgs.proxy-screen ];

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];

          # Builder prefill provenance (ADR 0009). The Proxy screen gets
          # its prefill substituted at build time — nothing reads this
          # file here; it exists so `cat /etc/installer-prefills` answers
          # "which fleet flavor is this stick?" on every proxied product.
          environment.etc."installer-prefills" = lib.mkIf (shared.builderPrefills.cacheUrl != null) {
            text = ''
              ISO_CACHE_URL=${shared.builderPrefills.cacheUrl}
            '';
          };
        }
      )
    ];
  };
in
{
  configs.proxied = installer;
  isos.proxied = installer.config.system.build.isoImage;
}
