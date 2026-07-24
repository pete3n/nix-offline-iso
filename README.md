# NixOS Offline ISO Builder

Build offline ISO images of the NixOS Calamares installer that include a
user-provided system configuration that can be installed with **no network connection**, 
by including all of its dependencies in the ISO's Nix store.

Targets the **NixOS 26.05** `calamares-nixos-extensions`. 
Two install types are supported:

- **channels** — a plain `configuration.nix` (tracks a NixOS channel, no flake)
- **flake** — a `flake.nix` (installed offline; see [Flake offline support](#flake-offline-support))

## How it works

The installer is the stock NixOS graphical Calamares (GNOME) image, with the
`calamares-nixos-extensions` package overlayed by the (`flake.nix`).

The overlay:

1. Ships a modified `calamares/welcome.conf` that drops the `internet`
   requirement check.
2. Injects a config-copy step into the installer's `nixos` module
   (`calamares/inject/config-copy.py`) that copies your files from
   `/tmp/nix-cfg` or `/iso/nix-cfg` into `/etc/nixos`, preserving the
   freshly generated `hardware-configuration.nix`.
3. Removes Calamares' user configuartion. Your config owns users and
   passwords (see [Users and passwords](#users-and-passwords)).
4. For a flake config, builds the system in the live installer store and
   installs the result with `nixos-install --system` (see
   [Flake offline support](#flake-offline-support)).

The installer is also configured to run nix **fully offline** during install
(`nix.settings.substituters = [ ]` and `flake-registry = ""`). Without this,
`nixos-install` reaches out to `cache.nixos.org` (binary-cache probe) and
`channels.nixos.org` (global flake registry) and fails with no network.
Because `nixos-generate-config` regenerates `hardware-configuration.nix` for 
the target machine at install time, the installed system differs slightly 
from what was pre-built, so a small rebuild must be performed. The ISO bakes 
the target's **build/derivation closure** so that the rebuild runs offline 
from sources already in the store.

## Layout

```
flake.nix                     ISO builder + overlay
calamares/
  welcome.conf                replaces upstream's (internet requirement removed)
  inject/config-copy.py       block injected into the installer's nixos module
configs/
  channels/                   example channels target (configuration.nix)
  flake/                      example flake target (flake.nix + configuration.nix)
```

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
   hostname you enter in Calamares (the example uses `nixos`).
4. Build:

```
# channels target
nix build .#iso.channels-x86_64-linux

# flake target
nix build .#iso.flake-x86_64-linux
```

5. Write the ISO to disk with `dd` or equivalent tool.
6. Boot the target and run the installer. Partition the target disk **partitioning** in 
   Calamares installer. The disk configuration will be used. Most other GUI choices 
   (locale, desktop, extra packages, the user) will be overwritten by the provided 
   `configuration.nix`, so just click through them. For a **flake** target, set the 
   **hostname** to match your `nixosConfigurations.<name>`. The install may appear 
   to sit for a long time while it copies and rebuilds from the store. 
   Toggle the log to see activity.

### Users and passwords

The provided `configuration.nix` sets users and their passwords. 
**Set a password in your config** ( e.g. `users.users.<name>.initialPassword`,
`hashedPassword`, or `hashedPasswordFile`), and for `root` if you want
root login). The example configs use `initialPassword = "test"` for `root` and
`tester`. You can log in as `tester` / `test`.

### Dynamic configuration

You can customize a configuration at install time by placing it in `/tmp/nix-cfg`.
The installer will ignore the baked-in `/iso/nix-cfg` configuration, so you
can edit the config after booting the live environment. Remember though, you can 
safely remove items from a configuration, but if your edits add dependencies 
that aren't in the ISO store, the offline install will fail.

## Flake offline support

Offline `nixos-install --flake` requires several workarounds (see
[nix#8953](https://github.com/NixOS/nix/issues/8953)): 

1. Evaluate offline by pinning `nixpkgs` to a store path.
So at ISO-build time the builder bakes a *copy* of your flake whose
`nixpkgs` input is rewritten to `path:/nix/store/…-source` (the nixpkgs already
in the ISO store), together with a matching, complete `flake.lock`. A `path:`
input with a complete lock needs no registry and no network.

2. Build offline by using the live install environment store and passing the 
finished path to `nixos-install --system`, which just copies the closure to the 
target. The Calamares hostname must match a `nixosConfigurations.<name>` attribute 
in the flake.

3. Bake inputs into the closure. The ISO store carries the target system's built 
closure, its derivation closure (`.drv`s + source tarballs, for the hardware-config rebuild), 
and the nixpkgs source.

Do **not** commit a `configs/flake/flake.lock` the builder generates the path-pinned 
lock for the ISO copy. The repo `flake.nix` uses an indirect `nixpkgs` so it 
still resolves normally on a networked machine.

**After install**, the target's `/etc/nixos/flake.nix` carries the store-path
`nixpkgs` ref. For online rebuilds later, repoint it to a channel, e.g.
`nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";`, then `nix flake update`.

### Free disk space

The ISO is large (20+ GB depending on the config). Keep ~3× the ISO size free
(100+ GB recommended) on the build host's Nix store partition.
