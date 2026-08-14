# nix-offline-iso

This repo provides [NixOS](https://nixos.org) ISO builders for offline and proxied networks.
The offline installation ISOs save every dependency in the ISO's store, and 
proxied installs source flake inputs through a reverse-proxy / Nix binary cache 
server. Each installer variant comes with a NixOS community version and a
[Determinate Nix](https://determinate.systems) version.

## Installers


| Variant | Nix | Installer Interface | Network |
|---|---|---|---|
| `nixos-cli-offline` | Nixos.org | CLI + script | Completely offline |
| `nixos-graphical-offline` | Nixos.org | Gnome + Calamares | Completely offline |
| `nixos-graphical-proxied` | Nixos.org | Gnome + Calamares | Reverse-proxy |
| `determinate-cli-offline` | Determinate | CLI + script | Completely offline |
| `determinate-cli-proxied` | Determinate | CLI + script | Reverse-proxy |

Build an ISO (per-variant usage located in `variants/<variant>/README.md`):

```
nix build .#installer-iso-<variant>          # e.g. installer-iso-determinate-cli-offline
nix build .#installer-iso-nixos-cli-offline-channels    # channels-target shape (nixos-*-offline only)
```

To cross-build for aarch64/x86_64 specify the output arch in the build command:

```
nix build .#packages.aarch-64-linux.installer-iso-nixos-cli-offline
```


## Offline vs. Proxy Installers

- **Offline**: the ISO bakes its derivation closure, and every flake input's 
  source, with the lock repinned to store paths so the install 
  (and later rebuilds for configuration edits on the installed system) 
  can be performed on an air-gapped system. The offline variants provide an 
  example target configuraiton under `variants/<variant>/configs/`; 
  replace it with your own configuration, or build with
  `--override-input target-<variant> path:/your/flake` for example:

  ```
  nix build .#installer-iso-determinate-cli-offline \
  --override-input target-determinate-cli-offline path:/path/to/your/flake
  ```

  The target configuration path can be either relative or absolute.

- **Proxied**: the ISO bakes nothing and owns no URLs. The target configuration 
  is intended to be provided at install time. This method was specifically designed
  to utilized a [private cache proxy](https://nixos.wiki/wiki/FAQ/Private_Cache_Proxy). 
  The URL to this proxy can be configured in the installer.

  - **Environment**: The proxied ISOs support reading from a .env file in the
    project root that can pass env vars to the installer. Currently it only supports
    setting the default proxy URL with:
    ```
    ISO_CACHE_URL=http://nix-cache.url.lan
    ```
    and
    ```
    ISO_INPUT_OVERRIDES=
    ```

    A plain `nix build` ignores `.env` and builds the tracked defaults.

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
`test-proxied-install.sh`. 

## Versioning

`main` tracks the current stable NixOS release. Previous versions will be left
available but unmaintained in version-specific branches (e.g. nixos-26.05).

## License

See [LICENSE](./LICENSE).
