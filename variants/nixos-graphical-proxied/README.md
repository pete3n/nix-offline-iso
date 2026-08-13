# NixOS Proxied-Install ISO Builder

> Product documentation for `nixos-graphical-proxied`, carried over from its pre-flatten
> branch. Paths like `configs/flake/` mean this directory's `configs/`;
> build commands may be stale — the authoritative output name is
> `nix build .#installer-iso-nixos-graphical-proxied` (see the repo README).

Builds an ISO of the **NixOS graphical installer** (Calamares, GNOME)
for networks whose only route to the internet is a proxy-cache.

## Usage

1. [Install Nix](https://nixos.org/download) with flakes enabled on an online
   system with plenty of free disk (see below).
2. Build the ISO:

```
nix build .#iso.proxy-x86_64-linux
```
```
```

3. Write the ISO to disk with `dd` or equivalent tool.

4. Boot the ISO. The GNOME live session autostarts the installer. The Proxy
   screen appears first.
5. Edit the URL and test the connection. *Continue* unlocks only after the
   probe passes. Continuing reroutes the live environment's substituters to
   the Cache URL (restarting `nix-daemon`) and records the URL for step 8.
6. **Direct install** bypasses the proxy and runs the installer as normal.
7. The installer runs as normal. All packages substitute through the Cache
   proxy (Proxied) or directly (Direct).
8. For a Proxied install, the generated `/etc/nixos/configuration.nix` on
   the installed system additionally contains:

   ```nix
     # Route Nix through the LAN cache proxy that performed this install.
     # Written by the proxied installer; remove if this machine leaves
     # the filtered network.
     nix.settings.substituters = [ "http://nix-proxy.lan" ];
   ```

## What the Cache proxy must serve

The Cache URL is a plain **Nix substituter base URL**, this project never
sets `http_proxy`-style variables. The proxy must pass these paths
through to `cache.nixos.org`, on plain HTTP or HTTPS:

- `<base>/nix-cache-info`
- `<base>/<hash>.narinfo`
- `<base>/nar/…`

Everything else may 403. GET/HEAD is enough. No key material moves: narinfos
are signed by `cache.nixos.org` itself and the installer verifies them
against the compiled-in `cache.nixos.org-1` trusted key, so a pass-through
proxy cannot tamper with substituted paths.

Only the primary cache is wired at install time. Additional prefix-routed
upstreams the appliance may expose (cachix mirrors, `/github/` source
tarballs for flake inputs) are for post-install use and don't participate in
the install.

## Stock behaviors this ISO removes

- The welcome page's **internet requirement**: it probes `geoip.kde.org` and
  `cache.nixos.org` directly (both unreachable behind the appliance) and
  runs at startup, before any screen could collect the Cache URL. 
- The locale page's **GeoIP lookup**: timezone selection is manual.

## Layout

```
flake.nix                     ISO builder + overlay (cacheUrlDefault lives here)
calamares/
  welcome.conf                replaces upstream's (internet requirement removed)
  locale.conf                 replaces upstream's (geoip removed)
  proxy-screen.py             the Proxy screen (GTK dialog + --apply root helper)
  proxy-screen-launch.in      launcher template: screen gates, then stock Exec
  inject/proxy-persist.py     injected into the nixos module: persists the Cache URL
tools/
  test-overlay.sh             overlay simulation + injection tests
  test-proxy-screen.sh        Proxy screen logic tests
CONTEXT.md                    this branch's language (Cache proxy, Cache URL, …)
docs/adr/                     decisions (0002: dialog, not a Calamares viewstep)
docs/plan.md                  implementation plan (host-side verification pending)
```
