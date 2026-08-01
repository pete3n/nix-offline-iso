# Cache proxy additions this branch needs

Tracking note. The Cache proxy appliance (`services.nix-cache-proxy`, config
lives outside this repo) must learn to serve the Determinate input tree before
a Proxied install from this branch can work. This list is what to add; nothing
here is implemented yet.

The concrete URL set below is read off this branch's root `flake.lock`
(Determinate 3.21.9 — the live installer pins the same tree a matching
Config repo does). Re-derive it when the pinned Determinate version
changes: the fetch surface moves with the pin.

## Already noted (carried over from the graphical-proxy branch)

- **`cuda-maintainers.cachix.org`** (plus its trusted key) via
  `prefixUpstreams`, so unfree NVIDIA/CUDA outputs substitute instead of
  building locally and fetching vendor-URL sources the appliance cannot
  route. See "Limitations" in the graphical-proxy README.

## New: required for the Determinate tree, regardless of routing shape

- **`install.determinate.systems`** — the `determinate-nixd` binary blobs,
  fetched as flake `file` inputs:
  `https://install.determinate.systems/determinate-nixd/tag/v3.21.9/<arch>`.
  Only `x86_64-linux` is needed for this fleet; route the path generically so
  a version bump doesn't need appliance edits.
- **`releases.nixos.org`** — Determinate's `nix` builds against a nixexprs
  tarball pin, e.g.
  `https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1043539.9bc02893134c/nixexprs.tar.xz`.
  Serves directly (no redirect chasing expected).
- **github route allowlist add: `edolstra/flake-compat`** — the one github
  input in the tree outside the current allowlist. (`NixOS/nixpkgs` entries
  are already allowed.)

## Decision pending: how the FlakeHub tarballs route

Deferred (2026-08-01) until the appliance work actually happens. Consequence:
the docs' Config-repo conventions (and the org's GitLab starter template,
which lives outside this repo — `configs/flake/` is deleted on this branch)
cannot commit to concrete proxied input URLs until the shape is picked.

Six inputs lock as `api.flakehub.com/f/pinned/...` tarballs: `determinate`
itself, `nix` (DeterminateSystems/nix-src), `nixpkgs` (NixOS 0.2511),
`nixpkgs-weekly`, `flake-parts` (hercules-ci), `git-hooks.nix` (cachix). Two
ways to make them reachable:

- **Shape A — front `flakehub.com` + `api.flakehub.com`.** New path routes on
  the appliance. FlakeHub tarball GETs are believed to answer with redirects
  (range URL → pinned URL → object storage); the appliance should NOT follow
  them server-side but `proxy_redirect`-rewrite each Location back through
  itself, because Nix records the redirect target as the locked URL — that is
  how a semver-range input locks to a pinned one. Client-side following
  through rewritten Locations keeps `nix flake update` and range tracking
  working; locks then record appliance-addressed URLs (LAN-only portability,
  same property as Shape B). Redirect behavior must be verified.
- **Shape B — rewrite everything github-shaped through the existing codeload
  route.** All six repos exist on GitHub; the user flake template overrides
  them to `tarball+http://<cache-url>/github/<owner>/<repo>/tar.gz/<rev>`.
  Appliance work is allowlist adds only: `DeterminateSystems/determinate`,
  `DeterminateSystems/nix`, `hercules-ci/flake-parts`, `cachix/git-hooks.nix`.
  No redirect engineering, but explicit-rev pins lose FlakeHub's semver
  ranges — Determinate updates become manual rev bumps in the template.

## Excluded: FlakeHub Cache ("why not Determinate's own binary cache?")

Determinate's binary cache (`cache.flakehub.com`) cannot fill the
outputs-substitution gap anonymously. Evidence from the pinned module
(determinate 3.21.9, `modules/nixos.nix`): it configures **no** substituter by
default — `edgeCacheSubstituters` defaults to `null` and, when set, merely
writes admin-supplied URLs into `/etc/determinate/config.json` (the hook for
FlakeHub Cache's on-prem edge nodes, a paid product); FlakeHub Cache itself is
only attached by `determinate-nixd login`, i.e. a per-machine token on a
FlakeHub plan. Routing it through the appliance would add: org accounts, a
token inside the throwaway live installer, token refresh against
`api.flakehub.com`, and Authorization-header pass-through. Rejected as a
default; revisit only if the org adopts FlakeHub anyway. The adopted answer
is the **Pin match** convention (CONTEXT.md): Config repos pin `determinate`
to the ISO's rev so the outputs come from the Installer's store; the
installer warns before a from-source drift build.
(`install.determinate.systems` is a plain file host, not a binary cache — its
static nix tarballs feed the `curl | sh` installer, not the NixOS module,
which builds `nix` from the `nix-src` flake.)

## To verify appliance-side

- Redirect behavior of `api.flakehub.com/f/pinned/...` and of
  `install.determinate.systems/determinate-nixd/...` (302-to-CDN vs direct).
- GET/HEAD-only policy is sufficient for all of the above (expected: yes —
  every fetch here is a plain download).
