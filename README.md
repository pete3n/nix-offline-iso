# NixOS Proxied-Install ISO Builder

Builds an ISO of the **stock graphical NixOS installer** (Calamares, GNOME)
for networks whose only route to the internet is a filtering LAN cache
appliance — a path-routed nginx reverse proxy in front of `cache.nixos.org`
(the **Cache proxy**; see `CONTEXT.md` for this branch's language).

Unlike this repo's offline branches, nothing is baked into the ISO: the full
stock install flow (users, desktop choice, unfree toggle, partitioning) is
kept. The one addition is the **Proxy screen**, shown before Calamares
starts, where the operator confirms or replaces the Cache URL.

Targets **NixOS 26.05**.

## How an install works

1. Boot the ISO. The GNOME live session autostarts the installer; the Proxy
   screen appears first.
2. **Proxied install** (the default): the Cache URL field is prefilled
   (`http://nix-proxy.lan`) and probed automatically — the probe fetches
   `<url>/nix-cache-info` and expects a Nix binary-cache answer. Edit the
   URL and *Test connection* as needed; *Continue* unlocks only after the
   probe passes. Continuing reroutes the live environment's substituters to
   the Cache URL (restarting `nix-daemon`) and records the URL for step 5.
3. **Direct install** (escape hatch, e.g. for testing the ISO on an open
   network): probes `cache.nixos.org` itself; nothing is rerouted and
   nothing is persisted. The install behaves exactly like the stock ISO.
4. The stock Calamares flow runs. All packages substitute through the Cache
   proxy (Proxied) or directly (Direct).
5. For a Proxied install, the generated `/etc/nixos/configuration.nix` on
   the installed system additionally contains:

   ```nix
     # Route Nix through the LAN cache proxy that performed this install.
     # Written by the proxied installer; remove if this machine leaves
     # the filtered network.
     nix.settings.substituters = [ "http://nix-proxy.lan" ];
     # The global flake registry lives on channels.nixos.org, which the
     # cache proxy does not expose; disable the fetch instead of letting
     # flake commands hang on it.
     nix.settings.flake-registry = "";
   ```

   so the first `nixos-rebuild switch` works on the filtered network. To
   undo, delete the block and rebuild (sensible only once the machine has
   another route to packages).

Quitting the Proxy screen leaves the live session without starting
Calamares; relaunch from the dock/menu entry.

## Building

```
nix build .#iso.proxy-x86_64-linux     # or .#iso.proxy-aarch64-linux
```

Write the result to a USB stick with `dd` or similar. To change the
prefilled Cache URL, edit `cacheUrlDefault` in `flake.nix` and rebuild; at
install time the field is editable either way (an operator can also set
`PROXY_SCREEN_DEFAULT_URL` when launching `proxy-screen` manually).

## What the Cache proxy must serve

The Cache URL is a plain **Nix substituter base URL** — this project never
sets `http_proxy`-style variables. The appliance must pass these paths
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
  runs at startup, before any screen could collect the Cache URL. The Proxy
  screen's probe replaces it — see `docs/adr/0002` for why the screen is a
  dialog in front of Calamares rather than a page inside it.
- The locale page's **GeoIP lookup**: same reachability problem; timezone
  selection is simply manual.

## Limitations

- **Unfree packages that fetch from vendor URLs fail a Proxied install.**
  Unfree packages (NVIDIA userspace drivers, CUDA) are not on
  `cache.nixos.org`, so Nix builds them locally and fetches their sources
  from vendor domains (`download.nvidia.com`, …). Those fetches bypass the
  substituter mechanism entirely and cannot transit a path-routed reverse
  proxy. Ticking "allow unfree" on hardware whose scan pulls such a driver
  fails mid-install with a fetch error naming the vendor URL. Options:
  install free-only and add unfree bits post-install via configuration
  management, or front a cache that actually holds the unfree outputs
  (e.g. `cuda-maintainers.cachix.org` plus its trusted key) on the
  appliance.
- **DNS**: a name-form Cache URL must resolve via the live session's
  DHCP-provided resolver. If the LAN doesn't serve that name, use the IP
  form (e.g. `http://10.201.200.160`).
- Running `calamares` directly from a terminal bypasses the Proxy screen
  (the desktop entry and autostart do not). Use `proxy-screen-launch`, or
  run `proxy-screen` first, if you need the proxied flow from a shell.

## Testing

- `tools/test-overlay.sh <extensions-src>` — simulates the overlay's
  `postInstall` against a real `calamares-nixos-extensions` source tree
  (e.g. `pkgs/by-name/ca/calamares-nixos-extensions/src` in the pinned
  nixpkgs): anchors, guards, stock page sequence, and the injected
  persist logic end to end.
- `tools/test-proxy-screen.sh` — displayless tests of the Proxy screen's
  logic: URL validation, the symlinked-`nix.conf` rewrite, `--apply`
  ordering, probe semantics against a local HTTP fixture.
- Before trusting a build, run the VM matrix in `docs/plan.md` (phase 4):
  Proxied install end-to-end against a real or fake appliance including a
  first-boot `nixos-rebuild switch`, a Direct install on an open network,
  and the no-network probe gate.

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
