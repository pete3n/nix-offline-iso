#!/usr/bin/env bash
# test-all.sh — run every harness in this repo in one shot, so a release
# gate cannot silently miss one. A suite that cannot run in the current
# environment (no network, no sibling checkout) is reported as SKIP rather
# than dropped, so the summary always accounts for every suite.
#
# Usage: tools/test-all.sh [--no-network] [--calamares-src PATH] [--ncache PATH]
#
#   --no-network        Skip the offline-rebuild probes. They prove offline
#                       REBUILDS, but on a cold nix store their setup step
#                       must first fetch the variants' pinned inputs, which
#                       needs network (a store warmed by a prior run or ISO
#                       build works offline).
#   --calamares-src P   calamares-nixos-extensions source tree for
#                       test-overlay.sh. Default: the sibling checkout
#                       ../calamares-nixos-extensions/src, if present.
#   --ncache P          Also probe an appliance checkout (ships its own
#                       offline-rebuild-cases.sh) with test-offline-rebuild.sh.
#
# Not covered here, by design: `nix build` of the ISO outputs and the VM
# install matrix — those are release-gate steps, not harnesses.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(dirname "$script_dir")

allow_network=1
calamares_src=""
ncache_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-network)
      allow_network=0
      shift
      ;;
    --calamares-src)
      calamares_src="${2:?--calamares-src needs a path}"
      shift 2
      ;;
    --ncache)
      ncache_dir="${2:?--ncache needs a path}"
      shift 2
      ;;
    -h|--help)
      # The comment block up top is the usage text; print it instead of
      # maintaining a second copy.
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1 (see --help)" >&2
      exit 2
      ;;
  esac
done

# Default to the sibling checkout this repo is developed against; test-overlay
# needs its src/ layout (modules/, config/, branding/).
if [ -z "$calamares_src" ] && [ -d "$repo_root/../calamares-nixos-extensions/src/modules" ]; then
  calamares_src="$repo_root/../calamares-nixos-extensions/src"
fi

suite_names=()
suite_results=()
suite_details=()

run_suite() {
  suite_name="$1"
  shift
  echo
  echo "════ $suite_name: $* ════"
  if "$@"; then
    suite_result="PASS"
    suite_detail=""
  else
    # Capture the status before anything else runs and resets $?.
    suite_detail="(exit $?)"
    suite_result="FAIL"
  fi
  suite_names+=("$suite_name")
  suite_results+=("$suite_result")
  suite_details+=("$suite_detail")
}

skip_suite() {
  suite_name="$1"
  skip_reason="$2"
  suite_names+=("$suite_name")
  suite_results+=("SKIP")
  suite_details+=("$skip_reason")
}

# ── Logic harnesses: fully local, loopback at most, no nix store writes ──
run_suite "offline-install-args" "$script_dir/test-offline-install-args.sh"
run_suite "proxy-screen"         "$script_dir/test-proxy-screen.sh"
run_suite "proxied-install"      "$script_dir/test-proxied-install.sh"

if [ -n "$calamares_src" ]; then
  run_suite "overlay" "$script_dir/test-overlay.sh" "$calamares_src"
else
  skip_suite "overlay" "no calamares-nixos-extensions checkout found; pass --calamares-src"
fi

# ── Offline-rebuild probes: one per variant that bakes a target flake ──
# The channels-shaped configs and the proxied variants have no probe: the
# former are not flakes, the latter deliberately bake no target (ADR 0003).
offline_flake_variants="determinate-cli-offline nixos-cli-offline nixos-graphical-offline"
for variant in $offline_flake_variants; do
  if [ "$allow_network" -eq 1 ]; then
    run_suite "offline-rebuild:$variant" \
      "$script_dir/test-offline-rebuild.sh" "$repo_root/variants/$variant/configs/flake"
  else
    skip_suite "offline-rebuild:$variant" "--no-network"
  fi
done

if [ -n "$ncache_dir" ]; then
  if [ "$allow_network" -eq 1 ]; then
    run_suite "offline-rebuild:ncache" "$script_dir/test-offline-rebuild.sh" "$ncache_dir"
  else
    skip_suite "offline-rebuild:ncache" "--no-network"
  fi
fi

# ── Summary ──
echo
echo "════ Summary ════"
overall=0
suite_index=0
for suite_name in "${suite_names[@]}"; do
  result="${suite_results[$suite_index]}"
  detail="${suite_details[$suite_index]}"
  printf '%-32s %s %s\n' "$suite_name" "$result" "$detail"
  if [ "$result" = "FAIL" ]; then
    overall=1
  fi
  suite_index=$((suite_index + 1))
done
if [ "$overall" -eq 0 ]; then
  echo ">> All run suites passed."
else
  echo ">> FAILURES above." >&2
fi
exit "$overall"
