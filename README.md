# NixOS Offline ISO Builder

Build offline ISO images of the NixOS Calamares installer that install a
user-provided system configuration with **no network connection**, including
all of its dependencies in the ISO's Nix store.

Targets **NixOS 26.05** and whatever `calamares-nixos-extensions` that channel
ships. Two target styles are supported:

- **channels** — a plain `configuration.nix` (classic, no flake)
- **flake** — a `flake.nix` (installed offline; see [Flake offline support](#flake-offline-support))

## How it works

The installer is the stock NixOS graphical Calamares (GNOME) image, with the
`calamares-nixos-extensions` package modified through a **robust overlay**
(`flake.nix`) rather than the old context-diff patches. The overlay:

1. Ships a controlled `calamares/welcome.conf` that drops the `internet`
   requirement, so the installer runs offline.
2. Injects a config-copy step into the installer's `nixos` module
   (`calamares/inject/config-copy.py`) that copies your files from
   `/tmp/nix-cfg` or `/iso/nix-cfg` into `/etc/nixos`, preserving the
   freshly generated `hardware-configuration.nix`.
3. Removes Calamares' imperative password step (your config owns users and
   passwords — see [Users and passwords](#users-and-passwords)).
4. For a flake config, builds the system in the live installer store and
   installs the result with `nixos-install --system` (see
   [Flake offline support](#flake-offline-support)).

These source transforms are anchored on stable comments/strings in the upstream
source and are **guarded: the build fails loudly if an anchor ever disappears**,
instead of silently shipping a no-op installer. This is the fix for the
recurring breakage where an upstream rewrite invalidated the old line-context
patches.

The installer is also configured to run nix **fully offline** during install
(`nix.settings.substituters = [ ]` and `flake-registry = ""`). Without this,
`nixos-install` reaches out to `cache.nixos.org` (binary-cache probe) and
`channels.nixos.org` (global flake registry) and fails with no network — which
is the whole point of the ISO. Consequently the ISO store must be
self-sufficient. Because `nixos-generate-config` regenerates
`hardware-configuration.nix` for the real machine at install time, the installed
system differs slightly from what was pre-built, so a small rebuild is
unavoidable — the ISO therefore bakes the target's **build/derivation closure**
(channels via `isoImage.includeSystemBuildDependencies`; the flake target via
its `toplevel.drvPath` plus `system.includeBuildDependencies`) so that rebuild
runs offline from sources already in the store.

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
   Keep a `hardware-configuration.nix` template there — it is needed to build
   the ISO closure and is overwritten by the real hardware scan at install time.
   Keep it vendor-neutral: don't force-load CPU-specific modules
   (`boot.kernelModules = [ "kvm-intel" ]` etc.). For the channels installer this
   file is merged into the live installer, and a force-loaded `kvm-intel` makes
   `systemd-modules-load` fail with "Operation not supported" when the installer
   runs on a machine/VM without that CPU's virtualization exposed.
3. For a flake target, the `nixosConfigurations.<name>` attribute must match the
   hostname you enter in Calamares (the example uses `nixos`).
4. Build:

```
# channels target
nix build .#iso.channels-x86_64-linux

# flake target
nix build .#iso.flake-x86_64-linux
```

5. Write the ISO to disk with `dd` (or image it into a VM — see Testing).
6. Boot the target and run the installer. Do the **partitioning** in the GUI —
   that part is real and is used. Most other GUI choices (locale, desktop, extra
   packages, the user) are **cosmetic**: your config is authoritative and
   overwrites the generated `configuration.nix`, so just click through them. For
   a **flake** target, set the **hostname** to match your
   `nixosConfigurations.<name>`. The install may appear to sit for a long time
   while it copies and rebuilds from the store — toggle the log to see activity.

### Users and passwords

Your declarative config owns users **and** their passwords. The overlay removes
Calamares' imperative password step from the install sequence (it ran `usermod`
in the chroot and failed with exit 6 whenever the GUI username differed from the
one your config declares). The Calamares users page still appears but its input
is not used.

So **set a password in your config** — e.g. `users.users.<name>.initialPassword`,
`hashedPassword`, or `hashedPasswordFile` (and likewise for `root` if you want
root login). The example configs use `initialPassword = "test"` for `root` and
`tester`; log in as `tester` / `test`.

### Dynamic configuration

The installer prefers `/tmp/nix-cfg` over the baked-in `/iso/nix-cfg`, so you
can edit the config after booting the live environment. If your edits add
dependencies that aren't in the ISO store, the offline install will fail.

## Flake offline support

Offline `nixos-install --flake` is the hard part (see
[nix#8953](https://github.com/NixOS/nix/issues/8953)): the flake must both
*evaluate* and *build* without network. The `flake-*` target solves this in
three pieces.

**1. Evaluate offline — pin `nixpkgs` to a store path.** Having the input's
store path present is not enough: nix won't resolve a locked `github:` input
from the store offline, and it won't reliably consult the system flake registry
for input resolution during `nixos-install` (and we disable the global
registry). So at ISO-build time the builder bakes a *copy* of your flake whose
`nixpkgs` input is rewritten to `path:/nix/store/…-source` (the nixpkgs already
in the ISO store), together with a matching, complete `flake.lock`. A `path:`
input with a complete lock needs no registry and no network — and nix never has
to *write* a lock, which for a `path:` flake would mutate the directory
mid-evaluation and cause a NAR-hash mismatch. Your repo's
`configs/flake/flake.nix` stays clean (the indirect ref `"nixpkgs"`); only the
baked ISO copy carries the store path.

**2. Build offline — build in the live store, install with `--system`.**
`nixos-install --flake` would realize the system into the empty target store,
which offline can't be populated (substituters are disabled), so it would
rebuild the toolchain from source and fail. Instead the `nixos` module builds
the flake's `toplevel` in the **live installer store** (where every build input
is already present) and passes the finished path to `nixos-install --system`,
which just copies the closure to the target. The Calamares hostname must match a
`nixosConfigurations.<name>` attribute in the flake.

**3. Have the inputs — bake the closure.** The ISO store carries the target
system's built closure, its derivation closure (`.drv`s + source tarballs, for
the small hardware-config rebuild), and the nixpkgs source.

You do **not** commit a `configs/flake/flake.lock` — the builder generates the
path-pinned lock for the ISO copy. The repo `flake.nix` uses an indirect
`nixpkgs` so it still resolves normally on a networked machine.

**After install**, the target's `/etc/nixos/flake.nix` carries the store-path
`nixpkgs` ref. For online rebuilds later, repoint it to a channel, e.g.
`nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";`, then `nix flake update`.

## Testing in a VM

```
# build, then boot the ISO with no network to prove offline behavior:
qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
  -drive file=disk.qcow2,if=virtio -boot d \
  -cdrom result/iso/*.iso \
  -nic none                       # <- no network; offline install must still work
```

Add `-nic user,hostfwd=tcp::2222-:22` instead of `-nic none` after install to
SSH into the installed system (the example configs enable SSH; test password is
`test`).

The example configs are minimal and **headless** (SSH only, no desktop), so the
installed system has no graphical output under SPICE/quickemu — that's expected,
not a failure; SSH in to verify it. Add a desktop environment (and, for VMs, a
guest video setup like `services.spice-vdagentd.enable`) to your config if you
want a GUI. Note also that the stock installer image logs a failed
`xe-daemon.service` (Xen guest agent) on non-Xen VMs like QEMU — harmless and
unrelated to the install.

### Free disk space

The ISO is large (20+ GB depending on the config). Keep ~3× the ISO size free
(100+ GB recommended) on the build host's Nix store partition.
