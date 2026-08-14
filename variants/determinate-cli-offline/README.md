# NixOS Offline ISO Builder (Determinate Nix, minimal CLI installer)

> Variant documentation for `determinate-cli-offline`, carried over from its pre-flatten
> branch. Paths like `configs/flake/` mean this directory's `configs/`;
> build commands may be stale — the authoritative output name is
> `nix build .#installer-iso-determinate-cli-offline` (see the repo README).

Build offline ISO images of a **minimal, console-based** NixOS installer that
include a user-provided flake configuration that can be installed with **no
network connection**, by including all of its dependencies in the ISO's Nix
store.

This branch ships **Determinate Nix**: [Determinate Systems'](https://determinate.systems) 
Nix distribution. It runs runs on **both the live installer and the installed system**, 
while keeping the install fully offline. 

## Usage

1. [Install Nix](https://nixos.org/download) with flakes enabled on an online
   build host with plenty of free disk (see below).
2. Put your system config in `configs/flake/`. Keep the provided
   `hardware-configuration.nix` template. It is needed to build the ISO closure
   and is overwritten by the real hardware scan at install time. If there are
   significant differences between the target hardware and the
   `hardware-configuration.nix` template, then you may need to replace the template
   config with the generated one so that the ISO includes necessary dependencies.
   Your config imports `determinate.nixosModules.default` (see the example
   `configs/flake/flake.nix`) so the installed system runs Determinate Nix.
3. The `nixosConfigurations.<name>` attribute must match the installer hostname
   (default `nixos`) or the `--host NAME` you pass to `offline-install`.
4. If you changed `configs/flake/flake.nix`, regenerate and commit its lock
   (`nix flake lock ./configs/flake && git add configs/flake/flake.lock`), then
   re-lock the builder (`nix flake lock`). Build:

```
nix build .#iso.flake-x86_64-linux
```

5. Write the ISO to disk with `dd` or an equivalent tool.
6. Boot the target, and follow the instructions from the console.

## How it works

The installer is the stock NixOS **minimal** (console) image
(`installation-cd-minimal`). The ISO simply ships an `offline-install` script 
(`cli/offline-install.sh`) and a login hint. When you run it, the script:

1. Runs `nixos-generate-config --root /mnt` and preserves the freshly generated
   `hardware-configuration.nix`.
2. Copies your files from `/tmp/nix-cfg` or `/iso/nix-cfg` into
   `/mnt/etc/nixos`, then restores the generated `hardware-configuration.nix`.
   Your config owns users and passwords (see
   [Users and passwords](#users-and-passwords)).
3. Builds the system **in the live installer store** via
   `nix build …#…toplevel` and installs the finished path with
   `nixos-install --system`, which just copies the closure to the target.
   Building in the live store (not the empty target store) is what lets the
   install succeed offline. The build runs through **`determinate-nixd`**, which
   the Determinate module installs as the live installer's `nix-daemon`.

The installer is also configured to run nix **fully offline** during install
(`nix.settings.substituters = [ ]` and `flake-registry = ""`). Without this, nix
reaches out to `cache.nixos.org` (binary-cache probe) and `channels.nixos.org`
(global flake registry) and fails with no network. The Determinate module 
redirects the generated `nix.conf` to `/etc/nix/nix.custom.conf`, which
`determinate-nixd` includes. Determinate additionally pins a *system* flake-registry 
entry for `nixpkgs` to a FlakeHub tarball, which `flake-registry = ""` does not 
cover, so the installer also forces `nix.registry = {}` (empty) (see 
[Determinate Nix](#determinate-nix)). Because `nixos-generate-config` regenerates 
`hardware-configuration.nix` for the target machine at install time, the 
installed system differs slightly from what was pre-built, so a small rebuild 
must be performed. The ISO bakes the target's **build/derivation closure** so that 
the rebuild runs offline from sources already in the store.

## Determinate Nix

This branch replaces upstream Nix with **Determinate Nix** in two places:

- **The live installer** imports `determinate.nixosModules.default`
  into the installer image. Its `determinate-nixd` daemon does the install-time
  build.
- **The installed system example** `configs/flake/flake.nix` imports the same module,
  so the machine you install runs Determinate Nix.

Both pin Determinate to FlakeHub major version `3` (`.../determinate/3`); the
committed locks record the exact release baked into the ISO.

- No cache substituter is configured (`determinate.edgeCacheSubstituters` is left
  at its `null` default; the module adds no substituter on its own).
- The installer forces `nix.settings.substituters = [ ]` and, because
  Determinate's module pins a FlakeHub `nixpkgs` registry entry,
  `nix.registry = {}` as well, so no bare flakeref resolution reaches the
  network.

## Layout

```
flake.nix                     ISO builder (Determinate installer + offline logic)
cli/offline-install.sh        console installer script (shipped on the ISO)
cli/partition-help.txt        manual partitioning cheat-sheet (`partition-help`)
configs/
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
login). The example config uses `initialPassword = "test"` for `root` and
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
   `follows` edges (e.g. `disko` following `nixpkgs`) keep working. An `original`
   ref with a `path` `locked` needs no registry and no network: Nix reuses the
   lock without re-fetching and resolves each source from the store. This holds
   regardless of the original fetch type, so it works for the whole Determinate
   input tree — `github`, FlakeHub `tarball` inputs (`determinate`, its `nix`,
   `nixpkgs-weekly`, …), and the `file` inputs (the `determinate-nixd` binaries)
   are all repinned the same way.

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
revisions to pin. On this branch that lock includes `determinate` and its whole
transitive tree, so the builder bakes several source trees (Determinate's nix
source, `nixpkgs-weekly`, the `determinate-nixd` binaries, plus your own
`nixpkgs`). An untracked lock is invisible to the flake and the build will tell
you it is missing.

**After install**, the target's `/etc/nixos/flake.nix` is unchanged — it still
carries your original input refs (`github:` / FlakeHub `https://flakehub.com/…`)
— but its `flake.lock` points every input at a store path. For online rebuilds
later, run `nix flake update` to re-lock against the network.

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

disko always wipes the device(s) **declared in the config** — `--disk` cannot
redirect it, so passing `--disk` to a disko target is a hard error rather
than a silently ignored flag (the installer names the declared devices,
verifies they exist on the machine, and asks for confirmation before
wiping). If the target machine's disk is named differently (a VM's virtio
disk is `/dev/vda`, not `/dev/sda`), edit the device in `/tmp/nix-cfg`'s
disko config and re-run. `tools/test-offline-install-args.sh` locks this
behavior down.

### Free disk space

The ISO is large (depending on the config) — though smaller than the graphical
variant since there is no desktop. Determinate adds to it: its module bakes the
Determinate Nix package plus several full source trees from its input tree
(see [Flake offline support](#flake-offline-support)), so expect a noticeably
larger ISO and a long first build. Keep ~3× the ISO size free on the build
host's Nix store partition.
