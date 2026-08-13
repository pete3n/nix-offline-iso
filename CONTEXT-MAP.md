# Context Map

Repo-wide language and the map of this repo's bounded contexts. Written
2026-08-12 with [ADR 0008](./docs/adr/0008-single-main-variant-matrix.md)
(single-`main` restructure); paths marked *(post-flatten)* arrive with it.

## Language (repo-wide)

**Product**:
One installer ISO this repo ships — a cell of the three-axis matrix below,
named `<ecosystem>-<interface>-<contract>`. The five current Products:
`nixos-cli-offline`, `nixos-graphical-offline`, `determinate-cli-offline`,
`determinate-cli-proxied`, `nixos-graphical-proxied`. All five install NixOS;
the ecosystem axis names which Nix the Installer and Target run.
_Avoid_: branch (products are directories; branches are for development),
variant (older sessions' word for the same thing — Product is canonical).

**Ecosystem** (axis): `nixos` | `determinate`.
`nixos` = Nix as upstream NixOS ships it; `determinate` = Determinate Nix
(patched daemon/binary + `determinate-nixd`).
_Avoid_: upstream, stock (reads as disparagement in public docs), community,
nix-community (that is the nix-community GitHub org / cachix — a different,
load-bearing name in this ecosystem).

**Interface** (axis): `cli` | `graphical`.
The Installer's front end: the `offline-install`/`proxied-install` console
scripts, or Calamares.

**Contract** (axis): `offline` | `proxied`.
The network contract: Offline install (zero network attempts, everything
baked) or Proxied install (egress only via the Cache proxy + LAN; bakes
nothing). These are opposing doctrines, not variations — each keeps its own
glossary and their terms deliberately conflict.

## Contexts

- [Offline contract](./CONTEXT.md) — zero-network installs; everything the
  Target needs is baked into the ISO. *(post-flatten: `docs/offline/CONTEXT.md`,
  merging this file's glossary with the stock branches'.)*
- Proxied contract — installs whose only egress is the Cache proxy + LAN;
  the ISO bakes nothing and owns no URLs. Today on branch
  `nixos-26.05-cli-determinate-proxy` (`CONTEXT.md` there); *(post-flatten:
  `docs/proxied/CONTEXT.md`, merging the cli-proxied and graphical-proxied
  glossaries — their term conflicts, e.g. "Proxy setup" vs "Proxy screen",
  get resolved in that merge.)*

## Relationships

- The two contracts share installer machinery (`cli/`, `calamares/`, the ISO
  module) and the harness suite (`tools/`), but never a glossary: the same
  word can mean opposite things across them (**Determinate Nix** is
  hard-neutered in the offline contract, as-shipped in the proxied one).
- Fleet-internal decisions (which LAN, whose keys, which hosts) are out of
  scope for this public repo entirely: recorded in the fleet's private repo;
  ADR numbers 0005/0006 are reserved for them and never reused here.
