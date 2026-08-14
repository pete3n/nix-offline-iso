# nix-offline-iso

NixOS installer ISOs for networks that aren't normal: fully **offline**
installs that carry every dependency in the ISO's store, and **proxied**
installs whose only route to the internet is a filtering LAN cache appliance.
Each comes in a plain-NixOS flavor and a
[Determinate Nix](https://determinate.systems) flavor.

## Products

One repo, one `main`, five installer products
(`<ecosystem>-<interface>-<contract>` — see [`CONTEXT-MAP.md`](./CONTEXT-MAP.md)):

| Product | Nix | Front end | Network contract |
|---|---|---|---|
| `nixos-cli-offline` | upstream | console script | offline — zero network attempts |
| `nixos-graphical-offline` | upstream | Calamares | offline — zero network attempts |
| `determinate-cli-offline` | Determinate | console script | offline — zero network attempts |
| `determinate-cli-proxied` | Determinate | console script | everything via a LAN cache proxy |
| `nixos-graphical-proxied` | upstream | Calamares | everything via a LAN cache proxy |

Build an ISO (per-product usage lives in `variants/<product>/README.md`):

```
nix build .#installer-iso-<product>          # e.g. installer-iso-determinate-cli-offline
nix build .#installer-iso-nixos-cli-offline-channels    # channels-target shape (nixos-*-offline only)
```

To bake your own defaults (the proxied products' Cache URL prefill) or
reroute input fetches for builds behind a cache proxy, copy `.env.example`
to `.env` and build through `tools/build-iso.sh <product>` instead — see
[ADR 0009](./docs/adr/0009-builder-env-prefills-and-route-overrides.md).
A plain `nix build` ignores `.env` and builds the tracked defaults.

## The two contracts

- **Offline** ([glossary](./docs/offline/CONTEXT.md)): the ISO bakes a
  *target configuration* — its built closure, its derivation closure, and
  every flake input's source, with the lock repinned to store paths — so the
  install (and later on-target rebuilds of config edits) make zero network
  attempts by construction. The offline products embed an example target
  under `variants/<product>/configs/`; bring your own by replacing it, or
  build with `--override-input target-<product> path:/your/flake` without
  touching this tree.
- **Proxied** ([glossary](./docs/proxied/CONTEXT.md)): the ISO bakes
  *nothing* and owns no URLs (ADR 0003). The target configuration is cloned
  from your LAN git host at install time, and every fetch rides a LAN cache
  appliance (an nginx reverse proxy fronting cache.nixos.org and allow-listed
  source routes — requirements in
  [`docs/proxied/appliance-requirements.md`](./docs/proxied/appliance-requirements.md)).

Why it's built this way: [`docs/adr/`](./docs/adr/README.md). Start with
[ADR 0008](./docs/adr/0008-single-main-variant-matrix.md) for the repo's
shape, [ADR 0007](./docs/adr/0007-determinate-nix-offline.md) for
Determinate-offline, [ADR 0003](./docs/adr/0003-proxied-cli-bakes-nothing.md)
for the proxied contract.

## Layout

```
flake.nix               # one builder flake: five installer-iso-* outputs
nix/lib.nix             # machinery shared across products (bake logic, modules)
cli/                    # console installers (offline-install, proxied-install, proxy-setup)
calamares/              # graphical machinery (overlay config files, proxy screen, injects)
variants/<product>/     # per-product wiring (iso.nix), README, example configs (offline only)
tools/                  # offline-capable regression harnesses — run before burning an ISO
docs/                   # ADRs + per-contract glossaries
```

## Testing

Every harness in `tools/` runs in seconds without building an ISO:
`test-offline-install-args.sh` (installer arg safety against destructive-tool
stubs), `test-offline-rebuild.sh <variant-configs>` (the offline-rebuild
contract), `test-overlay.sh` / `test-proxy-screen.sh` (Calamares proxy
machinery), `test-proxied-install.sh`. Run the relevant ones before spending
an ISO+VM cycle.

## Versioning

`main` tracks the current stable NixOS release; annotated tags (`v26.05`,
`v26.05.1`, …) mark citable states. Release bumps move the whole product
matrix at once; maintenance branches for old releases are cut from the last
tag only on demand. The historical per-product branches (`nixos-26.05-*`)
are frozen — their content lives on here.

## License

See [LICENSE](./LICENSE).
