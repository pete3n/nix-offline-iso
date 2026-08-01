# NixOS Offline ISO Builder (minimal CLI installer)

Build offline ISO images of a **minimal, console-based** NixOS installer that
include a user-provided system configuration that can be installed with **no
network connection**, by including all of its dependencies in the ISO's Nix
store.

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
6. Boot the target and follow the instructions from the console.

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
3. Builds the system **in the live installer store** channels via
   `nix-build '<nixpkgs/nixos>'`, flake via `nix build …#…toplevel` and installs
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
cli/partition-help.txt        manual partitioning cheat-sheet (`partition-help`)
configs/
  channels/                   example channels target (configuration.nix)
  flake/                      example flake target (flake.nix + configuration.nix)
```

## Manual partitioning (encrypted root + swap)

`offline-install --disk` only makes a simple unencrypted layout. For an
encrypted install, manually partition and then run `offline-install`.  
Run **`partition-help`** at the console (or read [`cli/partition-help.txt`](cli/partition-help.txt))
to view example instructions for partitioning, formatating, and created LUKS 
encrypted volumes.

`offline-install` runs `nixos-generate-config`, which auto-detects the
filesystems and swap. It does **not** detect the LUKS layer beneath LVM, so you
must declare the unlock device yourself. Because this installer regenerates
`hardware-configuration.nix` at install time, put it in your
**`configuration.nix`** (which is preserved), not the hardware file:

```nix
boot.initrd.luks.devices."cryptroot".device =
  "/dev/disk/by-uuid/<UUID of the LUKS partition>";
```

(If you skip LVM and put ext4 directly on the LUKS device,
`nixos-generate-config` *does* add that entry for you (see the notes in
`partition-help`).

### Users and passwords

The provided `configuration.nix` sets users and their passwords.
**Set a password in your config** (e.g. `users.users.<name>.initialPassword`,
`hashedPassword`, or `hashedPasswordFile`, and for `root` if you want root
login). The example configs use `initialPassword = "test"` for `root` and
`tester`. You can log in as `tester` / `test`.

### Dynamic configuration

At boot the live installer seeds a **writable copy** of the baked `/iso/nix-cfg`
into `/tmp/nix-cfg` (the baked copy is read-only iso9660). Edit
`/tmp/nix-cfg/configuration.nix` from the console before running
`offline-install`, for example to add a `boot.initrd.luks.devices` entry for an
encrypted disk. `offline-install` prefers `/tmp/nix-cfg` over `/iso/nix-cfg`, so
your edits are what gets installed; the seed only runs when `/tmp/nix-cfg`
doesn't already exist, so a hand-made copy is never clobbered. Remember you can
safely remove items from a configuration, but if your edits add dependencies
that aren't in the ISO store, the offline install will fail.

## Flake offline support

Offline flake installs require several workarounds (see
[nix#8953](https://github.com/NixOS/nix/issues/8953)):

1. **Evaluate offline** by pinning *every* input to a store path. At ISO-build
   time the builder bakes a *copy* of your flake with a rewritten `flake.lock`:
   for each input it reads your committed lock, fetches that input's source, and
   repoints the input's `locked` ref to the resulting `/nix/store/…` path. Your
   `flake.nix` is copied verbatim — `inputs` and `outputs` are untouched — so
   `follows` edges (e.g. `disko` following `nixpkgs`) keep working. A `github`
   `original` with a `path` `locked` needs no registry and no network: Nix
   reuses the lock without re-fetching and resolves each source from the store.
   This works for any real multi-input flake, not just a lone `nixpkgs`.

2. **Build offline** in the live installer store, then pass the finished path to
   `nixos-install --system`, which just copies the closure to the target. The
   installer hostname (or `--host`) must match a `nixosConfigurations.<name>`
   attribute in the flake. The ISO bakes exactly one config's closure: the entry
   named `nixos`, or the sole entry if there is only one.

3. **Bake the inputs** into the closure. The ISO store carries the target
   system's built closure, its derivation closure (`.drv`s + source tarballs, for
   the hardware-config rebuild), and the source tree of every flake input.

You **must** commit a git-tracked `configs/flake/flake.lock` (generate it with
`nix flake lock ./configs/flake`); the builder reads it to learn which input
revisions to pin. An untracked lock is invisible to the flake and the build will
tell you it is missing.

**After install**, the target's `/etc/nixos/flake.nix` is unchanged — it still
carries your original `github:` input refs — but its `flake.lock` points every
input at a store path. For online rebuilds later, run `nix flake update` to
re-lock against the network.

### disko targets

If your flake config imports [disko](https://github.com/nix-community/disko)
and declares a `disko.devices` layout, `offline-install` uses it: the builder
bakes the config's `system.build.diskoScript` (and its closure) into the ISO,
and at install time the script runs disko to wipe, partition, format and mount
the declared disk(s) at `/mnt`, then installs. It does **not** run
`nixos-generate-config` for a disko target, because disko already owns the
`fileSystems` config — running both would define `fileSystems."/"` twice and
fail evaluation. Keep filesystem-independent hardware bits (kernel modules,
`nixpkgs.hostPlatform`) in your committed `hardware-configuration.nix`; it is
used as-is. Use `--no-disko` to partition/mount yourself while still letting
disko own `fileSystems`.

### Free disk space

The ISO is large (depending on the config) — though smaller than the graphical
variant since there is no desktop. Keep ~3× the ISO size free on the build
host's Nix store partition.
