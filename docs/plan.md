# Implementation plan: nixos-26.05-cli-determinate-proxy

> Status (2026-08-01): phases 0–4 implemented and component-tested; the
> end-to-end install against the live appliance PASSED. Follow-up from that
> run: upstream clients warn on Determinate's generated settings
> (lazy-trees/eval-cores) — fixed by dropping pkgs.nix from the installer's
> runtimeInputs (Determinate's client matches the daemon); a residual
> warning from nixos-install's bundled upstream nix is cosmetic (README,
> Limitations). Still open: the on-target rebuild leg of the acceptance
> checklist, and recording the FlakeHub routing shape the appliance
> actually adopted (docs/appliance-requirements.md).

Language in `CONTEXT.md`; the shape decision in `docs/adr/0003`; appliance
prerequisites in `docs/appliance-requirements.md`. Flow being implemented
(MOTD order): boot → partition (manual / `--disk` / disko) → clone Config
repo to `/tmp/nix-cfg` → edit as needed → `proxy-setup` → `proxied-install`.

## Phase 0 — carve-down

Delete what the thin ISO no longer means: `configs/` (and the `target-flake`
input), `pinNode` and all target-closure baking (`storeContents` beyond the
live system), the offline-rebuild-deps wiring, the installer neuter block
(`substituters`/`nix.registry` `mkForce`s, `flake-registry` persist-drop),
`tools/test-offline-rebuild.sh`, and `docs/adr/0001` (it documents the
parent's machinery and stays on the parent branch).

Accept: ISO builds; boots to a Determinate live env; the image carries no
target closure.

## Phase 1 — live environment

- Live substituters empty by default (Proxy setup owns them; fail fast, no
  blackhole hangs). Not a guard: the Target's substituters come from its own
  config.
- Add the flow's tools: git, openssh client, an editor.
- MOTD rewritten around the six-step flow; no `determinate-nixd login`
  mention (FlakeHub is unreachable and unused here).
- Expose the ISO's `determinate` lock identity for Pin match — the locked
  URL and, decisively, the **narHash** (tarball lock nodes carry no git rev,
  and the URL may legitimately differ between appliance routing shapes while
  the content matches). E.g. a small `/etc/` file plus a MOTD line.

Accept: booted env has empty substituters, the tools present, the rev file
populated.

## Phase 2 — proxy-setup

Prompt confirming/replacing the prefilled Cache URL (`http://nix-proxy.lan`);
Reachability probe (`<url>/nix-cache-info`, expect a binary-cache answer);
on success declare the live substituters at the Determinate include point
(`/etc/nix/nix.custom.conf` is a store symlink on the ISO — same
replace-with-a-real-file dance the graphical sibling's rewrite does for
`nix.conf`, then let `determinate-nixd` re-assemble) and record the URL at
`/run/nix-cache-url` for the installer. No `--direct` mode: a failing probe
means no Proxied install.

Accept: after `proxy-setup`, a bare `nix store info --store <url>`-class
check and an ordinary substitution work; `/run/nix-cache-url` holds the URL.

## Phase 3 — proxied-install (rework of offline-install.sh)

Keep the skeleton: root check, tri-mode partitioning (`--disk` / disko /
pre-mounted), disko detection via full eval, host resolution with hostname
fallback, `nixos-generate-config` ESP-umask fix, `--no-channel-copy`,
build-then-`nixos-install --system`.

Change:
- Rename to `proxied-install`; refuse to run without `/run/nix-cache-url`
  (point at `proxy-setup`), with `--cache-url` as an explicit override.
- Config comes from `/tmp/nix-cfg` (or `--config PATH`); the `/iso/nix-cfg`
  fallback is gone. Flake target only.
- Drop every `--offline` flag; the exported `NIX_CONFIG` keeps the
  experimental-features line but sets `substituters = <Cache URL>` (was:
  empty) so every nix the script spawns — including what `nixos-install`
  runs — substitutes through the appliance regardless of client.
- Delete the path-pinned input-source `nix copy` step (the lock is not
  path-pinned; the Target refetches inputs through the appliance).
- Add the **Pin match** check: compare the cloned lock's `determinate`
  narHash against the ISO's; on mismatch warn "compiles Nix from source
  through the proxy (long build)" and ask to continue.
- Add the persistence check: from the eval the script already does, read the
  Target's `nix.settings.substituters`; warn when the entered Cache URL is
  absent (including the alias-vs-IP mismatch case) — first rebuild after
  reboot would not reach the proxy.

Accept: `tools/test-proxied-install.sh` green (phase 4); manual run against
a mock appliance completes the decision points in order.

## Phase 4 — tests and docs

- `tools/test-proxied-install.sh`: localhost mock appliance (static
  `/nix-cache-info` + tiny fixture content); assert probe gating, installer
  refusal without setup, Pin-match warning path, substituter-declaration
  warning path, URL handoff. Seconds, no VM.
- README rewrite: the six-step flow; Config-repo conventions (declared
  Cache-URL substituter, appliance-addressed input URLs — concrete form
  pending the routing-shape decision in `docs/appliance-requirements.md`,
  Pin match); limitations (appliance required, unfree/CUDA carried over,
  DNS name-form caveat).
- The real acceptance stays a documented manual checklist against the live
  appliance: full install → reboot → `nixos-rebuild switch` (no-op and a
  real change) through the proxy.
