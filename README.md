# nix-offline-iso

This repo provides [NixOS](https://nixos.org) ISO builders for offline and proxied networks.
The offline installation ISOs save every dependency in the ISO's store, and 
proxied installs source flake inputs through a reverse-proxy / Nix binary cache 
server. Each installer variant comes with a NixOS community version and a
[Determinate Nix](https://determinate.systems) version.

## Installers


| Variant | Nix | Installer Interface | Network |
|---|---|---|---|
| nixos-cli-offline | Nixos.org | CLI + script | Completely offline |
| nixos-graphical-offline | Nixos.org | Gnome + Calamares | Completely offline |
| nixos-graphical-proxied | Nixos.org | Gnome + Calamares | Reverse-proxy |
| determinate-cli-offline | Determinate | CLI + script | Completely offline |
| determinate-cli-proxied | Determinate | CLI + script | Reverse-proxy |

## Intent

Pick an installer by what the network can reach at install time:

- **`determinate-cli-offline`**: for the infrastructure the rest of a
  network depends on, such as its cache proxy, its forge or its identity
  server. These hosts must install and reinstall while the network is down,
  so the ISO carries everything the install needs. Build it on any machine
  that can fetch the target's inputs: an internet-connected builder outside
  the network if the network is gone, or a builder inside it through its
  proxy. It bakes no derivation closure, so its targets commit their
  hardware configuration and carry their own rebuild tools (see its
  README).
- **`determinate-cli-proxied`**: for every other host, once a cache proxy
  exists. The ISO bakes nothing; the install fetches through the proxy, so
  the ISO stays small and can be built from inside the network.
- **`nixos-*`**: general-purpose installers on community NixOS, offline and
  proxied, CLI and graphical. They are maintained alongside the Determinate
  products for anyone who wants the stock ecosystem or a graphical
  installer.


## Usage
Either run the provide builder script from `./tools/build-iso.sh` or use nix build
directly to build an ISO: 

```
nix build .#installer-iso-<variant>          # e.g. installer-iso-determinate-cli-offline
nix build .#installer-iso-nixos-cli-offline-channels    # channels-target shape (nixos-*-offline only)
```


Per-variant usage is located in `variants/<variant>/README.md`.
To cross-build for aarch64/x86_64 specify the output arch in the build command:

```
nix build .#packages.aarch-64-linux.installer-iso-nixos-cli-offline
```

## Offline vs. Proxy Installers

- **Offline**: the offline installer ISOs bake their derivation closure, and every 
  flake input's source, with the lock repinned to store paths so the install 
  (and later rebuilds for configuration edits on the installed system) 
  can be performed on an air-gapped system. (`determinate-cli-offline` is the
  exception: it bakes no derivation closure, so its targets must commit their
  hardware config and carry their own rebuild tools; see its README.)
  The offline variants provide an 
  example target configuration under `variants/<variant>/configs/`; 
  replace it with your own configuration, or build with
  `--override-input target-<variant> path:/your/flake` for example:

  ```
  nix build .#installer-iso-determinate-cli-offline \
  --override-input target-determinate-cli-offline path:/path/to/your/flake
  ```

  The target configuration path can be either relative or absolute.

  A target can also be a flake in a subdirectory of a larger repository,
  for example one that reaches shared modules through a relative path input
  (`path:../../lib`). Point the override at the repository with `?dir=`:

  ```
  nix build .#installer-iso-determinate-cli-offline \
  --override-input target-determinate-cli-offline 'path:/path/to/repo?dir=hosts/myhost'
  ```

  The ISO then carries the whole repository, and `offline-install` builds
  from that subdirectory (recorded in the baked config's `.flake-dir`, or
  given with `--flake-dir`). Relative inputs stay as they are in the lock;
  they resolve inside the copied repository. Overriding with
  `path:/path/to/repo/hosts/myhost` instead copies only that directory, and
  a relative input pointing outside it fails.

  Subdirectory targets are supported by the CLI installer (`offline-install`)
  only; the graphical installer still expects `flake.nix` at the top of the
  baked config.

- **Proxied**: the ISO bakes nothing and owns no URLs. The target configuration 
  is intended to be provided at install time. This method was specifically designed
  to utilized a [private cache proxy](https://nixos.wiki/wiki/FAQ/Private_Cache_Proxy). 
  The URL to this proxy can be configured in the installer.

  - **Environment**: The proxied ISOs support reading from a .env file in the
    project root that can pass env vars to the installer. This file currently
    supports setting the default proxy URL with:
    ```
    ISO_CACHE_URL=http://nix-cache.url.lan
    ```
    and re-pinning inputs in the target flake with the proxy URL:
    ```
    ISO_INPUT_OVERRIDES="determinate=tarball+http://my-nix-cache.lan/flakehub-api/f/pinned/DeterminateSystems/determinate/3.22.0/019fdd2b-320e-7cf1-8321-a350e90231d9/source.tar.gz?narHash=sha256-KV12%2BFdIAecrnrS97IYhDUUotvnwYMrB%2BbXirUMPOdA%3D&rev=c5a93225f633faee482cbd0670e5d6dca0edf9de&revCount=431&lastModified=1786121778"
    ```

    Each override replaces the input's lock entry, so carry its whole
    identity from your `flake.lock`: `narHash`, plus `rev`, `revCount` and
    `lastModified` (see `.env.example` for why). Overriding a top-level input
    does not reroute its own inputs; a build that must fetch nothing upstream
    needs one override per input path (`determinate/nix`, …).

    The .env file is automatically ingested by the `./tools/build-iso.sh` script
    and passes them to the ISO build process by building with the --impure flag.

    A plain `nix build` ignores `.env` and builds with default values.

## Layout

```
flake.nix               # provides five installer-iso-* outputs
nix/lib.nix             # shared build library (bake logic, modules)
cli/                    # console installers (offline-install, proxied-install, proxy-setup)
calamares/              # calamares mods (overlay config files, proxy screen, injects)
variants/<variant>/     # per-variant config (iso.nix), README, example configs (offline only)
tools/                  # test harnesses to validate before building an ISO
```

## Testing

Every harness in `tools/` runs quickly without building an ISO:
`test-offline-install-args.sh` (installer arg safety for disk partitioning), 
`test-offline-rebuild.sh <variant-configs>` (target config offline rebuild test),
`test-overlay.sh` / `test-proxy-screen.sh` (proxy URL config test), 
`test-proxied-install.sh`, `test-flake-subdir.sh` (what the bake copies to
`/iso/nix-cfg` for default and `?dir=` targets). `test-drv-identity.sh` (needs
network) dry-runs the `determinate-cli-offline` build and fails if it would
compile Determinate Nix from source; run it before building that ISO. 

## Versioning

`main` tracks the current stable NixOS release. Previous versions will be left
available but unmaintained in version-specific branches (e.g. nixos-26.05).

## License

See [LICENSE](./LICENSE).
