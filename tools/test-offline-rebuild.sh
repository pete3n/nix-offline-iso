#!/usr/bin/env bash
# test-offline-rebuild.sh — regression test for the offline-rebuild contract:
# "a config-only change rebuilds on the installed target with no network".
#
# How it works: build the committed system (exactly what the ISO bakes), seed
# its closure into a throwaway chroot store (exactly what nixos-install copies
# onto the target), then rebuild perturbed copies of the config against that
# store with --offline. A FAIL here is the same failure the real target would
# hit after reboot — caught in seconds, without an ISO build + VM cycle.
#
# Covers both target types of this branch:
#   flake:    configs/flake     nix build path:...#nixosConfigurations...
#   channels: configs/channels  nix-build '<nixpkgs/nixos>' -A system, pinned
#             to the builder flake's locked nixpkgs. The channels base is
#             built the same way its probe rebuilds are, so the perturbation
#             cone — the thing the dep list must cover — is exercised
#             faithfully, even though version-suffix plumbing differs slightly
#             from the flake-evaluated toplevel the ISO bakes.
#
# Run on the build machine (needs network for the initial base builds, and jq).
#
# Usage: tools/test-offline-rebuild.sh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
flake_dir="$repo_root/configs/flake"
channels_dir="$repo_root/configs/channels"
flake_attr='nixosConfigurations.nixos.config.system.build.toplevel'

work=$(mktemp -d "${TMPDIR:-/tmp}/offline-rebuild-probe.XXXXXX")
cfg_dir="$work/cfg"
keep_logs=0
cleanup() {
  if [ "$keep_logs" -eq 1 ]; then
    echo ">> Probe workdir kept for inspection: $work"
  else
    chmod -R u+w "$work" 2>/dev/null || true
    rm -rf "$work"
  fi
}
trap cleanup EXIT

overall=0

# Each case is a sed program applied to a fresh copy of a committed config —
# a stand-in for "the user edits configuration.nix on the installed system".
# $1 case label, $2 source config dir, $3 sed program; remaining args are the
# offline build command, which references the perturbed copy in $cfg_dir.
run_case() {
  local case_name=$1 src_dir=$2 sed_prog=$3
  shift 3
  rm -rf "$cfg_dir"
  cp -r "$src_dir" "$cfg_dir"
  chmod -R u+w "$cfg_dir"
  sed -i "$sed_prog" "$cfg_dir/configuration.nix"
  echo ">> [$case_name] offline rebuild against the simulated target store"
  local log="$work/$case_name.log"
  if "$@" >"$log" 2>&1; then
    echo "   PASS"
  else
    echo "   FAIL — the installed target would hit this after reboot:"
    grep -E "will be built|will be fetched|cannot build|unable to|error" "$log" \
      | head -30 | sed 's/^/   | /'
    echo "   full log: $log"
    keep_logs=1
    overall=1
  fi
}

# The five config-change classes of the offline contract. sshd-disable is the
# only one that changes systemPackages *membership*, which rebuilds system-path
# itself (and the dbus config that embeds it) — it has caught the most, keep it.
all_cases() {
  local src_dir=$1 prefix=$2
  shift 2
  run_case "$prefix-password" "$src_dir" 's/initialPassword = "test"/initialPassword = "offline-probe"/' "$@"
  run_case "$prefix-timezone" "$src_dir" 's|time.timeZone = "America/New_York"|time.timeZone = "America/Chicago"|' "$@"
  run_case "$prefix-bootloader" "$src_dir" 's|boot.loader.systemd-boot.enable = true;|boot.loader.systemd-boot.enable = true;\n  boot.loader.systemd-boot.configurationLimit = 7;|' "$@"
  # Toggling a service whose package is already in the closure (fstrim ships in
  # util-linux) — the "enable a baked service" leg of the contract.
  run_case "$prefix-service" "$src_dir" 's|networking.networkmanager.enable = true;|networking.networkmanager.enable = true;\n  services.fstrim.enable = true;|' "$@"
  # The sed targets the four-space-indented `enable = true;` in services.openssh.
  run_case "$prefix-sshd-disable" "$src_dir" 's|^    enable = true;|    enable = false;|' "$@"
}

# ---- flake target ------------------------------------------------------------
if [ -e "$flake_dir/flake.nix" ]; then
  echo ">> [flake] building the committed toplevel (what the ISO bakes)"
  flake_top=$(nix build --no-link --print-out-paths "path:$flake_dir#$flake_attr")
  echo "   $flake_top"
  echo ">> [flake] seeding a simulated target store (what nixos-install copies)"
  flake_store="$work/store-flake"
  nix copy --no-check-sigs --to "local?root=$flake_store" "$flake_top"
  echo "   simulated target store size: $(du -sh "$flake_store/nix/store" | cut -f1)"
  # --builders '': the target has no remote builders, so the probe must not use
  # the dev machine's either — a reachable builder would realize the missing
  # paths remotely and mask a real on-target failure.
  all_cases "$flake_dir" flake \
    nix build --store "local?root=$flake_store" --offline --no-link \
      --builders '' "path:$cfg_dir#$flake_attr"
fi

# ---- channels target ----------------------------------------------------------
if [ -e "$channels_dir/configuration.nix" ]; then
  echo ">> [channels] resolving the builder flake's pinned nixpkgs"
  np_rev=$(jq -r '.nodes.nixpkgs.locked.rev' "$repo_root/flake.lock")
  np_hash=$(jq -r '.nodes.nixpkgs.locked.narHash' "$repo_root/flake.lock")
  nixpkgs_path=$(nix flake prefetch --json "github:NixOS/nixpkgs/$np_rev?narHash=$np_hash" | jq -r '.storePath')
  echo "   $nixpkgs_path"
  echo ">> [channels] building the committed channels system"
  channels_top=$(nix build --no-link --print-out-paths -f "$nixpkgs_path/nixos" system \
    -I "nixpkgs=$nixpkgs_path" -I "nixos-config=$channels_dir/configuration.nix")
  echo "   $channels_top"
  echo ">> [channels] seeding a simulated target store"
  channels_store="$work/store-channels"
  nix copy --no-check-sigs --to "local?root=$channels_store" "$channels_top"
  # nix3 CLI in file mode (-f), NOT classic nix-build: nix-build has no
  # --offline flag, and the point is to probe with exactly the same offline
  # semantics as the flake leg.
  all_cases "$channels_dir" channels \
    nix build --store "local?root=$channels_store" --offline --no-link \
      --builders '' -f "$nixpkgs_path/nixos" system \
      -I "nixpkgs=$nixpkgs_path" -I "nixos-config=$cfg_dir/configuration.nix"
fi

if [ "$overall" -eq 0 ]; then
  echo ">> All cases rebuild offline. Safe to spend an ISO+VM cycle."
else
  echo ">> At least one case fails offline. Fix the dep list before burning a VM cycle." >&2
fi
exit "$overall"
