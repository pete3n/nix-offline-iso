# Context Map

Repo-wide language and the map of this repo's bounded contexts
([ADR 0008](./docs/adr/0008-single-main-variant-matrix.md)).

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

**Builder prefill**:
A value the ISO builder supplies at build time that changes only what an
installer prefills or displays — never anything that bypasses an operator
confirmation or probe, and never the Target except as the operator's
probed, confirmed choice. The repo's tracked defaults are the fallback
when the builder supplies nothing; the repo itself stays fleet-generic
either way. Builder-supplied *routes* (rerouting where an input is fetched
from) sit under the same rule only while the fetched content stays pinned
to what the lock records — an unpinned reroute changes which bytes, not
just where from, and is outside this term.
_Avoid_: build option/build setting (too broad — most build settings are
not prefills and do not get this exemption), baked config (the offline
contract's word for a different thing).

## Contexts

- [Offline contract](./docs/offline/CONTEXT.md) — zero-network installs;
  everything the Target needs is baked into the ISO. Products:
  `nixos-cli-offline`, `nixos-graphical-offline`, `determinate-cli-offline`.
- [Proxied contract](./docs/proxied/CONTEXT.md) — installs whose only egress
  is the Cache proxy + LAN; the ISO bakes nothing and owns no URLs. Products:
  `determinate-cli-proxied`, `nixos-graphical-proxied`.

## Relationships

- The two contracts share installer machinery (`cli/`, `calamares/`, the ISO
  module) and the harness suite (`tools/`), but never a glossary: the same
  word can mean opposite things across them (**Determinate Nix** is
  hard-neutered in the offline contract, as-shipped in the proxied one).
- Fleet-internal decisions (which LAN, whose keys, which hosts) are out of
  scope for this public repo entirely: recorded in the fleet's private repo;
  ADR numbers 0005/0006 are reserved for them and never reused here.
