# Implementation plan: proxied-install ISO

Working document for the `nixos-26.05-graphical-proxy` branch. Language is in
`CONTEXT.md`; the dialog-not-viewstep decision is `docs/adr/0002`. Delete this
file when the work lands.

**Status (2026-08-01):** phases 0–3 are implemented and committed, including
the phase-4 sim harnesses (`tools/test-overlay.sh`, `tools/test-proxy-screen.sh`),
which pass in-jail. What remains is phase 4's host-side half: build the ISO
and run the VM matrix below. Two things only that pass can confirm: the real
`calamares.desktop` Exec shape (build guards fail loudly on drift) and the
GTK/sudo flow inside the live GNOME session.

Design anchors (settled in the 2026-08-01 grill session):

- The Cache URL is a **Nix substituter base URL** (path-routed appliance,
  plain HTTP). Nothing ever sets `http_proxy`-style variables — the stock
  `generateProxyStrings()` passthrough in `main.py` no-ops and is left alone.
- The Proxy screen is a pre-Calamares dialog; it owns the Reachability probe
  (`GET <url>/nix-cache-info`, expect 200 + body starting `StoreDir:`).
- Proxied install reroutes the live environment AND persists
  `nix.settings.substituters = [ <Cache URL> ]` into the Target's generated
  `configuration.nix`. Direct install touches nothing. (`flake-registry = ""`
  was originally persisted too — the first host ISO test showed it fails the
  target's nix.conf validation during nixos-install, because it is
  flakes-gated and stock targets have flakes disabled; it is now only an
  advisory comment in the generated config.)

## Phase 0 — carve out the offline machinery (`flake.nix`)

Delete: the `target-flake` input; the channels/flake installer split (one
`mkProxyInstaller` remains); `pinNode`/`offlineLock`/`inputSources`/
`flakeCfgDir`; `isoModule` (no baked `/iso/nix-cfg`, no `storeContents`, no
`includeSystemBuildDependencies`, no squashfs override — stock size is fine);
`offlineNixModule` (the live ISO keeps stock nix settings; the dialog rewrites
them at runtime); overlay steps 2–4 (config-copy injection, `--system` sed,
page stripping — stock pages stay); `calamares/inject/config-copy.py`;
`configs/`; `tools/test-offline-rebuild.sh`; `docs/adr/0001` (describes
deleted machinery); the `initialHashedPassword` mkForce (channels-target
artifact).

Keep: the `calamaresOverlay` skeleton + `welcome.conf` replacement (update its
header comment: the requirement moved to the Proxy screen, the installer is
not offline); `zfsWarningFix`; the
`installation-cd-graphical-calamares-gnome.nix` base.

Add: `cacheUrlDefault = "http://nix-proxy.lan";` as a named flake constant
threaded into the dialog package. Outputs become
`nixosConfigurations.proxy-<system>` and `iso.proxy-<system>` (both arches).

## Phase 1 — extensions overlay (config + injection)

1. `locale.conf` replacement without the `geoip:` block (deterministic manual
   timezone; geoip.kde.org is unreachable). **Gotcha:** the stock
   `installPhase` substitutes `@glibcLocales@` *before* `postInstall` runs, so
   the replacement must `substituteInPlace --replace-fail @glibcLocales@
   ${prev.glibcLocales}` itself in `postInstall`.
2. `main.py` injection "proxy-persist", house style (anchored awk + loud
   before/after guards). Anchor: the `# Write the configuration.nix file`
   comment. Logic: read `/run/nix-cache-url`; if present and matching
   `^https?://[A-Za-z0-9.:/_-]+$` (defense in depth — the dialog validates
   first), append a `cfgcacheproxy` chunk to `cfg` before it is written:
   substituters = the URL, flake-registry = "", under a comment naming the
   proxied installer as the author. Verify chunk composition against the
   surrounding `cfg +=` chunks (they compose inside one attrset).

## Phase 2 — Proxy screen (dialog + launcher)

- Package `proxy-screen`: python3 + PyGObject GTK app (~150 lines), its own
  gtk dependency so ISO contents don't matter. English-only.
  - Modes: **Proxied** (default; entry prefilled with `cacheUrlDefault`;
    probe against the entered URL) and **Direct** (probe against
    `https://cache.nixos.org/nix-cache-info`).
  - Continue is disabled until the active mode's probe passes (5s timeout,
    inline error + retry). Closing the window exits without launching
    Calamares.
  - Proxied Continue, via `sudo -n`: write `/run/nix-cache-url`; rewrite the
    live nix.conf (resolve the `/etc/nix/nix.conf` symlink, copy content,
    drop any `substituters =` line, append ours, replace the symlink with the
    file); `systemctl restart nix-daemon`. Compiled-in `trusted-public-keys`
    (cache.nixos.org-1) remain — no key changes needed.
  - Then exec the original Calamares launch command.
- Wiring: overlay `calamares-nixos` to patch its
  `share/applications/*.desktop` Exec to `proxy-screen` (which execs the
  original Exec target on Continue). The stock autostart
  (`makeAutostartItem` in `installation-cd-graphical-calamares.nix`) then
  picks up the wrapped entry automatically, and manual menu launches get the
  dialog too. Verify the desktop file's real Exec (pkexec wrapper vs plain)
  on the built package; verify `sudo -n` works for the live user (wheel is
  passwordless on installer images) — fallback is a pkexec policy.

## Phase 3 — docs

README rewrite: purpose; build + boot flow with the Proxy screen; the
appliance contract (base URL must serve `/nix-cache-info`, `/nar/`,
`*.narinfo`; plain HTTP is fine); Target persistence and how to undo it;
Direct install; **Limitations**: unfree/vendor source fetches (NVIDIA
userspace, CUDA) bypass substitution and fail mid-install behind the
appliance — the documented trap; future fixes are appliance-side (front
`cuda-maintainers.cachix.org` via `prefixUpstreams` + trusted key) or a
fail-fast check in the injection; DNS note (`nxs.lan` needs the internal
resolver via DHCP — enter the IP form of the Cache URL otherwise).

## Phase 4 — verification

- `tools/test-overlay.sh`: the postInstall simulation harness from the
  graphical-branch fix, adapted — run the overlay against the nixpkgs-vendored
  extensions source; assert stock pages REMAIN in the sequence, the injection
  compiles (`py_compile`), and a sample URL renders a syntactically valid
  config chunk.
- On the build host (jail can't build ISOs or run VMs):
  1. LAN VM or fake appliance (nginx with the same location shapes) →
     Proxied install end-to-end; Target config contains the block;
     first-boot `nixos-rebuild switch` through the appliance succeeds.
  2. Open-network NAT VM → Direct install behaves stock.
  3. No-network VM → probes fail, gate holds, retry works.
  4. Optional: unfree + NVIDIA selection → capture the real failure message
     verbatim for the README's limitation section.

Rough effort: phases 0–1 ≈ 2–3h, phase 2 ≈ 3–4h, phases 3–4 ≈ 2–3h plus ISO
build/VM time on the host.
