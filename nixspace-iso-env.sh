#!/usr/bin/env bash
# nixspace-iso-env: generate the .env for LAN ISO builds from flake.lock.
#
# Run from the nix-offline-iso repo root after any lock change:
#
#   ./nixspace-iso-env.sh > .env
#   tools/build-iso.sh determinate-cli-proxied
#
# How the values are derived (the whole calculation):
#
#   1. Inputs whose locked URLs point at external hosts (api.flakehub.com). 
#   	 Currently: nixpkgs and determinate. The path: target inputs are local; 
#   	 add any future remote inputs here.
#
#   2. .nodes.<input>.locked.narHash is the identity nix recorded when the input 
#      was first locked on a networked machine. --override-input replaces a lock 
#      entry, so the narHash must be included in the URL or the build takes 
#      whatever the route serves.
#
#   3. Replace the base URL with the Nginx proxy server path:
#        nixpkgs     -> /github/NixOS/nixpkgs/tar.gz/<locked .rev>
#                       (codeload route; FlakeHub's NixOS/nixpkgs releases
#                       are republished plain github commits, so the rev's
#                       tree — and therefore the narHash — is identical)
#        determinate -> /flakehub/f/DeterminateSystems/determinate/<ver>.tar.gz
#                       (same upstream the lock recorded, path-routed; the
#                       exact version is parsed out of the locked URL)
#      A wrong route choice cannot build the wrong thing: the narHash check
#      fails the fetch loudly instead.
#
#   4. The hash rides in a URL query string, and base64's
#      + / = are URI-reserved characters — jq's @uri percent-encodes them
#      (+ -> %2B, / -> %2F, = -> %3D).
set -euo pipefail

lock="${1:-flake.lock}"
if [ ! -r "$lock" ]; then
  echo "usage: $0 [path/to/flake.lock]  (default: ./flake.lock)" >&2
  exit 1
fi

jq -r '
  .nodes.nixpkgs.locked as $np
  | .nodes.determinate.locked as $det
  | ($det.url | capture("/determinate/(?<version>[^/]+)/").version) as $ver
  | "ISO_CACHE_URL=http://nix-cache.nxs.lan\n"
  + "ISO_INPUT_OVERRIDES=\""
  + "nixpkgs=tarball+http://nix-cache.nxs.lan/github/NixOS/nixpkgs/tar.gz/\($np.rev)?narHash=\($np.narHash | @uri)"
  + " determinate=tarball+http://nix-cache.nxs.lan/flakehub/f/DeterminateSystems/determinate/\($ver).tar.gz?narHash=\($det.narHash | @uri)"
  + "\""
' "$lock"
