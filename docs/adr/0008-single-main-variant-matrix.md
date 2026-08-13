# One public `main`: the variant matrix becomes directories

> Written 2026-08-12 on `nixos-26.05-cli-determinate` (the trunk-to-be),
> before the restructure it decides — it rides into `main` with the flatten.
> Numbering note: 0002–0006 exist on sibling branches (the family sequence
> was always global in intent); 0007 is reserved for this branch's
> `0001-determinate-nix-offline.md`, renumbered during the flatten to
> resolve the collision with the stock branches' `0001-offline-rebuild-deps.md`.

This repo ships five NixOS installer ISOs as five long-lived, release-named
branches (`nixos-26.05-cli`, `-graphical`, `-cli-determinate`,
`-cli-determinate-proxy`, `-graphical-proxy`), hosted publicly for community
re-use. Both ecosystems — plain NixOS and Determinate — are maintained
products. The branch scheme taxes every change: a shared installer fix is N
hand-replicated commits (the disko `--disk` safety fix exists as twin commits
`b06d40c`/`07e9640`; the stock branches *still* lack it), harness work
strands on one branch, docs and ADR numbering forked (two different ADRs
both numbered 0001), one branch re-broke a fix a sibling had already landed,
and the next NixOS release would double the zoo.

**Decision: flatten to a single public `main` where the products are
directories, and retire product branches entirely.**

- **Products** are cells of a three-axis matrix, named
  `<ecosystem>-<interface>-<contract>` (axes and glossary: `CONTEXT-MAP.md`):
  `nixos-cli-offline`, `nixos-graphical-offline`, `determinate-cli-offline`,
  `determinate-cli-proxied`, `nixos-graphical-proxied`. Shared machinery
  (`cli/`, `calamares/`, the ISO module, `tools/` harnesses) is imported by
  relative path; per-product wiring lives under `variants/<product>/`.
- **One root builder flake**, one lock, one shared builder `nixpkgs` pin,
  five `installer-iso-<product>` outputs. Each *offline* product keeps its
  example target as a path-input subflake (`variants/<product>/configs/flake`)
  with its own committed lock — the `pinNode` bake machinery reads the lock
  from the **target-flake input's source** (not a hardcoded repo path), so
  production ISOs are built against private target flakes with
  `--override-input target-flake-<product> path:/…` and the public tree is
  never edited. *Proxied* products ship no `configs/` at all — bakes-nothing
  (ADR 0003) is structural, not conventional.
- **Docs**: `CONTEXT-MAP.md` at the root (repo-wide product-matrix language);
  per-contract glossaries `docs/offline/CONTEXT.md` and
  `docs/proxied/CONTEXT.md` — the contracts are opposing doctrines whose
  terms deliberately conflict (offline hard-neuters Determinate Nix; proxied
  runs it as-shipped) and are never merged. ADRs stay in this one flat dir
  with the family-global numbering preserved; only the colliding
  `0001-determinate-nix-offline` is renumbered (→ 0007), and the index
  README carries the former-number table. Numbers 0005/0006 are **reserved,
  fleet-internal**: those decisions are recorded in the fleet's private
  repo, never here — `.gitignore` carries a `docs/fleet/` / `**/fleet-*`
  tripwire so working notes cannot be committed by accident.
- **Migration**: build `main` from the branches' *origin* states (verified
  free of internal material), restructure, then reapply the unpushed deltas
  as fresh commits minus the fleet documents (only never-published commits
  are rewritten). Where branches diverged on shared code, the Determinate
  line wins (it is newest) gated by the harnesses proving the nixos products
  still pass. Nothing pushes until: all five outputs build, per-variant
  harnesses are green, the determinate products' closures evaluate
  **identical** to their branch builds (the flatten must not change their
  content), and one real VM install passes per *contract*. Then: push
  `main`, push the clean branch tips, freeze every product branch with a
  pointer commit ("flattened into `main` as `<product>` at `v26.05`"),
  flip the GitHub default branch.
- **Versioning**: `main` tracks the current stable NixOS release; annotated
  tags (`v26.05`, then `v26.05.N` checkpoints) are the citable states.
  Release bumps are atomic across the whole matrix. A `release/<ver>`
  maintenance branch is cut from the last tag **only when a real backport
  need appears** — never pre-emptively.
- The repo keeps its name: offline is the flagship contract and the name is
  the established public identity; GitHub renames redirect, so this stays
  cheap to revisit.

## Considered options

- **Two ecosystem branches (`nixos-community` / `determinate`), variants as
  directories inside each.** Rejected: most real fixes this month were
  cross-ecosystem (installer safety, harnesses, docs), so every one would
  still be two commits — it renames the tax and institutionalizes the stock
  lag it was meant to fix. The naming also collides: `nix-community` is the
  nix-community GitHub org/cachix, a different load-bearing name in this
  ecosystem's own allowlists.
- **Variants as branches, release dropped from names.** Rejected: same tax,
  smaller sticker.
- **Builder flake per variant directory.** Rejected: five locks to bump per
  release re-creates branch drift inside one branch. The union root lock's
  cost (whole-flake ops touch every ecosystem's inputs) falls only on the
  networked build machine; laziness keeps per-output builds clean.
- **Fleet docs kept in-tree, gitignored.** Rejected: gitignore neither
  untracks committed blobs nor protects history, and untracked files have no
  history, no backup, and no presence in clones — the wrong properties for
  load-bearing decision records. They live tracked in the fleet's private
  repo instead; the tripwire here is a guard, not the record.
- **Pre-emptive `release/26.05` branch.** Rejected: maintenance surface with
  zero demonstrated backport demand; tags serve pinning.
- **Renumbering ADRs into per-context sequences.** Rejected: "ADR 0003–0006"
  is cited by name in three sibling repos; citation stability beats a pretty
  timeline. One file renumbered, one redirects table.

## Consequences

- A shared fix is one commit, one diff, one review, gated by every
  product's harness in one run. The nixos products inherit the Determinate
  line's accumulated safety fixes at flatten time.
- `git blame` lineage breaks at the restructure boundary; deep history lives
  in the frozen branches, which remain browsable on GitHub.
- Sibling repos must repoint citations that name branches or the renumbered
  ADR (nix-nginx-proxy's ADRs, workstation-config's README, session
  memories): branch names → product names, "ADR 0001 finding #6" → 0007,
  fleet ADR references → the private repo.
- The separate build-tree clone stops carrying private-config edits: with
  `--override-input`, private target flakes (e.g. the appliance's own repo)
  are injected at build time and the clone stays pristine — the standing
  jail-vs-build-tree drift hazard reduces to `git pull`.
- Release bumps cannot be staggered per product without cutting a
  maintenance branch; that is deliberate.
