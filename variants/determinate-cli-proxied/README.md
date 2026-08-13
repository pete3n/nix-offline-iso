# NixOS Proxied-Install ISO (Determinate Nix, minimal CLI installer)

> Product documentation for `determinate-cli-proxied`, carried over from its pre-flatten
> branch. Paths like `configs/flake/` mean this directory's `configs/`;
> build commands may be stale — the authoritative output name is
> `nix build .#installer-iso-determinate-cli-proxied` (see the repo README).

Builds an minimal CLI installer with Determinate Nix for networks whose only
route to the internet is a proxy-cache.

## Usage

1. [Install Nix](https://nixos.org/download) with flakes enabled on an online
system with plenty of free disk (see below).

2. Build the ISO:
```
nix build .#iso.x86_64-linux
```

3. Write the ISO to disk with dd or an equivalent tool.

4. Boot the ISO and follow the instructions from the console.

5. **Clone your Config repo**: `git clone <your-repo-url> /tmp/nix-cfg`

6. **Edit** `/tmp/nix-cfg` if needed (hostname, LUKS device, hardware).

7. **`sudo proxy-setup`** to confirm or replace the prefilled Cache URL
   (`http://nix-proxy.lan`). It probes `<url>/nix-cache-info` and refuses to
   proceed unless the answer looks like a Nix binary cache, then points the
   live environment's substituters at the proxy and records the URL for the
   installer. 

8. **`sudo proxied-install`** builds and installs. Use `--host NAME` if
   your `nixosConfigurations.<name>` isn't `nixos`, `--config DIR` if you
   cloned somewhere other than `/tmp/nix-cfg`.

- **Declare the Cache URL as the target's substituter**, e.g.

  ```nix
  nix.settings.substituters = [ "http://nix-proxy.lan" ];
  ```

## How it works

`proxy-setup` (`cli/proxy-setup.sh`): validates the URL shape, probes
`<url>/nix-cache-info`, then declares `substituters = <url>` in
`/etc/nix/nix.custom.conf` and restarts `nix-daemon.service` 
(which execs `determinate-nixd`).

`proxied-install` (`cli/proxied-install.sh`), in order:

1. Refuses to run without the recorded Cache URL (`--cache-url` overrides).
2. Exports env-level `NIX_CONFIG` (`extra-experimental-features`,
   `substituters = <Cache URL>`) so *every* nix it spawns substitutes
   through the proxy regardless of which client reads which conf file. The
   script's own `nix` is Determinate's client (it ships no upstream nix of
   its own), but `nixos-install` bundles an upstream client internally, and
   the env covers it too.
3. Requires `flake.nix` in the config dir.
4. **Pin match**: compares the config lock's `determinate` narHash against
   `/etc/determinate-pin`; a mismatch warns (from-source build) and asks for
   YES. Skipped with a note when there is no lock to read.
5. One full evaluation answers two pre-flight questions: disko layout
   (disko then owns partitioning) and declared substituters (warning above).
6. Partitions (disko / `--disk` / you), runs `nixos-generate-config` for
   non-disko targets (preserving the generated `hardware-configuration.nix`,
   with the ESP-umask fix), copies the config to `/etc/nixos`.
7. Builds `…#nixosConfigurations.<host>…toplevel` **in the live store** —
   whose substituters point at the proxy — and installs the finished path
   with `nixos-install --system … --no-channel-copy` (a flake-managed
   system has no use for a root channel).

## Layout

```
flake.nix                     thin ISO builder (Determinate live env)
cli/proxy-setup.sh            Cache-URL probe + live substituter reroute
cli/proxied-install.sh        console installer (shipped on the ISO)
cli/partition-help.txt        manual partitioning cheat-sheet (`partition-help`)
tools/test-proxied-install.sh component test (mock appliance)
docs/appliance-requirements.md  what the Cache proxy must additionally serve
docs/adr/0003-*.md            why this ISO bakes nothing and owns no URLs
docs/plan.md                  the implementation plan this branch followed
```

## Manual partitioning (encrypted root + swap)

`proxied-install --disk` only makes a simple unencrypted layout. For an
encrypted install, partition by hand first — run **`partition-help`** at the
console (or read [`cli/partition-help.txt`](cli/partition-help.txt)) for a
worked LUKS2 + LVM example.

`proxied-install` runs `nixos-generate-config`, which auto-detects
filesystems and swap but **not** the LUKS layer beneath LVM. Declare the
unlock device in your **`configuration.nix`** (which is preserved), not the
hardware file (which is regenerated at install time):

```nix
boot.initrd.luks.devices."cryptroot".device =
  "/dev/disk/by-uuid/<UUID of the LUKS partition>";
```

### disko targets

If your config imports [disko](https://github.com/nix-community/disko) and
declares a `disko.devices` layout, `proxied-install` builds the config's
`system.build.diskoScript` at install time (fetching through the proxy as
needed) and runs it to wipe, partition, format and mount the declared
disk(s) at `/mnt`. It does **not** run `nixos-generate-config` for a disko
target — disko owns the `fileSystems` config, and defining
`fileSystems."/"` twice fails evaluation. Keep filesystem-independent
hardware bits (kernel modules, `nixpkgs.hostPlatform`) in your committed
`hardware-configuration.nix`. `--no-disko` partitions/mounts yourself while
disko still owns `fileSystems`.
