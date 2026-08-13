# The Proxy screen is a pre-Calamares dialog, not a Calamares viewstep

The Proxied install needs a screen at the start of the flow that collects the
Cache URL and gates on the Reachability probe. We implement it as a small
GTK dialog run by a wrapper around the Calamares autostart, which then execs
Calamares — not as a page inside the Calamares wizard.

A reasonable reader will assume a wizard page was the obvious choice. It
wasn't available cheaply: in Calamares 3.4.2 Python modules are job-only (no
UI), the QML viewsteps came out of the Qt6 port unreliable, and a real
viewstep therefore means a compiled C++/Qt plugin — a new compiled package
(out-of-tree against Calamares' CMake exports, or patched in-tree with a
Calamares rebuild) plus VM-bound iteration, days instead of hours. The
feature was scoped as a small modification, so we chose the dialog.

## Consequences

- The screen appears as its own window before the wizard and cannot be
  revisited once Calamares starts; styling does not match the wizard.
- All plumbing is front-end-agnostic on purpose: the probe, the
  `welcome.conf` internet-requirement drop, the live-environment substituter
  rewrite, and the handoff to the `nixos` job module do not care what
  collected the URL. A C++ viewstep can replace the dialog later without
  touching any of it.
