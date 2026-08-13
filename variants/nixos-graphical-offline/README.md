# NixOS Offline ISO Builder

> Product documentation for `nixos-graphical-offline`, carried over from its pre-flatten
> branch. Paths like `configs/flake/` mean this directory's `configs/`;
> build commands may be stale — the authoritative output name is
> `nix build .#installer-iso-nixos-graphical-offline` (see the repo README).

Build offline ISO images of the NixOS Calamares installer that include a
user-provided system configuration that can be installed with **no network connection**, 
by including all of its dependencies in the ISO's Nix store.

Two install types are supported:

- **channels** - a plain `configuration.nix` (tracks a NixOS channel, no flake)
- **flake** - a `flake.nix` (installed offline; see [Flake offline support](#flake-offline-support))

## Usage

1. [Install Nix](https://nixos.org/download) with flakes enabled on an online
   system with plenty of free disk (see below).
2. Put your system config in either `configs/channels/` or `configs/flake/`.
   Keep the provided `hardware-configuration.nix` template. It is needed to build 
   the ISO closure and is overwritten by the real hardware scan at install time. 
   If there are significant differences between the target hardware and the 
   `hardware-configuration.nix` template, then you may need to replace the template 
   config with the generated one so that the ISO includes necessary dependencies. 
3. For a flake target, the installer selects the `nixosConfigurations.<name>`
   attribute automatically: it uses the sole attribute if your flake defines
   exactly one, otherwise it expects one named `nixos` (the example uses `nixos`).
4. Build:

```
# channels target
nix build .#iso.channels-x86_64-linux

# flake target
nix build .#iso.flake-x86_64-linux
```

5. Write the ISO to disk with `dd` or equivalent tool.
6. Boot the target and run the installer. Partition the target disk **partitioning** in 
   Calamares installer. The disk configuration will be used. The desktop, software, 
   and user-configuration (user/password/hostname) pages are removed since the 
   provided `configuration.nix` owns those; the remaining GUI choices (locale, 
   keyboard) are also overwritten by it, so just click through them. For a **flake** 
   target the installer picks your `nixosConfigurations.<name>` automatically (the 
   sole attribute, or one named `nixos`), so there is no hostname to enter. The 
   install may appear to sit for a long time while it copies and rebuilds from the 
   store. Toggle the log to see activity.

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
3. Removes the Calamares pages whose choices your configuration overrides:
   the user-configuration page (your config owns users, passwords, and the
   hostname, see [Users and passwords](#users-and-passwords)), the
   desktop-environment selection page, and the free/unfree software page.
   Whatever these would have generated is replaced by the copied config in step 2. 
   For a flake, the target `nixosConfigurations` attribute is auto-selected 
   (sole attribute, or one named `nixos`) instead of coming from the removed 
   hostname field.
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

1. **Evaluate offline** by pinning *every* input to a store path. At ISO-build
   time the builder bakes a *copy* of your flake with a rewritten `flake.lock`:
   for each input it reads your committed lock, fetches that input's source, and
   repoints the input's `locked` ref to the resulting `/nix/store/…` path. Your
   `flake.nix` is copied verbatim — `inputs` and `outputs` are untouched — so
   `follows` edges (e.g. an input following your `nixpkgs`) keep working. A `github`
   `original` with a `path` `locked` needs no registry and no network. This
   works for any real multi-input flake, not just a lone `nixpkgs`.

2. **Build offline** in the live install environment store, passing the finished
   path to `nixos-install --system`, which just copies the closure to the
   target. The ISO bakes exactly one config's closure: the entry named `nixos`,
   or the sole entry if there is only one (the Calamares flake install
   auto-selects the same attribute).

3. **Bake the inputs** into the closure. The ISO store carries the target
   system's built closure, its derivation closure (`.drv`s + source tarballs, for
   the hardware-config rebuild), and the source tree of every flake input.

You **must** commit a git-tracked `configs/flake/flake.lock` (generate it with
`nix flake lock ./configs/flake`); the builder reads it to learn which input
revisions to pin. An untracked lock is invisible to the flake and the build will
tell you it is missing.

**After install**, the target's `/etc/nixos/flake.nix` is unchanged. It still
carries your original `github:` input refs, but its `flake.lock` points every
input at a store path. For online rebuilds later, run `nix flake update` to
re-lock against the network.

### Free disk space

The ISO is large (20+ GB depending on the config). Keep ~3× the ISO size free
(100+ GB recommended) on the build host's Nix store partition.
