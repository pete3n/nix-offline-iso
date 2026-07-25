# NixOS Offline ISO Builder (minimal CLI installer)

Build offline ISO images of a **minimal, console-based** NixOS installer that
include a user-provided system configuration that can be installed with **no
network connection**, by including all of its dependencies in the ISO's Nix
store.

This is the CLI variant — there is no graphical installer; you install from a
console with the `offline-install` script. (The graphical Calamares variant
lives on the `nixos-26.05-graphical` branch.)

Targets **NixOS 26.05**. Two install types are supported:

- **channels** — a plain `configuration.nix` (tracks a NixOS channel, no flake)
- **flake** — a `flake.nix` (installed offline; see [Flake offline support](#flake-offline-support))

## Usage

1. [Install Nix](https://nixos.org/download) with flakes enabled on an online
   build host with plenty of free disk (see below).
2. Put your system config in either `configs/channels/` or `configs/flake/`.
   Keep the provided `hardware-configuration.nix` template. It is needed to build
   the ISO closure and is overwritten by the real hardware scan at install time.
   If there are significant differences between the target hardware and the
   `hardware-configuration.nix` template, then you may need to replace the template
   config with the generated one so that the ISO includes necessary dependencies.
3. For a flake target, the `nixosConfigurations.<name>` attribute must match the
   installer hostname (default `nixos`) or the `--host NAME` you pass to
   `offline-install`.
4. Build:

```
# channels target
nix build .#iso.channels-x86_64-linux

# flake target
nix build .#iso.flake-x86_64-linux
```

5. Write the ISO to disk with `dd` or an equivalent tool.
6. Boot the target. At the console:
   - Partition and mount your target at `/mnt` yourself, **or** let the installer
     do a single disk: `offline-install --disk /dev/sdX` (GPT: 1024 MiB ESP + ext4
     root — **erases the disk**).
   - Run `sudo offline-install`.
   - For a **flake** target, pass `--host NAME` if your
     `nixosConfigurations.<name>` isn't the default `nixos`.

   The install may appear to sit for a long time while it builds and copies from
   the store — that is expected.

## How it works

The installer is the stock NixOS **minimal** (console) image
(`installation-cd-minimal`). There is no Calamares; the ISO simply ships the
`offline-install` script (`cli/offline-install.sh`) and a login hint. When you
run it, the script:

1. Runs `nixos-generate-config --root /mnt` and preserves the freshly generated
   `hardware-configuration.nix`.
2. Copies your files from `/tmp/nix-cfg` or `/iso/nix-cfg` into
   `/mnt/etc/nixos`, then restores the generated `hardware-configuration.nix`.
   Your config owns users and passwords (see
   [Users and passwords](#users-and-passwords)).
3. Builds the system **in the live installer store** — channels via
   `nix-build '<nixpkgs/nixos>'`, flake via `nix build …#…toplevel` — and installs
   the finished path with `nixos-install --system`, which just copies the closure
   to the target. Building in the live store (not the empty target store) is what
   lets the install succeed offline.

The installer is also configured to run nix **fully offline** during install
(`nix.settings.substituters = [ ]` and `flake-registry = ""`). Without this, nix
reaches out to `cache.nixos.org` (binary-cache probe) and `channels.nixos.org`
(global flake registry) and fails with no network. Because
`nixos-generate-config` regenerates `hardware-configuration.nix` for the target
machine at install time, the installed system differs slightly from what was
pre-built, so a small rebuild must be performed. The ISO bakes the target's
**build/derivation closure** so that the rebuild runs offline from sources
already in the store.

## Layout

```
flake.nix                     ISO builder (minimal installer + offline logic)
cli/offline-install.sh        console installer script (shipped on the ISO)
configs/
  channels/                   example channels target (configuration.nix)
  flake/                      example flake target (flake.nix + configuration.nix)
```

### Users and passwords

The provided `configuration.nix` sets users and their passwords.
**Set a password in your config** (e.g. `users.users.<name>.initialPassword`,
`hashedPassword`, or `hashedPasswordFile`, and for `root` if you want root
login). The example configs use `initialPassword = "test"` for `root` and
`tester`. You can log in as `tester` / `test`.

### Dynamic configuration

You can customize a configuration at install time by placing it in `/tmp/nix-cfg`.
The installer prefers it over the baked-in `/iso/nix-cfg`, so you can edit the
config after booting the live environment. Remember though, you can safely remove
items from a configuration, but if your edits add dependencies that aren't in the
ISO store, the offline install will fail.

## Flake offline support

Offline flake installs require several workarounds (see
[nix#8953](https://github.com/NixOS/nix/issues/8953)):

1. **Evaluate offline** by pinning `nixpkgs` to a store path. At ISO-build time
   the builder bakes a *copy* of your flake whose `nixpkgs` input is rewritten to
   `path:/nix/store/…-source` (the nixpkgs already in the ISO store), together
   with a matching, complete `flake.lock`. A `path:` input with a complete lock
   needs no registry and no network.

2. **Build offline** in the live installer store, then pass the finished path to
   `nixos-install --system`, which just copies the closure to the target. The
   installer hostname (or `--host`) must match a `nixosConfigurations.<name>`
   attribute in the flake.

3. **Bake the inputs** into the closure. The ISO store carries the target
   system's built closure, its derivation closure (`.drv`s + source tarballs, for
   the hardware-config rebuild), and the nixpkgs source.

Do **not** commit a `configs/flake/flake.lock`; the builder generates the
path-pinned lock for the ISO copy. The repo `flake.nix` uses an indirect
`nixpkgs` so it still resolves normally on a networked machine.

**After install**, the target's `/etc/nixos/flake.nix` carries the store-path
`nixpkgs` ref. For online rebuilds later, repoint it to a channel, e.g.
`nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";`, then `nix flake update`.

### Free disk space

The ISO is large (depending on the config) — though smaller than the graphical
variant since there is no desktop. Keep ~3× the ISO size free on the build
host's Nix store partition.
