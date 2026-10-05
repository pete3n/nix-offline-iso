#!/usr/bin/env bash
# Regression test for how the bake picks what to copy into /iso/nix-cfg.
#
# A default target is a relative input of this repo
# (path:./variants/<v>/configs/flake), so Nix reports the builder's own
# source as its sourceInfo. It must still bake just the flake, as before
# subdirectory targets existed. A flake in a subdirectory bakes its whole
# source tree, and names the subdirectory in .flake-dir, when it lives
# outside this repo (--override-input ... 'path:/repo?dir=hosts/foo') or
# when it reaches sibling directories through relative inputs.
#
# Evaluation only: it reads the /nix-cfg derivation's build script and never
# builds an ISO. Needs the variants' inputs in the store (a store warmed by a
# prior evaluation or ISO build works offline).
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(dirname "$script_dir")
nix_flags=(--extra-experimental-features 'nix-command flakes' --offline)

work=$(mktemp -d "${TMPDIR:-/tmp}/flake-subdir.XXXXXX")
trap 'rm -rf "$work"' EXIT

# An outside source with its flake in hosts/foo. It needs no
# nixosConfigurations: only the /nix-cfg derivation is evaluated, which reads
# the lock and the paths, never the configuration.
mkdir -p "$work/outside/hosts/foo"
echo '{ outputs = _: { }; }' > "$work/outside/hosts/foo/flake.nix"
echo '{"nodes":{"root":{}},"root":"root","version":7}' > "$work/outside/hosts/foo/flake.lock"

# A copy of this repo with a flake in hosts/foo that reads ../../lib through
# a relative input, as an operator keeping their config in the builder
# checkout would. Locking a relative path input needs no network.
cp -r "$repo_root/." "$work/builder"
rm -rf "$work/builder/.git"
mkdir -p "$work/builder/hosts/foo" "$work/builder/lib"
echo '{ }' > "$work/builder/lib/default.nix"
cat > "$work/builder/hosts/foo/flake.nix" <<'EOF'
{
  inputs.lib = {
    url = "path:../../lib";
    flake = false;
  };
  outputs = _: { };
}
EOF
nix "${nix_flags[@]}" flake lock "path:$work/builder?dir=hosts/foo" 2>/dev/null

# The build script of the derivation copied to /nix-cfg, for one variant of
# the builder at <source>. runCommand keeps the script as an attribute.
cfg_dir_script() {
  local source=$1 variant=$2
  shift 2
  nix "${nix_flags[@]}" eval --raw "$@" \
    "path:$source#nixosConfigurations.$variant-flake-x86_64-linux.config.isoImage.contents" \
    --apply 'contents: (builtins.head (builtins.filter (entry: entry.target == "/nix-cfg") contents)).source.buildCommand'
}

overall=0
# check <case> <builder source> <variant> <want: root|subdir> [extra nix args...]
check() {
  local case_name=$1 source=$2 variant=$3 want=$4
  shift 4
  local script got
  if ! script=$(cfg_dir_script "$source" "$variant" "$@" 2>"$work/err"); then
    # Some inputs download files while evaluating (Determinate's binaries).
    # Without network or a warm store that cannot work, which says nothing
    # about the bake, so it is a skip.
    if grep -q 'unable to download' "$work/err"; then
      echo ">> [$case_name] SKIP: evaluation needs network"
      return
    fi
    echo ">> [$case_name] FAIL: evaluation failed"
    sed 's/^/   | /' "$work/err" | tail -6
    overall=1
    return
  fi
  if grep -q '\.flake-dir' <<< "$script"; then got=subdir; else got=root; fi
  if [ "$got" != "$want" ]; then
    echo ">> [$case_name] FAIL: baked as $got, expected $want"
    sed 's/^/   | /' <<< "$script"
    overall=1
    return
  fi
  if [ "$want" = subdir ] && ! grep -q "hosts/foo/flake.lock" <<< "$script"; then
    echo ">> [$case_name] FAIL: lock not written into the subdirectory"
    sed 's/^/   | /' <<< "$script"
    overall=1
    return
  fi
  echo ">> [$case_name] PASS"
}

# 1. Every default target bakes just its flake.
for variant in nixos-cli-offline nixos-graphical-offline determinate-cli-offline; do
  check "default:$variant" "$repo_root" "$variant" root
done

# 2. An outside ?dir= target bakes its whole source tree.
check "outside-subdir" "$repo_root" nixos-cli-offline subdir \
  --override-input target-nixos-cli-offline "path:$work/outside?dir=hosts/foo"

# 3. A target inside this repo with a relative input bakes the whole tree,
#    or ../../lib is out of reach at install time.
check "inside-relative-input" "$work/builder" nixos-cli-offline subdir \
  --override-input target-nixos-cli-offline "path:$work/builder?dir=hosts/foo"

if [ "$overall" -eq 0 ]; then
  echo "PASS: flake-subdir bake shape"
else
  echo "FAIL: see cases above" >&2
fi
exit "$overall"
