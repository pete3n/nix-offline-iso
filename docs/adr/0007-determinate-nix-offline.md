# Ship Determinate Nix on an offline installer, hard-neutered

> Formerly ADR 0001 on `nixos-26.05-cli-determinate`; renumbered by the
> ADR 0008 flatten to resolve the collision with 0001-offline-rebuild-deps
> (the stock lineage's ADR). Citations of "finding #6" point here.

On the `nixos-26.05-cli-determinate` branch we replace upstream Nix with
Determinate Systems' Nix distribution on both the Installer and the Target,
while keeping the install 100% offline. Determinate is an online-first
distribution (its daemon `determinate-nixd` and its value proposition center on
FlakeHub Cache/login), so this is a deliberately unusual pairing: we want
Determinate Nix's improved daemon/binary, not its network features.

## Decision

Keep `github:nixos/nixpkgs/nixos-26.05` as the sole nixpkgs and add
`determinate` as an extra input rather than switching to Determinate's FlakeHub
rolling nixpkgs. Apply Determinate only to the **flake target** (the channels
target is dropped on this branch, since Determinate is flakes-first). Adopt two
Determinate installer conveniences — NetworkManager and the `fh` CLI — but not
its flake-mode `nixos-generate-config` or `determinate-nixd login` MOTD, both of
which conflict with `offline-install.sh` preserving the user's committed flake.

## Hard-neuter, not best-effort — Consequences

Inspecting the pinned module (`determinate` 3.21.9, `modules/nixos.nix`) showed
the neutering surface is smaller than first assumed: the module adds **no**
substituter on its own (`determinate.edgeCacheSubstituters` defaults to `null`;
FlakeHub Cache is only added by `determinate-nixd login` at runtime), and our
`nix.settings` still bind Determinate because the module redirects the generated
`nix.conf` into `/etc/nix/nix.custom.conf`, which `determinate-nixd` includes.
The one genuine network path the module introduces is a *system* flake-registry
pin (`nix.registry.nixpkgs.to` → a FlakeHub tarball), which `flake-registry = ""`
does **not** cover. So the installer forces `nix.registry = mkForce {}` alongside
the existing `substituters = mkForce []` and `flake-registry = ""`.

The rejected alternative was to rely on substituters being best-effort (a failed
FlakeHub probe falling back to the baked local store). We rejected it because a
probe against an unreachable host can stall on a timeout during the long
build-and-copy window, weakening the "zero network attempts by construction"
guarantee to "offline in practice". A future reader should not "restore" the
FlakeHub registry pin or re-enable `determinate-nixd`'s online features on the
*installer* thinking it was an oversight — it is the whole point of this branch.
(The installed *target* deliberately keeps Determinate's registry pin and normal
substituters; only the installer is neutered.)

Residual: this module version exposes **no** knob to silence `determinate-nixd`'s
own telemetry/status probes, so that part of "hard-neuter" is unverified — see
below. Re-check the neutering surface whenever the pinned Determinate version
changes.

## Verification notes (install-time findings)

A first end-to-end install surfaced three issues, all rooted in the same fact:
`cli/offline-install.sh` drives an **upstream** `nix` client (`pkgs.nix` in
`offlineInstaller`'s `runtimeInputs`) while the daemon and config are
Determinate's. All three are fixed in the install script; none required changing
the Determinate wiring itself. They only reach the installer on a **rebuilt
ISO**.

1. **Silent exit after "Using configuration from …".** The best-effort host
   resolution `HOST="$(nix eval … 2>/dev/null)"` runs under `set -e`
   (`writeShellApplication`), where a bare assignment adopts the command's exit
   status — so a non-zero `nix eval` aborted the whole script, with the error
   swallowed by `2>/dev/null`. Fix: trailing `|| true` so the documented
   hostname fallback is actually reached.

2. **`error: experimental Nix feature 'nix-command' is disabled`.** Determinate
   enables `nix-command`/`flakes` by default only for *its own* client. Our
   settings land in `/etc/nix/nix.custom.conf`, which the upstream client the
   script invokes doesn't reliably pick up. Fix: the script exports
   `NIX_CONFIG="extra-experimental-features = nix-command flakes"` so it works
   regardless of client or how `determinate-nixd` assembled `nix.conf`.

3. **`nixos-install` reaching `cache.nixos.org` for a channel.** `nixos-install`
   copies a Nixpkgs channel into the target and registers it, realizing the
   channel derivation inside the target chroot — which uses the target's (not
   offline-neutered) `nix.conf`, whose default substituter is `cache.nixos.org`.
   Non-fatal (a warning), but a real network attempt. Fix: `--no-channel-copy`
   (a flake-managed system has no use for a root channel).

A second install + reboot surfaced two more, both fixed in the install script:

4. **`nixos-rebuild switch` on the booted target fails with `path
   '/nix/store/…-source' does not exist`.** The baked lock repins every input to
   a `/nix/store/…-source` path (`pinNode`), but those source trees are consumed
   only at *evaluation* time — they are not in the installed system's runtime
   closure, so `nixos-install --system` never copies them to the target. The
   installed system therefore can't read its own flake inputs. Fix: after
   `nixos-install`, the script extracts every `path`-pinned node from the target
   lock and `nix copy --to "$ROOT"`s those source closures into the target store.

5. **`nix-cache-info` fetched from `cache.nixos.org` as the copy phase starts.**
   Same root as #2/#3: only the explicit `nix … --offline` calls are protected,
   but `nixos-install` runs nix *without* `--offline` (closure copy + chroot
   bootloader activation), and the upstream client doesn't reliably read the
   neutered `nix.custom.conf`, so it falls back to the default substituter and
   probes its `nix-cache-info` handshake. Non-fatal (local closure is complete),
   but a real network attempt. Fix: the script's exported `NIX_CONFIG` now also
   forces `substituters =`/`trusted-substituters =` empty — env-only, so the
   installed target keeps its normal substituters after reboot.

With #4 and #5 fixed, install + reboot + `nixos-rebuild switch` (no-op and
`--flake .#nixos`) were confirmed working. That surfaced the scope of the
offline guarantee for *rebuilds*, and one more change:

6. **A benign config change (e.g. a password) failed offline, pulling a build
   toolchain (`python`, `bash`, `binutils`, `bison`, `bzip2`, `gnu-config`…).**
   A no-op rebuild builds nothing (outputs already present), but any real change
   produces new store paths that must be *built*, needing build-tool outputs the
   *plain* runtime toplevel doesn't carry — so nixos-rebuild reached for
   `cache.nixos.org`. **Contract:** the target must be able to rebuild config
   changes over a *baked* package/service set with no network; a genuinely new
   package or service may still need the network.

   First attempt — install the `targetToplevel` built with
   `system.includeBuildDependencies = true` — **overflowed a 64 GB target disk.**
   That option bakes the entire *recursive* build-output closure, and on a
   Determinate target `nix` is built from source, so it dragged in the whole
   Rust/LLVM + gcc-bootstrap toolchain (tens of GB, in the ISO *and* copied to
   the target). But a config change never rebuilds nix/gcc — it only re-realizes
   the system's own assembly derivations (`/etc`, users/groups, activation,
   toplevel), which need the *outputs* of a small tool set, not a from-source
   build. So we switched to a curated `system.extraDependencies` = the runtime
   closures of `stdenv`, `perl`, `python3`, plus the tools an offline rebuild
   named explicitly (`bash`, `binutils`, `bison`, `bzip2`, `gnu-config` — the
   last supplies `config.guess`/`config.sub`; bash/binutils/bzip2 already sit in
   stdenv's closure and just dedup). A few GB, not 64.

   Second attempt — inject that set at *install time* via `extendModules` in the
   script — **broke even a no-change rebuild** (it tried to fetch the Python
   *source* tarball from python.org and failed offline). Root cause: the deps
   were injected only into what the installer built, not into the committed
   `/etc/nixos` config, so the installed toplevel diverged from the one the
   target re-evaluates. Every `nixos-rebuild` then saw a "new" system, rebuilt it
   from scratch, and reached the network — and the divergent closure would GC the
   extra deps on the first switch anyway. Fix: declare `system.extraDependencies`
   in the **committed target config** (`configs/flake/configuration.nix`), and
   have both `flake.nix` (`targetToplevel`) and the install script build the
   plain `…toplevel` with no injection. Now **installed == evaluated == baked**:
   a no-change rebuild is a true no-op, and the deps persist across rebuilds and
   GC. If a real config change later needs a tool outside the set, extend the
   list in `configuration.nix` (one place). The trade-off: the offline-rebuild
   dependency set is visible in the user's own config, which is the honest place
   for it — a system's ability to rebuild itself offline is a property it should
   declare, and a user who brings their own flake opts in by copying the block.

   Third attempt — still failed, and exposed that the list was built the wrong
   way. The names in the failure output (Python, bash, binutils, bison, bzip2,
   config.guess) are the *source tarballs* at the leaves of a from-source build
   cascade: with no substituters, ONE missing build-time store path makes Nix
   plan to compile that path's whole build closure from source, and the plan's
   download failures name those tarballs — not the missing path. Adding
   packages by those names was name-matching, not root-causing (the third
   failure listed the added packages right back). Two real gaps: (a)
   `system.extraDependencies` attaches paths to the toplevel *derivation*, but
   the ISO (`storeContents`) and `nixos-install --system` carry only the built
   *output*'s closure — whether the deps reach that output is a nixpkgs
   implementation detail. The observed behavior (no-op rebuild fine; any real
   change cascades to compiling the dep list itself from source) matches them
   never reaching the target: the new toplevel derivation's inputs — our own
   dep list — were absent. (b) `stdenvNoCC`, referenced by nearly every
   writeText/runCommand assembly derivation and retained by nothing else, was
   never in the list. Fix: declare the deps as the *content* of
   `/etc/nixos/offline-rebuild-deps` (`environment.etc`), making them
   references of the system closure by construction — provably baked,
   installed, and GC-rooted — and add `stdenvNoCC`. And stop tuning the list
   against ISO+VM cycles: `tools/test-offline-rebuild.sh` seeds the committed
   toplevel's closure into a throwaway chroot store (simulating a fresh
   install) and offline-rebuilds perturbed configs (password, timezone,
   bootloader option) against it — the same failure the target would hit after
   reboot, reproduced in seconds. The list is done when the probe is green;
   extend the probe's cases as new classes of config edit matter.

   The probe immediately earned its keep: password and timezone passed; the
   bootloader case (one-line `configurationLimit` change) failed with an
   **854-derivation** from-source plan. Anatomy: the systemd-boot install
   script is re-generated and *type-checked with mypy* when boot.loader.*
   options change; mypy's output is build-time-only, so it was absent. The
   plan then amplifies, because in nixpkgs *downloading a source tarball is
   itself a derivation that needs curl's output* (`fetchurl` runs curl) — so
   curl, libssh2, c-ares, CUnit, cmake … joined the plan, recursing into their
   own build tools. One missing ~100 MB tool output reads as "rebuild the
   world"; the cure is always the tool at the frontier (mypy), never the
   tarballs in the cascade. Added `mypy` to the dep list. Also hardened the
   probe twice over: `--builders ''` (the first run tried the dev machine's
   remote builder over ssh — the target has none, and a *reachable* builder
   would have silently masked the failure), and a fourth case toggling a
   baked service (`services.fstrim.enable`), the third leg of the contract.
   Expect the same pattern for other build-time checkers as configs grow
   (e.g. shellcheck behind writeShellApplication-based modules); the probe
   names the frontier tool — add that, re-run, done.

7. **Disabling sshd failed offline, with `Archive-Tar` in the plan.** A new
   failure *class*: the four green probe cases all perturb around a fixed
   package set, but `services.openssh.enable = false` removes `openssh` from
   `environment.systemPackages`, so **`system-path` itself rebuilds** — the
   one assembly derivation no earlier case had touched. Its post-build hook
   (`environment.extraSetup`) invokes three tools by absolute store path that
   the hook text alone references (the text lives in the derivation, not the
   built output, so nothing retains them): `install-info` from **plain
   `texinfo`** (the system carries `texinfoInteractive` — a *different*
   derivation), `update-mime-database` (**`shared-mime-info`**), and
   `update-desktop-database` (**`desktop-file-utils`**). And `/etc/dbus-1`
   embeds the system-path store path in its config, so it rebuilds in the
   same cone, running `xsltproc` (**`libxslt.bin`**) at build time. All four
   added to the dep list; probe gained a `sshd-disable` case.

   Anatomy of the `Archive-Tar` name, confirming the "never the tarballs"
   rule: `Archive-Tar-3.12.tar.gz.drv` is a *direct input of `perl`'s own
   derivation* (perl 5.42's nixpkgs packaging fetches vendored CPAN dists at
   build). Perl appearing in a plan therefore means the probed store lacked
   the dep-list perl itself — i.e. the tested system predated the
   `offline-rebuild-deps` file (`environment.defaultPackages` retains
   perl.out+man via system-path on a current install, and the dep file pins
   it besides). On a current base the sshd case plans the four tools above
   instead. Derivation-graph analysis (`nix-store -q --requisites` diff of
   the two toplevel .drvs + `nix why-depends`) found the frontier without an
   ISO+VM cycle; the probe remains the acceptance test.

8. **The re-baked ISO's target still failed the sshd toggle — two more
   frontier tools, plus a version-suffix divergence.** The on-target log (a
   490-derivation plan) first confirmed #7 landed: texinfo,
   shared-mime-info, desktop-file-utils and libxslt were all *absent* from
   the plan, i.e. present on the target. The plan's two real roots were
   **jq** (`bin` output — a direct input of every toplevel build, which
   pipes bootspec and systemd-generator-environment.json through it) and
   **lndir** (assembles the system-units / user-units / tmpfiles.d trees).
   The other ~480 derivations were those two tools' from-source build
   closures — the full stage0→mes→tinycc→gcc bootstrap — with `Archive-Tar`
   (a CPAN dist fetched by perl's own derivation) once again merely the
   noisiest name in the cascade. Both tools added to the dep list. Note the
   committed lock had been on the same nixpkgs rev all along: these deps were
   latent in the 26.11pre assembly layer, and every probe case (any of which
   rebuilds the toplevel, hence needs jq) would surface them on a re-run —
   the earlier green run predated the current tree/config combination.

   The log's second tell: the target built `…26.11.20260729.dirty`, not the
   baked `….9bc0289`. `pinNode` replaced each input's `locked` ref with
   `{type = "path"; path; narHash}` (+ `lastModified`) but dropped **`rev`**,
   and nixpkgs derives `system.nixos.versionSuffix` from `self.shortRev`
   with a `"dirty"` fallback. So the installed target always re-evaluated a
   *different* toplevel than the ISO baked — quietly violating
   installed == evaluated == baked (#6) and re-building the version-suffix
   cone on every rebuild, no-ops included (invisible while that cone was all
   cheap stdenvNoCC derivations; cone-inflating once it wasn't). Path-type
   locked refs accept `rev`/`revCount` (verified via fetchTree), so pinNode
   now carries them through. Takes effect on the next ISO build; an
   already-installed target keeps its rev-less lock and cannot grow the
   missing tool outputs offline — retest from a fresh install, not by
   editing the old VM.

9. **Round three: right package, wrong *output*.** A fresh install from the
   #8 ISO confirmed both #8 fixes (toplevel back to `….9bc0289`; lndir gone
   from the plan) yet the sshd toggle still planned 488 derivations, dying
   on the same tarball fetches. The refinement #8 missed: **Nix schedules a
   derivation when ANY wanted output is missing, and want-edges name
   outputs, not packages.** A reverse want-index over
   `nix derivation show -r <toplevel.drv>` showed exactly one unsatisfied
   edge leaving the change cone: `systemd-generator-environment.json.drv`
   wants `jq` **`[dev]`** — jq sits in its `nativeBuildInputs`, and nixpkgs
   resolves dependency-list entries of multi-output packages to their *dev*
   output (dev pulls bin back in at build time via nix-support
   propagation). The toplevel's own `jq [bin]` edge was already satisfied
   by the #8 pin, so jq was scheduled purely for `dev` — and one missing
   ~100 kB output again read as "rebuild the world" (fetchurl's dedicated
   curl builds against pre-final bootstrap stages, hence stage0→mes→tinycc→
   gcc in the plan). Fix: bake `jq.dev` alongside `lib.getBin jq`.

   Audit note: every other secondary-output want leaving the cone is a
   system-path *member* link (man/info/doc of member packages, via
   `environment.extraOutputsToLink`) — the previous system-path output
   links the same outputs, so they are always retained; their absence from
   the on-target plan confirms it. Rule refined: when the probe names a
   tool, read the wanted outputs off the edge
   (`nix derivation show <referrer>` → `inputs.drvs`), and remember that
   `nativeBuildInputs` means the dev output.

Still open (needs a clean install + reboot to confirm):

- **The offline resolution of Determinate's full input tree** — whether the
  baked, path-rewritten lock (`pinNode` in `flake.nix`) resolves under `--offline`
  for the FlakeHub `tarball` inputs and the `type = "file"` `determinate-nixd`
  binaries. Now exercised end-to-end through install + reboot + rebuild, but a
  targeted check of the `tarball`/`file` inputs specifically has not been isolated.
- **`determinate-nixd`'s background network behavior** when fully offline (no
  telemetry knob exists in 3.21.9; relying on it failing harmlessly).
- **`pkgs.fh` exists in nixpkgs 26.05** (else swap to a dedicated `fh` input).

Confirmed: the rebooted target boots into a working Determinate system and
rebuilds (no-op and `--flake`) succeed.

Structural note: the cleaner fix for #1/#2 would be to drop `pkgs.nix` from
`offlineInstaller`'s `runtimeInputs` so the script uses Determinate's client
(features on by default, client matches daemon). Deferred until a build can
confirm Determinate's `nix` is on the script's `PATH`; the script-level fixes
above are safe and client-agnostic in the meantime.
