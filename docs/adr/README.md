# Decision records

One flat, family-global sequence. The numbering predates the single-`main`
flatten (ADR 0008): ADRs were written across the old product branches with a
shared sequence in mind, and the flatten preserved every number that had ever
been cited rather than renumbering for a pretty timeline. Dates below are the
decision dates, so the sequence is not chronological.

| # | Title | Governs | Date |
|---|-------|---------|------|
| [0001](./0001-offline-rebuild-deps.md) | Offline-rebuild dependency anchoring | offline contract (all offline products) | 2026-08-01 |
| [0002](./0002-pre-calamares-proxy-dialog.md) | Pre-Calamares proxy dialog | `nixos-graphical-proxied` | 2026-08-01 |
| [0003](./0003-proxied-cli-bakes-nothing.md) | The proxied CLI bakes nothing and owns no URLs | proxied contract | 2026-08-11 |
| [0004](./0004-flakehub-inputs-route-via-codeload-shape-b.md) | FlakeHub inputs route via the codeload shape | `determinate-cli-proxied` | 2026-08-11 |
| 0005 | *(reserved — fleet-internal, recorded in the fleet's private repo)* | — | 2026-08-11 |
| 0006 | *(reserved — fleet-internal, recorded in the fleet's private repo)* | — | 2026-08-11 |
| [0007](./0007-determinate-nix-offline.md) | Determinate Nix, offline | `determinate-cli-offline` | 2026-08-01 |
| [0008](./0008-single-main-variant-matrix.md) | One public `main`: the variant matrix becomes directories | repo-wide | 2026-08-12 |
| [0009](./0009-builder-env-prefills-and-route-overrides.md) | Builder env: `.env` prefills and input-route overrides | repo-wide | 2026-08-13 |
| [0010](./0010-flake-ref-install.md) | Flake-ref install: build the Target straight from the bare Config repo | `determinate-cli-proxied` | 2026-08-13 |

Former numbers: **0007 was "ADR 0001" on the old `nixos-26.05-cli-determinate`
branch** — it collided with 0001-offline-rebuild-deps (the stock lineage's
0001) when the branches flattened. Citations of "ADR 0001 finding #6" mean
0007. Numbers 0005/0006 are never reused: they belong to fleet-internal
decisions whose record lives outside this public repo, and external
references to them stay unambiguous this way.
