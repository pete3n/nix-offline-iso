# Offline rebuilds: the dependency set the target must carry

The offline contract for an installed target: a CONFIG-ONLY change (a
password, a timezone, an option toggle, enabling a service whose package is
already baked) must `nixos-rebuild switch` with no network. A genuinely new
package or service is out of scope — its build inputs were never baked.

## Mechanism

Every config change re-runs the small "assembly" derivations (/etc,
users/groups, systemd units, activation scripts, system-path, the toplevel).
Their builders need TOOL OUTPUTS that a plain runtime closure does not carry.
The committed target config interpolates those tools into
`environment.etc."nixos/offline-rebuild-deps"` — an /etc file's content paths
are references of the system closure BY CONSTRUCTION, so they are baked into
the ISO, copied by nixos-install, and GC-rooted with the generation.

Rejected alternatives: `system.extraDependencies` (attaches the paths to the
toplevel *derivation*, which neither the ISO's `storeContents` nor
`nixos-install --system` carries — the deps never reached the target) and
`system.includeBuildDependencies` (bakes the recursive build-output closure;
tens of GB, overflowed a 64 GB disk).

The set must live in the committed config so that
**installed == evaluated == baked**. Inject it at install time instead and
the target re-evaluates a *different* toplevel: every rebuild — no-ops
included — rebuilds from scratch, and the diverged deps are GC'd on the
first switch.

## Diagnosis rules (each learned from a real failure)

1. With no substituters, ONE missing build-time output makes Nix plan that
   path's whole build closure from source, and the failure output names the
   source tarballs at the leaves (`Archive-Tar`, gcc, mes, tinycc...), never
   the missing tool. The cure is always the tool at the frontier, never the
   tarballs in the cascade.
2. Nix schedules a derivation when ANY WANTED OUTPUT is missing. Read the
   wanted outputs off the edge (`nix derivation show <referrer>` →
   `.inputs.drvs`), not just the package name. Dependency lists
   (`nativeBuildInputs`) resolve multi-output packages to their `dev` output
   — which is why the list pins jq's `bin` (toplevel/bootspec) AND `dev`
   (systemd-generator-environment.json).
3. system-path links its member packages' man/info/doc outputs
   (`environment.extraOutputsToLink`), and the previous generation's
   system-path retains those same links — so member outputs are always
   present. Only NON-member build tools need pinning: the post-build hook's
   plain texinfo / shared-mime-info / desktop-file-utils, buildEnv's perl,
   the dbus config's xsltproc (libxslt.bin), lndir (unit/tmpfiles trees),
   jq, and mypy (systemd-boot script re-generation + type-check on any
   boot.loader.* change).
4. `pinNode` (flake.nix) must carry `rev`/`revCount` into the path-repinned
   lock: nixpkgs derives `system.nixos.versionSuffix` from `self.shortRev`
   with a `"dirty"` fallback, and a suffix mismatch silently violates
   installed == evaluated == baked (the whole version-suffix cone rebuilds
   on every switch).

## Workflow

Tune the list ONLY with `tools/test-offline-rebuild.sh` (seconds per
iteration): it seeds the committed system's closure into a throwaway chroot
store and offline-rebuilds perturbed configs against it — the same failure
the target would hit after reboot. The probe is the acceptance test; extend
its cases when a new class of config edit matters. The current list was
converged on nixpkgs 26.11pre (9bc0289); a different pin may need additions
— the probe names them.

---
Distilled from the determinate line's ADR (now ADR 0007; formerly its own 0001)
verification notes (findings 6–9), where this contract was developed and
validated end-to-end (install → reboot → offline `nixos-rebuild switch`,
including the sshd-disable case).
