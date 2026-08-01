# NixOS Proxied-Install ISO

Builds an ISO of the stock graphical (Calamares) NixOS installer, modified so
the install works on networks whose only route to the internet is a
filtering LAN cache appliance. This branch (`nixos-26.05-graphical-proxy`)
keeps the full online install flow — nothing is baked into the ISO beyond the
stock image.

## Language

**Cache proxy**:
The LAN appliance (a path-routed nginx reverse proxy, `nix-cache-proxy`) that
is the sole permitted route to cache.nixos.org, allow-listed cachix caches,
and allow-listed GitHub source tarballs. Direct internet is unreachable from
client machines.
_Avoid_: proxy server, forward proxy, mirror (it passes through and caches; it
does not host content of its own).

**Cache URL**:
The base URL at which the Installer reaches the Cache proxy
(e.g. `http://nix-proxy.lan`). It is a Nix substituter base URL — never an
`http_proxy`/`https_proxy` value; nothing in this project sets proxy
environment variables.
_Avoid_: proxy URL (invites the `http_proxy` misreading).

**Proxied install**:
An online install whose only network egress is the Cache proxy: substitution
is rerouted to the Cache URL, and anything the Cache proxy does not allow-list
is treated as unreachable.
_Avoid_: online install (true but underspecified), offline install (the
sibling branches' contract — zero network; this branch does not hold that bar).

**Proxy screen**:
The screen shown at the start of a Proxied install where the operator
confirms or replaces the prefilled Cache URL. It owns the Reachability probe;
the stock internet requirement is dropped in its favor.
_Avoid_: proxy dialog, network page (the canonical term stays the same even
though the current implementation is a pre-Calamares dialog).

**Reachability probe**:
The Proxy screen's own check that a Proxied install can proceed: fetch
`<Cache URL>/nix-cache-info` and expect a binary-cache answer. Replaces the
stock installer's startup internet requirement, which runs before any screen
can collect input and cannot know the Cache URL.
_Avoid_: internet check (checks the Cache proxy, not the internet).

**Direct install**:
An install performed by this ISO without the Cache proxy — the Proxy screen's
escape hatch. Stock network semantics; the Reachability probe targets
cache.nixos.org itself. Nothing is rerouted and nothing is persisted into the
Target.
_Avoid_: offline install (a Direct install still requires the internet),
normal/default install (on this ISO the Proxied install is the primary path).

**Installer**:
The live, throwaway environment booted from the ISO that runs Calamares. Its
settings (including the Cache URL) exist to perform the install.
_Avoid_: live CD, ISO (the ISO is the artifact; the installer is what it
boots into).

**Target**:
The system being installed onto the disk — the machine the user will actually
run. Configured by the stock Calamares flow (users, desktop, partitioning),
not by a baked-in configuration.
_Avoid_: host, guest, machine.
