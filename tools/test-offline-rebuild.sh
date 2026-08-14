#!/usr/bin/env bash
# test-offline-rebuild.sh regression test.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
flake_dir=${1:-$script_dir/../variants/determinate-cli-offline/configs/flake}
flake_dir=$(cd "$flake_dir" && pwd)

# Select the config the way the ISO builder does: the entry named "nixos",
# or the sole entry. Override with a second argument when needed.
config_name=${2:-$(nix eval --raw "path:$flake_dir#nixosConfigurations" --apply '
  configs:
  let
    names = builtins.attrNames configs;
  in
  if configs ? nixos then
    "nixos"
  else if builtins.length names == 1 then
    builtins.head names
  else
    throw "multiple nixosConfigurations and none named nixos: ${builtins.concatStringsSep ", " names}"
')}
attr="nixosConfigurations.${config_name}.config.system.build.toplevel"
echo ">> Probing nixosConfigurations.${config_name}"

work=$(mktemp -d "${TMPDIR:-/tmp}/offline-rebuild-probe.XXXXXX")
store_root="$work/store"
cfg_dir="$work/cfg"
keep_logs=0

# shellcheck disable=2329
cleanup() {
  if [ "$keep_logs" -eq 1 ]; then
    echo ">> Probe workdir kept for inspection: $work"
  else
    chmod -R u+w "$work" 2>/dev/null || true
    rm -rf "$work"
  fi
}
trap cleanup EXIT

echo ">> Building the committed toplevel (what the ISO bakes)"
toplevel=$(nix build --no-link --print-out-paths "path:$flake_dir#$attr")
echo "   $toplevel"

echo ">> Seeding a simulated target store (what nixos-install copies)"
nix copy --no-check-sigs --to "local?root=$store_root" "$toplevel"
echo "   simulated target store size: $(du -sh "$store_root/nix/store" | cut -f1)"

overall=0

# Each case is a sed program applied to a fresh copy of the committed config.
# A stand-in for "the user edits configuration.nix on the installed system".
# The optional third argument names the file to edit (relative to the flake
# root; default configuration.nix) for targets that keep their config
# elsewhere (e.g. hosts/<name>/configuration.nix).
run_case() {
  local case_name=$1 sed_prog=$2 rel_file=${3:-configuration.nix}
  rm -rf "$cfg_dir"
  cp -r "$flake_dir" "$cfg_dir"
  chmod -R u+w "$cfg_dir"
  if [ ! -f "$cfg_dir/$rel_file" ]; then
    echo ">> [$case_name] BROKEN CASE — $rel_file does not exist in this config"
    overall=1
    return
  fi
  sed -i "$sed_prog" "$cfg_dir/$rel_file"
  # A sed program that matches nothing edits nothing, and an unchanged config
  # rebuilds nothing. Treat that as a failure because it means these cases were 
	# written for a different config, and this target needs its own 
	# (see offline-rebuild-cases.sh).
  if cmp -s "$flake_dir/$rel_file" "$cfg_dir/$rel_file"; then
    echo ">> [$case_name] Empty: sed pattern matched nothing in $rel_file"
    echo "   This config needs target-specific cases: ship an"
    echo "   offline-rebuild-cases.sh next to its flake.nix."
    overall=1
    return
  fi
  echo ">> [$case_name] offline rebuild against the simulated target store"
  local log="$work/$case_name.log"
  # --builders '': the target has no remote builders, so the probe must not
  # use the dev machine's either. A reachable builder would realize the
  # missing paths remotely and mask a real on-target failure. (The first probe
  # run showed exactly this attempt: ssh-ng://remotebuild@….)
  if nix build --store "local?root=$store_root" --offline --no-link \
       --builders '' \
       "path:$cfg_dir#$attr" >"$log" 2>&1; then
    echo "   PASS"
  else
    echo "   FAIL — the installed target would hit this after reboot:"
    grep -E "will be built|will be fetched|cannot build|unable to|error" "$log" \
      | head -30 | sed 's/^/   | /'
    echo "   full log: $work/$case_name.log"
    keep_logs=1
    overall=1
  fi
}

# Targets may ship their own edit-cases next to their flake.nix (a bash
# fragment of run_case invocations, sourced with $cfg_dir/$attr in scope).
# The built-in cases below are written against the example config in
# configs/flake and will report VACUOUS against anything else.
if [ -f "$flake_dir/offline-rebuild-cases.sh" ]; then
  echo ">> Using target-specific cases: $flake_dir/offline-rebuild-cases.sh"
  # shellcheck source=/dev/null
  . "$flake_dir/offline-rebuild-cases.sh"
else
  run_case password 's/initialPassword = "test"/initialPassword = "offline-probe"/'
  run_case timezone 's|time.timeZone = "America/New_York"|time.timeZone = "America/Chicago"|'
  run_case bootloader 's|boot.loader.systemd-boot.enable = true;|boot.loader.systemd-boot.enable = true;\n  boot.loader.systemd-boot.configurationLimit = 7;|'
  # Toggling a service whose package is already in the closure (fstrim ships in
  # util-linux).
  run_case service 's|networking.networkmanager.enable = true;|networking.networkmanager.enable = true;\n  services.fstrim.enable = true;|'
  # Disabling a service whose package rides in systemPackages (sshd). This is the only
  # case that changes system-path membership, so system-path itself rebuilds.
  run_case sshd-disable 's|^    enable = true;|    enable = false;|'
fi

if [ "$overall" -eq 0 ]; then
  echo ">> All cases rebuild offline. Safe to spend an ISO+VM cycle."
else
  echo ">> At least one case fails offline. Fix the dep list before burning a VM cycle." >&2
fi
exit "$overall"
