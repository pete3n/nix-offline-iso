# Builder env: `.env` prefills and input-route overrides

A gitignored `.env` at the repo root lets an ISO builder bake fleet-specific
values into a *locally built* ISO without touching tracked code: v1 carries
`ISO_CACHE_URL` (the Cache URL the proxied installers prefill) and
`ISO_INPUT_OVERRIDES` (`input=url` pairs turned into `--override-input`, so
a cold build behind the Cache proxy can fetch inputs whose committed lock
URLs are unreachable on a filtered network). `tools/build-iso.sh` sources
the file and builds with `--impure`; every `builtins.getEnv` read lives in
one allow-list in `nix/lib.nix`, and the values reach the CLI scripts as a
baked `/etc/installer-prefills` file (relocatable under the test harness's
`NIX_PROXY_TEST_PREFIX`, like every other runtime file the scripts touch).
A plain `nix build .#installer-iso-<product>` stays pure and builds the
tracked defaults.

The governing rule is the **Builder prefill** definition in
`CONTEXT-MAP.md`: a builder-supplied value may change only what an
installer *prefills or displays*, and where input bytes are *fetched from*
— never a gate (the Reachability probe, the disko and Pin-match
confirmations), and never the Target, except as the operator's probed,
confirmed choice (the graphical product persists the confirmed Cache URL
into the generated config by design, ADR 0002 — the confirmation carries
the value there, not the bake). This deliberately amends one sentence of
[ADR 0003](./0003-proxied-cli-bakes-nothing.md)'s consequences: **the
*repo* is fleet-generic; a *built ISO* may carry builder-supplied
prefills.** Everything ADR 0003 actually argued for — the installer never
rewrites or injects anything into what it installs; installed == evaluated
== committed — is untouched: a prefill was already on the ISO
(`DEFAULT_URL` in `proxy-setup`) when ADR 0003 was written, and the
operator still confirms or replaces it behind the probe.

## Considered options

- **Runtime sourcing** (the booted installer reads an env file from
  removable media): keeps the ISO fully generic, but adds an operator step
  to every install and cannot feed eval-time values (the graphical
  product's `cacheUrlDefault`, MOTD text). Rejected.
- **`path:` flake builds** so pure eval sees the untracked `.env`:
  rejected hard — `path:` copies the *entire working tree* into the
  world-readable store, including `result/` junk and any `docs/fleet/`
  notes the `.gitignore` tripwire exists to keep out of public artifacts.
- **A non-flake `build-env` input overridden per build**: pure and
  explicit, but the UX is the opposite of a drop-in `.env` — an absolute
  `--override-input` path on every build. Rejected.
- **Unprefixed variable names** (`CACHE_URL`): under `--impure`,
  `getEnv` sees the builder's whole ambient environment, so a stray
  same-named variable would silently bake into the ISO. The `ISO_` prefix
  makes that near-impossible. Rejected.
- **Feeding credentials through `.env`** (SSH key/cert for the Config
  repo): the paradigm case of not-a-prefill. The Provisioning key glossary
  entry already forbids credentials in a mass-copied artifact, and
  anything baked via the flake transits the world-readable `/nix/store`.
  Identity material stays on the installing admin's own stick, with the
  fleet's driver script (recorded in the fleet's private repo, never
  here). Rejected — see also ADR 0010.

## Consequences

- Builders who want prefills must build through `tools/build-iso.sh` (or
  pass `--impure` themselves); CI and contributors keep pure, reproducible
  default builds.
- An ISO built with a `.env` is a fleet-flavored artifact. Its prefills
  are not secrets (URLs a LAN client would learn anyway), but the artifact
  is no longer the repo's generic ISO and should not be redistributed as
  such. `/etc/installer-prefills` on the live ISO shows exactly what was
  baked.
- `ISO_INPUT_OVERRIDES` is only route-not-content when the override URL
  itself carries `?narHash=<the lock's hash>`: `--override-input` REPLACES
  the input's lock entry, so an unpinned override takes whatever the route
  serves. `tools/build-iso.sh` warns on any unpinned override, and
  `.env.example` shows the pinned form — with it, a LAN-routed build is
  bit-for-bit what a direct-internet build would produce.
- Every future `.env` variable must pass the Builder-prefill test before
  it is added; anything that fails the test is either tracked repo policy
  (e.g. the proxied products disabling Determinate crash telemetry) or
  does not belong in the build at all (credentials).
