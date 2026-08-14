# Flake-ref install: build the Target straight from the bare Config repo

`proxied-install` gains a second way to consume the Config repo: an
explicit `--flake 'git+ssh://…'` reference to the LAN bare repository. No
working copy exists anywhere — the Installer builds the committed rev Nix
fetches over LAN git, and the Target keeps **no `/etc/nixos` checkout**:
its rebuilds address the Config repo by ref, through whatever access its
own configuration declares. The mode never engages implicitly (no
defaulting from a Builder prefill, no auto-detection); the operator types
the ref, or the fleet's own driver script does. The clone-and-edit flow
survives unchanged as the machine-zero path — the only place a
`hardware-configuration.nix` can be authored for a box the repo does not
know yet. See `docs/proxied/CONTEXT.md` for the term (**"Direct install"
was already taken** — it names the graphical product's install *without*
the Cache proxy, a near-opposite meaning).

The doctrinal payoff: ADR 0003's `installed == evaluated == committed`
becomes literal. A clone can be edited on the spot and never committed
back; a flake ref cannot — what installs is exactly a committed rev.

Mechanics this commits us to: the Pin-match and declared-substituter
preflights run against the ref (`nix flake metadata`/`nix eval` on the
URL) instead of local files; `nixos-generate-config` is skipped entirely —
the Config repo must already commit the host's hardware description (a
hardware configuration or disko layout), and the installer says so plainly
rather than failing obscurely; SSH auth reaches Nix's git fetcher via a
root `~/.ssh/config` Host entry, because the fetcher ignores
`GIT_SSH_COMMAND` — the one non-obvious mechanic the public docs must
state.

## Considered options

- **Auto-clone / auto-install from a baked repo-URL prefill**: a prefill
  that triggers an install path is more than a prefill; rejected to keep
  the Builder-prefill rule (ADR 0009) bright-line. The repo-URL variable
  was dropped from `.env` entirely — the fleet's stick owns the URL.
- **Replacing the clone flow**: cleanest doctrine, but machine-zero
  hardware authoring would have to happen off-box, sight-unseen. Rejected;
  the flows coexist.
- **Cloning into the Target after the ref build** (keeping the "installed
  system keeps it as its git origin" contract in both modes): rejected in
  favour of one clear contract per mode — a Flake-ref-installed box owns
  nothing locally and rebuilds by ref. Mixing the modes' Target states
  would have made every installed machine's contract ambiguous.
- **Baking the SSH identity (key + CA-signed cert) into the ISO** for a
  zero-step experience: contradicts the Provisioning key doctrine
  ("never in the ISO"), puts a credential through the world-readable
  store, and couples ISO rebuilds to cert renewal if the cert is
  short-lived. Rejected: the identity, the SSH config, the repo URL, and
  the fleet's install driver script all travel on the installing admin's
  stick; the script's system of record is the fleet's private repo.
- **A `--yes` flag for fleet automation**: the disko wipe and Pin-mismatch
  confirmations are exactly the gates the prefill rule protects. Rejected;
  a driver script stops at the prompt and the operator types one word.

## Consequences

- Two Target contracts coexist and both are deliberate: clone-mode boxes
  own their config at `/etc/nixos` (git origin intact); Flake-ref boxes
  have an **empty `/etc/nixos`** — a future reader finding one should
  land here, not "fix" it.
- A Flake-ref-installed Target can only rebuild if its own committed
  configuration declares access to the Config repo (key material,
  known-hosts) and the Cache URL substituter — the preflight warns on the
  latter, as it already did for clones.
- The Config repo must commit per-host hardware truth before a host can be
  Flake-ref-installed; there is no generate-and-merge escape. Fleets that
  want zero-touch machine-N installs get exactly the discipline that
  makes reinstalls reproducible.
