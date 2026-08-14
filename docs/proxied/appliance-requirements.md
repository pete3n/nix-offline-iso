# Cache proxy additions the proxied products need

> Generic requirements: any appliance fronting a Proxied install must
> provide these routes. The fleet-annotated original (hostnames, revs,
> verification log) lives in the fleet's private repo.

Tracking note. The Cache proxy appliance (`services.nix-cache-proxy`; config
now lives in the sibling `nix-nginx-proxy` repo, which is authoritative for
appliance capability). Status 2026-08-11: the FlakeHub chain
(`/flakehub/` → `/flakehub-api/` → `/flakehub-cdn/`, Location **and**
Link-header rewriting via `flakehubSourceProxy.publicBaseUrl`), the
`/install-determinate/` prefix route, and the github allowlist adds below
are all implemented there (`hosts/nix-cache/configuration.nix`). Remaining
live verifications: an end-to-end `nix flake lock` through the box, the
`install.determinate.systems` redirect shape (200-direct vs 302-to-CDN),
and which keys sign its narinfos.

The concrete URL set below is read off this branch's root `flake.lock`
(Determinate 3.21.9 — the live installer pins the same tree a matching
Config repo does). Re-derive it when the pinned Determinate version
changes: the fetch surface moves with the pin.

## Already noted (carried over from the graphical-proxy branch)

- **`cuda-maintainers.cachix.org`** (plus its trusted key) via
  `prefixUpstreams`, so unfree NVIDIA/CUDA outputs substitute instead of
  building locally and fetching vendor-URL sources the appliance cannot
  route. See "Limitations" in the graphical-proxy README.

## Rejected 2026-08-11: hosting the Config repo on the appliance

- Considered serving the Config repo from the appliance's nginx (dumb HTTP,
  read-only) because it predates every workstation. Rejected same day: the
  appliance is internet-facing, and the fleet's config inventory does not
  belong on the box with the largest attack surface. The Config repo lives
  on a LAN git host (bare repo over authorized-key SSH) — outside this
  document's appliance scope. The appliance therefore
  grows **no** git route.

## New: required for the Determinate tree, regardless of routing shape

- **`install.determinate.systems`** — the `determinate-nixd` binary blobs,
  fetched as flake `file` inputs:
  `https://install.determinate.systems/determinate-nixd/tag/v3.21.9/<arch>`.
  Only the fleet's architectures are needed (e.g. `x86_64-linux`); route the path generically so
  a version bump doesn't need appliance edits. Proposed route prefix (what
  the first Config repo's flake already assumes — adjust both together if a
  different prefix is picked):
  `<cache-url>/install-determinate/<path>` →
  `https://install.determinate.systems/<path>`.
- **`releases.nixos.org`** — Determinate's `nix` builds against a nixexprs
  tarball pin, e.g.
  `https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1043539.9bc02893134c/nixexprs.tar.xz`.
  Serves directly (no redirect chasing expected).
- **github route allowlist add: `edolstra/flake-compat`** — the one github
  input in the tree outside the current allowlist. (`NixOS/nixpkgs` entries
  are already allowed.)

## Revised 2026-08-11 (later same day): FlakeHub path routes for top-level inputs (ADR 0006)

Top-level Config-repo inputs are FlakeHub *range* URLs, path-routed:

- **`/flakehub/<path>` → `https://flakehub.com/<path>`** and
  **`/flakehub-api/<path>` → `https://api.flakehub.com/<path>`**. The
  appliance must rewrite the `Location` **and** `Link` (`rel="immutable"`)
  response headers back through itself (`api.flakehub.com/...` →
  `<cache-url>/flakehub-api/...`): the Link header is how Nix locks a range
  to a pinned URL, so an unrewritten header locks an unreachable URL.
  Verify against the real chain: range GET → pinned redirect → object
  storage (the final CDN hop may be served or followed server-side —
  confirm which the tarball fetcher tolerates).
- **`/install-determinate/` doubles as a substituter mirror**: the Config
  repo declares `<cache-url>/install-determinate/` in
  `nix.settings.substituters`, so beyond the nixd blobs the route must
  pass `/nix-cache-info`, `*.narinfo`, and `nar/*` GETs through to
  `install.determinate.systems`. Verify its narinfo signatures match the
  `cache.flakehub.com-*` keys the Determinate daemon already trusts.
- The daemon-managed nix.conf keeps `https://install.determinate.systems/`
  as a literal extra substituter that no NixOS option can remove; it is
  harmless only if LAN DNS returns NXDOMAIN for external names (fail-fast,
  not blackhole) — verify.

## Noted 2026-08-13: Determinate ≥ 3.18 links sentry-native (crash telemetry)

As of Determinate Nix 3.18, `getsentry/sentry-native` joins the closure of
Determinate's `nix` (crash reporting). Consequence for the appliance: the
**full** closure — sentry-native's store paths included — must substitute
through the `/install-determinate/` mirror route (or arrive via Pin match
from the live installer's store). A client that cannot substitute those
paths falls back to *building* sentry-native, and its fixed-output source
fetch (`github.com/getsentry/…`) is exactly the class of URL the appliance
blocks — and no `/github/` allowlist entry can help, because the URL sits
inside a derivation, not a flake input the client could re-route.

Two misreads to avoid: `DETSYS_IDS_TELEMETRY=disabled` (baked into the
determinate installers as repo policy) is a **runtime** opt-out and changes
nothing about this closure; and the failure mode surfaces on *builds behind
the appliance* (ISO builds, rebuilds at a bumped pin), not only on installs.

The section below remains authoritative for the **transitive Determinate
tree** (explicit-rev codeload pins; ADR 0004).

## Decided 2026-08-11: FlakeHub tarballs route via Shape B (github codeload)

Six inputs lock as `api.flakehub.com/f/pinned/...` tarballs: `determinate`
itself, `nix` (DeterminateSystems/nix-src), `nixpkgs` (NixOS 0.2511),
`nixpkgs-weekly`, `flake-parts` (hercules-ci), `git-hooks.nix` (cachix). All
six repos exist on GitHub, so the Config-repo template overrides them to
`tarball+http://<cache-url>/github/<owner>/<repo>/tar.gz/<rev>` through the
existing codeload route. Appliance work is allowlist adds only:
`DeterminateSystems/determinate`, `DeterminateSystems/nix-src` (the GitHub
repo behind FlakeHub's `nix` project — the first Config-repo lock verifies
the name via narHash), `hercules-ci/flake-parts`, `cachix/git-hooks.nix`
(`NixOS/nixpkgs` already allowed, which also covers `nixpkgs-weekly`: its
revs are plain NixOS/nixpkgs commits republished on FlakeHub, so it needs
no entry of its own — the Config repo's narHash pins prove the mapping).

Explicit-rev pins lose FlakeHub's semver ranges — accepted deliberately: Pin
match already demands the Config repo track the ISO's exact `determinate`
rev, so a range that floats past it is drift the installer warns about, not
a convenience. Determinate updates are deliberate fleet events (new ISO +
template rev bump together).

The rejected alternative (**Shape A** — front `flakehub.com` +
`api.flakehub.com`, `proxy_redirect`-rewriting each Location back through
the appliance so semver-range locking keeps working) required unverified
redirect engineering to preserve a range-tracking property this fleet
treats as a bug. See ADR 0004.

## Future (optional): a curated LAN flake registry

A pass-through proxy of `channels.nixos.org` buys nothing: clients hardcode
the https URL (path routes can't intercept it), and the stock registry's
payload points at `github:` refs the filtered network blocks anyway — it
only moves the failure one hop. The fleet's committed-config flows are
registry-free by design; verification tooling sets
`--option flake-registry ''` client-side. If interactive bare flakerefs
(`nix run nixpkgs#hello`) are ever wanted on-LAN, the working shape is: the
appliance serves a curated `flake-registry.json` mapping `nixpkgs` etc. to
appliance-addressed tarball URLs the existing routes already serve, and the
fleet config points `flake-registry` at it. WARNING for that day:
`flake-registry` is a flakes-gated nix.conf setting — setting it via
`nix.settings` without `experimental-features` in the same generated file
re-creates the nix.conf-validation install failure from the graphical
branch (generated files list keys alphabetically; `e` < `f` saves you, but
only if both are set).

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
- One end-to-end build at a ≥ 3.18 determinate pin that *substitutes*
  sentry-native through `/install-determinate/` (route-level checks —
  `/nix-cache-info`, signed narinfos — do not prove the closure is
  complete; a from-source fallback on sentry-native means it is not).
