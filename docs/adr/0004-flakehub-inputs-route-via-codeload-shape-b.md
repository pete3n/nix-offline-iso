# FlakeHub-hosted inputs route through the github codeload shape (Shape B)

Status: superseded in part by ADR 0006 (2026-08-11, same day) — top-level
Config-repo inputs use path-routed FlakeHub ranges instead; this ADR
remains authoritative for the transitive Determinate tree's explicit-rev
pins.

The Determinate input tree locks as `api.flakehub.com` tarballs, unreachable
on the filtered network, and `appliance-requirements.md` had deferred how to
route them. Decided (2026-08-11, while authoring the first Config repo): the
Config-repo template overrides all six FlakeHub inputs to
`tarball+http://<cache-url>/github/<owner>/<repo>/tar.gz/<rev>` through the
appliance's existing codeload route — appliance work is four allowlist adds,
no redirect engineering.

## Considered options

- **Shape A — front `flakehub.com`/`api.flakehub.com` with Location-header
  rewriting.** Preserves FlakeHub semver-range tracking, at the cost of
  unverified redirect-chain engineering on the appliance. Rejected because
  range tracking is an anti-feature on this fleet: Pin match requires Config
  repos to hold `determinate` at the ISO's exact rev, so a range that floats
  past it produces the drift warning (and a from-source Nix build), not a
  convenience.

## Consequences

- Determinate updates are deliberate fleet events: build a new ISO and bump
  the template's revs together; `nix flake update` no longer tracks
  Determinate releases on its own.
- Config-repo locks record appliance-addressed URLs — LAN-only portability
  (Shape A had the same property).
- If FlakeHub is ever adopted org-wide (accounts, tokens, edge cache), this
  decision and the FlakeHub Cache exclusion in `appliance-requirements.md`
  should be revisited together.
