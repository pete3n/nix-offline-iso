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

   For an **encrypted** or otherwise custom layout, partition by hand before
   running `offline-install` — run `partition-help` at the console for a
   worked LUKS2 + LVM (encrypted root + swap) example. See
   [Manual partitioning](#manual-partitioning-encrypted-root--swap).

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
cli/partition-help.txt        manual partitioning cheat-sheet (`partition-help`)
configs/
  channels/                   example channels target (configuration.nix)
  flake/                      example flake target (flake.nix + configuration.nix)
```

## Manual partitioning (encrypted root + swap)

`offline-install --disk` only makes a simple unencrypted layout. For an
encrypted install — the CLI equivalent of what the graphical installer offers —
partition by hand, then run `offline-install` (no `--disk`) against what you
mounted at `/mnt`. The ISO already ships everything you need: `cryptsetup`,
`lvm2`, `parted`, and the `mkfs`/`mkswap` tools. Run **`partition-help`** at the
console (or read [`cli/partition-help.txt`](cli/partition-help.txt)) for the
full worked example; the shape is:

1. GPT with a ~1 GiB EFI system partition + a second partition for the container.
2. `cryptsetup luksFormat --type luks2` + `cryptsetup open` the second partition.
3. LVM inside it (`pvcreate`/`vgcreate`/`lvcreate`) for `swap` + `root` — one
   passphrase unlocks both, and swap is encrypted because it lives in the
   container.
4. `mkfs.ext4` the root LV, `mkswap` the swap LV, then mount at `/mnt` (+ ESP at
   `/mnt/boot`) and `swapon`.

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
`nixos-generate-config` *does* add that entry for you — see the notes in
`partition-help`.)

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
`offline-install` — for example to add a `boot.initrd.luks.devices` entry for an
encrypted disk. `offline-install` prefers `/tmp/nix-cfg` over `/iso/nix-cfg`, so
your edits are what gets installed; the seed only runs when `/tmp/nix-cfg`
doesn't already exist, so a hand-made copy is never clobbered. Remember you can
safely remove items from a configuration, but if your edits add dependencies
that aren't in the ISO store, the offline install will fail.

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
