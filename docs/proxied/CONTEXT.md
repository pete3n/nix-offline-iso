# Proxied contract

The glossary for the **proxied** products (`determinate-cli-proxied`,
`nixos-graphical-proxied`): installs on networks whose only route to the
internet is a filtering LAN cache appliance. Nothing is baked into the ISO
beyond the live environment. Repo-wide language (the product matrix) lives in
[`CONTEXT-MAP.md`](../../CONTEXT-MAP.md); the opposing contract's glossary in
[`docs/offline/CONTEXT.md`](../offline/CONTEXT.md).

## Language

**Cache proxy**:
The LAN appliance (a path-routed nginx reverse proxy) that is the sole
permitted route to cache.nixos.org, allow-listed cachix caches, and
allow-listed source tarballs. Direct internet is unreachable from client
machines.
_Avoid_: proxy server, forward proxy, mirror (it passes through and caches; it
does not host content of its own).

**Cache URL**:
The base URL at which the Installer reaches the Cache proxy (e.g.
`http://nix-proxy.lan`). It is a Nix substituter base URL — never an
`http_proxy`/`https_proxy` value; nothing in this project sets proxy
environment variables. Under the codeload input routing (ADR 0004) this host
string is also baked into Config repos' input URLs and locks, so pick a
stable DNS name that outlives the appliance's address.
_Avoid_: proxy URL (invites the `http_proxy` misreading), raw-IP URLs in
committed configs (renumbering would invalidate every lock).

**Proxied install**:
An online install whose only network egress is the Cache proxy plus the LAN
itself (the Config repo): substitution is rerouted to the Cache URL, and
anything the Cache proxy does not allow-list is treated as unreachable.
_Avoid_: online install (true but underspecified), offline install (the
offline contract's zero-network bar; the proxied products do not hold it).

**Config repo** _(cli)_:
The LAN-hosted git repository holding the user's flake configuration —
typically a bare repository reached over SSH with authorized-key login only.
Deliberately *not* hosted on the Cache proxy: the appliance is
internet-facing, and a config inventory does not belong on the box with the
largest attack surface. The Installer consumes it one of two ways: cloned at
install time using the Provisioning key (the working copy — possibly edited
on the spot — is what gets installed, and the installed system keeps it as
its git origin), or as a Flake-ref install (the committed rev is what gets
installed; nothing is cloned anywhere).
_Avoid_: baked config (nothing is baked on this contract), upstream (it is
the user's own repository), USB config (a `--config` escape hatch for
machine-zero, never the primary path).

**Provisioning key** _(cli)_:
The passphrase-protected SSH private key (with its CA-signed certificate,
where the fleet issues one) that authenticates the Installer's fetch of the
Config repo — clone and Flake-ref install alike. It travels on the
installing admin's own USB stick
— never in the ISO: a credential baked into a mass-copied artifact would
break the bakes-nothing contract (ADR 0003) and be only as private as the
least-controlled stick in the building. Its public half is authorized on the
git host pinned to read-only fetch (`restrict,command="git-upload-pack …"`).
_Avoid_: deploy key (the GitLab concept this may later become), shared admin
key (it grants one repo's fetch, not admin access).

**Proxy setup** _(cli)_ / **Proxy screen** _(graphical)_:
The step at the start of a Proxied install where the operator confirms or
replaces the prefilled Cache URL — a console script (`proxy-setup`) on the
CLI product, a pre-Calamares dialog on the graphical one. It owns the
Reachability probe and the live Installer's substituters outright — empty
until the Cache URL is declared (fail fast, never hang against a blackholed
default).
_Avoid_: cross-applying the names (there is no screen on the CLI product and
no script step on the graphical one), proxy config/proxy dialog (invite the
`http_proxy` misreading and the wrong mechanism).

**Reachability probe**:
The check that a Proxied install can proceed: fetch
`<Cache URL>/nix-cache-info` and expect a binary-cache answer. Replaces the
stock installer's startup internet requirement, which runs before any screen
could collect the Cache URL.
_Avoid_: internet check (it checks the Cache proxy, not the internet).

**Flake-ref install** _(cli)_:
A Proxied install performed straight from a flake reference to the Config
repo (`git+ssh://…`): no working copy exists anywhere — the Installer
builds the committed rev it fetches over LAN git, and the Target keeps no
`/etc/nixos` checkout; its rebuilds address the Config repo by ref through
whatever access its own configuration declares. Engaged only by an explicit
flag, never by default. Requires the Config repo to already commit the
host's hardware description (a hardware configuration or disko layout) —
there is no generate-and-merge step in this mode.
_Avoid_: direct install (the graphical product's no-proxy escape hatch — a
near-opposite meaning), remote install (nothing is remote; the repo is on
the LAN).

**Direct install** _(graphical)_:
An install performed without the Cache proxy — the Proxy screen's escape
hatch, with stock network semantics. Nothing is rerouted and nothing is
persisted into the Target. The CLI product has no equivalent: its Config
repos cannot install correctly without the appliance (ADR 0003).
_Avoid_: offline install (a Direct install still requires the internet),
normal/default install (the Proxied install is the primary path).

**Installer**:
The live, throwaway environment booted from the ISO. Its Nix store,
credentials, and settings exist only to perform the install and are never
carried onto the target.
_Avoid_: live CD, ISO (the ISO is the artifact; the installer is what it
boots into).

**Target**:
The system being installed onto the disk — the machine the user will actually
run. On the CLI product its configuration comes from the Config repo; on the
graphical product from the stock Calamares flow.
_Avoid_: host, guest, machine.

**Flake target** _(cli)_:
The shape a user's Target configuration must take — a `flake.nix` whose input
URLs are reachable on the filtered network, and which itself declares the
Cache URL as the Target's substituter (persistence is declared, never
injected: the installed system must equal what the committed config evaluates
to). A committed `flake.lock` is the convention, not a gate. The channels
shape is not supported on this contract.

**Determinate Nix** _(determinate products)_:
Determinate Systems' alternate Nix distribution (patched daemon/binary plus
the `determinate-nixd` service). On the proxied contract it replaces upstream
Nix on both the Installer and the Target **with its online features left
as-shipped**: what they can reach is bounded by the filtered network, not by
this ISO (the offline contract's "hard-neuter" idiom deliberately does not
apply here).
_Avoid_: DetSys Nix, det-nix.

**Pin match** _(determinate products)_:
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
The cache is login-gated and deliberately unused on this contract —
Determinate's nix outputs come from the Pin match instead.
