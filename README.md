# NixOS Offline ISO Builder

Build offline ISO images of the NixOS Calamares installer that install a
user-provided system configuration with **no network connection**, including
all of its dependencies in the ISO's Nix store.

Targets **NixOS 26.05** and whatever `calamares-nixos-extensions` that channel
ships. Two target styles are supported:

- **channels** — a plain `configuration.nix` (classic, no flake)
- **flake** — a `flake.nix` installed offline with `nixos-install --flake`

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
3. Adds `--flake`/`--offline` to `nixos-install` when the copied config is a
   flake.

Both injections are anchored on stable comments in the upstream source and are
guarded: **the build fails loudly if an anchor ever disappears**, instead of
silently shipping a no-op installer. This is the fix for the recurring breakage
where an upstream rewrite invalidated the old line-context patches.

The installer is also configured to run nix **fully offline** during install
(`nix.settings.substituters = [ ]` and `flake-registry = ""`). Without this,
`nixos-install` reaches out to `cache.nixos.org` (binary-cache probe) and
`channels.nixos.org` (global flake registry) and fails with no network — which
is the whole point of the ISO. Consequently the ISO store must be
self-sufficient: the target's **build dependencies** are baked in (channels via
`isoImage.includeSystemBuildDependencies`; the flake target via
`system.includeBuildDependencies`), so the install can rebuild locally after
`nixos-generate-config` regenerates `hardware-configuration.nix`.

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
6. Boot the target, run the installer as normal. Pick options consistent with
   your config (desktop, user). The install may sit at ~46% for a long time
   while dependencies copy — toggle the log to see activity.

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

## Flake offline support (experimental)

Offline `nixos-install --flake` is the hard part (see
[nix#8953](https://github.com/NixOS/nix/issues/8953)): evaluation needs every
flake input available without network, and simply having the input's store path
present is NOT enough — nix won't resolve a locked `github:` input from the
store offline.

The `flake-*` target sidesteps this by pinning `nixpkgs` to a **local store
path in the flake itself**:

- `configs/flake/flake.nix` in the repo stays clean — `nixpkgs` is an indirect
  ref (`"nixpkgs"`).
- At ISO-build time the builder bakes a *copy* of the flake whose `nixpkgs`
  input is rewritten to `path:/nix/store/…-source` (the nixpkgs already in the
  ISO store). A `path:` input needs no flake registry and no network, so
  `nixos-install --flake` locks and evaluates it fully offline.

This is deliberately not a registry pin: during `nixos-install --flake`,
indirect-input resolution does not reliably consult the system registry (and we
disable the global one), and a locked `github:` input can't be resolved from the
store offline. A `path:` input avoids resolution entirely.

**Do NOT commit a `configs/flake/flake.lock`** — a github-pinned lock would
override the path rewrite and reintroduce the offline fetch failure. If you
generated one during earlier experiments, delete it:

```
rm -f configs/flake/flake.lock
```

**After install**, the target's `/etc/nixos/flake.nix` will have the store-path
`nixpkgs` ref. For online rebuilds later, repoint it to a normal channel, e.g.
`nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";`, and `nix flake update`.

The `flake-*` target additionally pulls into the ISO store:

- the target system's built closure (so the build is a store copy, not a
  rebuild),
- the flake source tree, and
- the nixpkgs input source tree (unified via `follows`, so there's only one).

Install then runs with `--offline`. **This path still needs validation on real
hardware / a VM** — if `--offline` evaluation still reaches for the network on
your nixpkgs version, the fallback is to vendor the flake inputs as `path:`
references. Keep `configs/flake/flake.lock` pinned to the same nixpkgs revision
the ISO builder uses.

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

### Free disk space

The ISO is large (20+ GB depending on the config). Keep ~3× the ISO size free
(100+ GB recommended) on the build host's Nix store partition.
