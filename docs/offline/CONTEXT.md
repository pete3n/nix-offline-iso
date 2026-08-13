# Offline contract

The glossary for the **offline** products (`nixos-cli-offline`,
`nixos-graphical-offline`, `determinate-cli-offline`): installers that
install a user-provided system configuration with **no network connection**,
by carrying every dependency in the ISO's Nix store. Repo-wide language —
the product matrix and its axes — lives in
[`CONTEXT-MAP.md`](../../CONTEXT-MAP.md); the opposing contract's glossary in
[`docs/proxied/CONTEXT.md`](../proxied/CONTEXT.md).

## Language

**Offline install**:
An install performed with zero network access, where every required store path
is already baked into the ISO. The stronger sense — "zero network *attempts* by
construction", not merely "works despite failed probes" — is the bar this
project holds itself to.
_Avoid_: air-gapped (implies a security posture we don't claim), "works offline"
(ambiguous about whether it probes).

**Installer**:
The live, throwaway environment booted from the ISO that runs `offline-install`.
Its Nix store, credentials, and settings exist only to perform the install and
are never carried onto the target.
_Avoid_: live CD, ISO (the ISO is the artifact; the installer is what it boots into).

**Target**:
The system being installed onto the disk — the machine the user will actually
run. Its configuration is user-provided (the variant's `configs/`).
_Avoid_: host, guest, machine.

**Flake target** / **Channels target**:
The two shapes a user's Target configuration can take — a `flake.nix` (with a
committed `flake.lock`) or a plain `configuration.nix` tracking a channel.
The `nixos-*-offline` products support both; `determinate-cli-offline` is
flake target only.

**Determinate Nix** _(determinate products)_:
Determinate Systems' alternate Nix distribution (patched daemon/binary plus the
`determinate-nixd` service). On `determinate-cli-offline` it replaces upstream
Nix on both the Installer and the Target. Only its offline-compatible core is
used.
_Avoid_: DetSys Nix, det-nix.

**Hard-neuter** _(determinate products)_:
The offline contract's stance toward Determinate's online features: explicitly
strip the FlakeHub Cache substituter and disable `determinate-nixd`'s network
reach (login, telemetry, status probes) so the Offline install makes no network
attempts and cannot stall on a probe timeout. The improved Nix daemon/binary is
kept; FlakeHub Cache, `determinate-nixd login`, and telemetry are shed.

**FlakeHub**:
Determinate Systems' hosted flake registry and binary cache. Relevant only
*after* install once the Target has network; it is deliberately unused during
the Offline install.
