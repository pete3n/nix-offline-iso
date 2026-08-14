#!/usr/bin/env bash
# build-iso: build an installer ISO, applying .env variables.
#
# Usage: tools/build-iso.sh <variant> [extra `nix build` args...]
#
# With no .env at the repo root, this is the same as running:
# `nix build .#installer-iso-<variant>`: pure evaluation, with defaults.
#
# With a .env it reads the file IN A CLEAN ENVIRONMENT, validates known values,
# and build with with the --impure switch, so that nix/lib.nix's builderPrefills
# allow-list can read them:
#
#   ISO_CACHE_URL       Builder prefill for the proxied variants' cache URL.
#   ISO_INPUT_OVERRIDES Space-separated input=url pairs, each handed to
#                       --override-input. NOTE: an override REPLACES the
#                       input's lock entry — append ?narHash=<the lock's
#                       hash> to the URL to keep the content pinned; this
#                       script warns when an override is not pinned.
#
# See .env.example for the documented keys. Only variables read by
# builderPrefills (or turned into flags here) can influence the build.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

usage() {
  cat <<EOF
Usage: tools/build-iso.sh <variant> [extra \`nix build\` args...]

Products (installer-iso-<variant> in flake.nix):
  nixos-cli-offline              nixos-cli-offline-channels
  nixos-graphical-offline        nixos-graphical-offline-channels
  determinate-cli-offline
  determinate-cli-proxied
  nixos-graphical-proxied

Reads the gitignored .env at the repo root (see .env.example); without one
this is a plain, pure \`nix build\` of the tracked defaults.
EOF
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 1
fi
case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
esac

variant="$1"
shift
# Accept either the short product name or the full attribute name.
attr="installer-iso-${variant#installer-iso-}"

nix_args=()

if [ -r "$repo/.env" ]; then
  # Read .env in a scrubbed environment so a stray ISO_* exported in the
  # builder's shell can never masquerade as (or leak alongside) the file's
  # values. .env must be static KEY=VALUE lines. It cannot reference shell 
	# variables. The two known keys come back one per line.
	# shellcheck disable=2016
  mapfile -t env_values < <(env -i PATH="$PATH" bash -c '
    set -a
    . "$1"
    set +a
    printf "%s\n%s\n" "${ISO_CACHE_URL:-}" "${ISO_INPUT_OVERRIDES:-}"
  ' _ "$repo/.env")
  iso_cache_url="${env_values[0]:-}"
  iso_input_overrides="${env_values[1]:-}"

  # Export exactly what .env declared for nix's --impure getEnv. An unset key 
	# is unset for the build too, even if the ambient shell exported it.
  if [ -n "$iso_cache_url" ]; then
    export ISO_CACHE_URL="$iso_cache_url"
  else
    unset ISO_CACHE_URL
  fi
  unset ISO_INPUT_OVERRIDES

  # The same shape check proxy-setup and builderPrefills apply. 
	# Fail early for invalid values.
  if [ -n "$iso_cache_url" ]; then
    if ! printf '%s' "$iso_cache_url" | grep -Eq '^https?://[A-Za-z0-9.:/_-]+$'; then
      echo "build-iso: ISO_CACHE_URL is not a usable Cache URL: $iso_cache_url" >&2
      echo "Expected http(s)://host[:port][/path] with no spaces or quotes." >&2
      exit 1
    fi
    echo ">> .env: ISO_CACHE_URL=$iso_cache_url (Builder prefill)"
  fi

  if [ -n "$iso_input_overrides" ]; then
    read -r -a override_pairs <<< "$iso_input_overrides"
    for override_pair in "${override_pairs[@]}"; do
      input_name="${override_pair%%=*}"
      input_url="${override_pair#*=}"
      if [ -z "$input_name" ] || [ "$input_name" = "$override_pair" ] || [ -z "$input_url" ]; then
        echo "build-iso: ISO_INPUT_OVERRIDES entry is not input=url: $override_pair" >&2
        exit 1
      fi
      if printf '%s' "$input_url" | grep -q 'narHash='; then
        echo ">> .env: override input '$input_name' -> $input_url (content-pinned)"
      else
        echo ">> .env: override input '$input_name' -> $input_url"
        echo "   WARNING: no ?narHash= on this URL, the override REPLACES the"
        echo "   lock entry, so the build takes whatever this route serves."
        echo "   Append ?narHash=<the lock's hash> to pin it (see .env.example)."
      fi
      nix_args+=(--override-input "$input_name" "$input_url")
    done
  fi

  # --impure is what lets builderPrefills (nix/lib.nix) see the exported
  # values. Without a .env the build stays pure, so nothing in the ambient
  # environment can influence a default build either way.
  nix_args+=(--impure)
else
  echo ">> no .env: pure build of the tracked defaults"
fi

echo ">> nix build $repo#$attr"
exec nix build "$repo#$attr" "${nix_args[@]}" "$@"
