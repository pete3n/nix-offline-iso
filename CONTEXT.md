# NixOS Proxied-Install ISO (CLI, Determinate Nix)

Builds an ISO of a minimal, console-based NixOS installer for networks whose
only route to the internet is a filtering LAN cache appliance. Nothing is
baked into the ISO beyond the live environment itself: the user's flake
configuration is cloned from a LAN git repository at install time, and every
dependency of the installed system is pulled through the Cache proxy. This
branch (`nixos-26.05-cli-determinate-proxy`) ships Determinate Nix as the Nix
that runs on both the installer and the installed system.

## Language

**Cache proxy**:
The LAN appliance (a path-routed nginx reverse proxy, `nix-cache-proxy`) that
is the sole permitted route to cache.nixos.org, allow-listed cachix caches,
and allow-listed source tarballs. Direct internet is unreachable from client
machines.
_Avoid_: proxy server, forward proxy, mirror (it passes through and caches; it
does not host content of its own).

**Cache URL**:
The base URL at which the Installer reaches the Cache proxy
(e.g. `http://nix-proxy.lan`). It is a Nix substituter base URL — never an
`http_proxy`/`https_proxy` value; nothing in this project sets proxy
environment variables.
_Avoid_: proxy URL (invites the `http_proxy` misreading).

**Proxied install**:
An online install whose only network egress is the Cache proxy plus the LAN
itself (the Config repo): substitution is rerouted to the Cache URL, and
anything the Cache proxy does not allow-list is treated as unreachable.
_Avoid_: online install (true but underspecified), offline install (the
sibling branches' contract — zero network; this branch does not hold that
bar).

**Config repo**:
The LAN-hosted git repository (GitLab or a bare repository over SSH) holding
the user's flake configuration. The Installer clones it at install time; the
working copy — possibly edited on the spot — is what gets installed.
_Avoid_: baked config (nothing is baked into the ISO on this branch),
upstream (it is the user's own repository).

**Proxy setup**:
The step at the start of a Proxied install where the operator confirms or
replaces the prefilled Cache URL. It owns the Reachability probe and owns the
live Installer's substituters outright — they are empty until Proxy setup
declares the Cache URL (fail fast, never hang against a blackholed default) —
and it hands the URL to the install script, which does not proceed without
it.
_Avoid_: Proxy screen (the graphical sibling's term for the same step; there
is no screen here), proxy config (invites the `http_proxy` misreading).

**Reachability probe**:
Proxy setup's check that a Proxied install can proceed: fetch
`<Cache URL>/nix-cache-info` and expect a binary-cache answer.
_Avoid_: internet check (it checks the Cache proxy, not the internet).

**Installer**:
The live, throwaway environment booted from the ISO that runs `proxy-setup`
and `proxied-install`. Its Nix store, credentials, and settings exist only to
perform the install and are never carried onto the target.
_Avoid_: live CD, ISO (the ISO is the artifact; the installer is what it
boots into).

**Target**:
The system being installed onto the disk — the machine the user will actually
run. Its configuration comes from the Config repo.
_Avoid_: host, guest, machine.

**Flake target**:
The shape a user's Target configuration must take on this branch — a
`flake.nix` whose input URLs are reachable on the filtered network, and
which itself declares the Cache URL as the Target's substituter
(persistence is declared, never injected: the installed system must equal
what the committed config evaluates to). A committed `flake.lock` is the
convention, not a gate — locking at install time is just another fetch
through the Cache proxy. The channels shape (a plain `configuration.nix`
tracking a channel) is not supported here.

**Determinate Nix**:
Determinate Systems' alternate Nix distribution (patched daemon/binary plus the
`determinate-nixd` service). On this branch it replaces upstream Nix on both the
Installer and the Target, with its online features left as-shipped: what they
can reach is bounded by the filtered network, not by this ISO (the sibling
offline branches' "hard-neuter" idiom deliberately does not apply here).
_Avoid_: DetSys Nix, det-nix.

**Pin match**:
The convention that a Config repo pins `determinate` to the same rev the ISO
was built with. Determinate's nix outputs are not substitutable from any
anonymous cache, but the Installer's own store already holds them for the
ISO's rev — a matched pin therefore compiles nothing. Drift is allowed: the
Installer warns that a mismatched pin means compiling Nix from source through
the Cache proxy, and asks before proceeding.
_Avoid_: rev lock (nothing enforces it), version match (it is a rev, not a
version line).

**FlakeHub**:
Determinate Systems' hosted flake registry and binary cache (FlakeHub Cache).
The cache is login-gated and deliberately unused on this branch — Determinate's
nix outputs come from the Pin match instead.
