# The proxied Determinate CLI installer bakes nothing and owns no URLs

For the `determinate-cli-proxied` product (decided on branch
`nixos-26.05-cli-determinate-proxy`, pre-flatten) the ISO is thin: no target
configuration, no baked target closure, no path-pinned lock. The Flake target
is cloned from a LAN Config repo at install time, and every URL that must
work on the filtered network — flake input URLs and the Target's substituter
— is authored in the Config repo itself. The installer only collects the
Cache URL (`proxy-setup`), gates on the Reachability probe, and warns on
divergences (Pin match, missing substituter declaration); it never rewrites
or injects anything into what it installs. The reason is the offline
contract's hardest-won lesson (ADR 0007, finding #6 — formerly ADR 0001 on
the determinate branch):
anything injected at install time makes the installed system diverge from
what the committed config evaluates to, and the divergence surfaces as
broken rebuilds after reboot. installed == evaluated == committed, so the
committed config must already be proxy-correct.

## Considered options

- **Bake-hybrid ISO** (config text + flake input sources baked, outputs via
  proxy): defeated by the flow itself — the Config repo lives its own life in
  LAN git, so baked sources go stale immediately, and it drags the parent's
  `pinNode` machinery back in.
- **FlakeHub Cache for Determinate's outputs**: login-gated (token via
  `determinate-nixd login`, paid plan), and the pinned module configures no
  substituter without it — a secret inside a throwaway live environment plus
  Authorization pass-through on the appliance. Rejected; the **Pin match**
  convention (Config repos pin `determinate` to the ISO's rev, whose outputs
  the live store already holds) covers the gap for free. See
  `docs/appliance-requirements.md`.
- **Install-time persistence injection** (the graphical sibling's
  `proxy-persist` transplanted): there is no generated config to append to
  here, and an imperative write to the Target's nix config is regenerated
  away at the first rebuild.
- **A Direct-install escape hatch**: Config repos authored for this fleet
  (appliance-addressed inputs, declared Cache-URL substituter) cannot install
  correctly without the appliance, so the mode would only serve configs this
  branch does not target. Dropped; the Cache proxy is required.

## Consequences

- The ISO is fleet-generic. All fleet-specific knowledge lives in Config
  repos and the appliance; the repo documents the Config-repo conventions
  instead of shipping an example (`configs/` is deleted).
- This product cannot install anything real until the appliance grows the
  Determinate routes tracked in `docs/appliance-requirements.md` (FlakeHub
  tarball routing shape still deferred there).
- A Config repo that drifts its `determinate` pin from the ISO's compiles
  Nix from source through the proxy — warned and allowed, never blocked.
