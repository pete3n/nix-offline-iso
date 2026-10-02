#!/usr/bin/env bash
# test-drv-identity: the determinate-cli-offline bake must not plan any
# from-source Determinate Nix (or sentry-native) builds. Regression gate for
# a failure with two independent causes and one symptom:
#
#   1. Metadata-poor lock nodes (pins/overrides lacking rev/revCount/
#      lastModified) mint "dirty" nix-src version strings whose drvs no
#      cache serves.
#   2. Baking targetToplevel.drvPath demands EVERY output of the build
#      closure realized, including Determinate's unpublished
#      separateDebugInfo outputs (bakeBuildDependencies=false opts out).
#
# Either failure puts nix-src in the build plan, and its source build dies on
# sentry-native's git+submodules fetch (which a tarball-only cache proxy
# cannot serve). An empty plan match = drv identity intact AND the bake
# contract honored.
#
# Needs network: the dry-run evaluates the target's inputs, so run it where
# the build would run (with the same .env, if you build through a proxy).
# From the repo root:
#
#   tools/test-drv-identity.sh [extra build-iso.sh args...]
#
# Extra args pass through, e.g. a production target override:
#   tools/test-drv-identity.sh \
#     --override-input target-determinate-cli-offline 'path:/path/to/repo?dir=hosts/myhost'
set -euo pipefail
cd "$(dirname "$0")/.."

dry_log=$(mktemp "${TMPDIR:-/tmp}/drv-identity.XXXXXX.log")
trap 'rm -f "$dry_log"' EXIT

tools/build-iso.sh determinate-cli-offline \
  --option flake-registry '' --option http-connections 5 \
  --dry-run "$@" > "$dry_log" 2>&1 || {
  echo "FAIL: dry-run itself errored; tail of output:" >&2
  tail -20 "$dry_log" >&2
  exit 1
}

# Only the nix-src build family and sentry count: unit/config drvs with
# "-nix-" in the name (unit-nix-daemon.service, unit-determinate-nixd.socket,
# etc-nix-registry.json...) are trivial fresh-system builds, not drift.
offenders=$(awk '/will be built/{flag=1;next} /will be fetched|will be copied/{flag=0} flag' "$dry_log" \
  | grep -E 'sentry|determinate-nix-|nix-src' || true)

if [ -n "$offenders" ]; then
  echo "FAIL: the build plan wants to compile Determinate Nix / sentry from source:"
  echo "$offenders"
  echo
  echo "Triage: compare a planned determinate-nix drv against the running nix"
  echo "  (nix derivation show <drv> — a dirty/pre version = metadata-poor pins"
  echo "   or a metadata-dropping override; a clean version = an all-outputs"
  echo "   consumer, check bakeBuildDependencies wiring in nix/lib.nix)."
  exit 1
fi
echo "PASS: no nix-src / sentry builds in the determinate bake plan"
