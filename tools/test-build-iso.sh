#!/usr/bin/env bash
# test-build-iso — component probe for tools/build-iso.sh (ADR 0009).
#
# Runs the wrapper against a stub `nix` that prints its argv and the
# ISO_CACHE_URL it inherited, so every flag-assembly and environment-
# isolation behavior is asserted without evaluating anything. Needs: bash.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

pass=0
fail=0
note() { echo "     $1"; }
ok() {
  pass=$((pass + 1))
  echo "ok   - $1"
}
bad() {
  fail=$((fail + 1))
  echo "FAIL - $1"
}

# The wrapper derives the repo root from its own location, so give it a
# private tree: sandbox/tools/build-iso.sh with sandbox/.env alongside.
mkdir -p "$sandbox/tools" "$sandbox/stub"
cp "$repo/tools/build-iso.sh" "$sandbox/tools/"
cat > "$sandbox/stub/nix" <<'EOF'
#!/usr/bin/env bash
echo "NIX-ARGS: $*"
echo "NIX-ENV-ISO_CACHE_URL: ${ISO_CACHE_URL:-<unset>}"
EOF
chmod +x "$sandbox/stub/nix"

# run_wrapper [VAR=val ...] -- ARGS... : run the wrapper with the stub nix
# first on PATH, capturing combined output and exit status into globals.
out=""
status=0
run_wrapper() {
  local env_pairs=()
  while [ "$1" != "--" ]; do
    env_pairs+=("$1")
    shift
  done
  shift
  status=0
  out="$(env "${env_pairs[@]}" PATH="$sandbox/stub:$PATH" \
    "$sandbox/tools/build-iso.sh" "$@" 2>&1)" || status=$?
}

expect() {
  local name="$1" want_status="$2" want_pattern="$3"
  if [ "$status" -eq "$want_status" ] && printf '%s' "$out" | grep -Eq "$want_pattern"; then
    ok "$name"
  else
    bad "$name"
    note "exit $status (wanted $want_status); wanted /$want_pattern/"
    note "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 240)"
  fi
}

# --- no .env: pure build, ambient ISO_* must not leak -----------------------
rm -f "$sandbox/.env"
run_wrapper ISO_CACHE_URL=http://ambient.example -- determinate-cli-proxied
expect "no .env: builds the plain attribute" 0 \
  "NIX-ARGS: build $sandbox#installer-iso-determinate-cli-proxied( |$)"
if printf '%s' "$out" | grep -q -- --impure; then
  bad "no .env: --impure leaked into a pure build"
else
  ok "no .env: stays pure (no --impure)"
fi

# --- .env with both keys (pinned override) -----------------------------------
cat > "$sandbox/.env" <<'EOF'
ISO_CACHE_URL=http://cache.example
ISO_INPUT_OVERRIDES="determinate=tarball+http://cache.example/f/d.tar.gz?narHash=sha256-AAA"
EOF
run_wrapper -- determinate-cli-proxied
expect ".env: --impure + pinned override assembled" 0 \
  "NIX-ARGS: build .*--override-input determinate tarball\+http://cache\.example/f/d\.tar\.gz\?narHash=sha256-AAA --impure"
expect ".env: prefill exported to the nix process" 0 \
  "NIX-ENV-ISO_CACHE_URL: http://cache\.example"
if printf '%s' "$out" | grep -q "WARNING: no ?narHash="; then
  bad ".env: pinned override still warned"
else
  ok ".env: pinned override does not warn"
fi

# --- unpinned override warns -------------------------------------------------
printf 'ISO_INPUT_OVERRIDES="determinate=tarball+http://cache.example/f/d.tar.gz"\n' > "$sandbox/.env"
run_wrapper -- determinate-cli-proxied
expect "unpinned override: still builds" 0 "NIX-ARGS: build .*--override-input determinate"
expect "unpinned override: warns about the missing narHash" 0 "WARNING: no \?narHash="

# --- ambient isolation with .env present -------------------------------------
# .env does not set ISO_CACHE_URL; the ambient shell does. The nix process
# must see it UNSET — only .env content may influence the build.
run_wrapper ISO_CACHE_URL=http://ambient.example -- determinate-cli-proxied
expect "ambient isolation: nix sees ISO_CACHE_URL unset" 0 \
  "NIX-ENV-ISO_CACHE_URL: <unset>"
if printf '%s' "$out" | grep -q "ambient.example"; then
  bad "ambient isolation: ambient value surfaced in output"
else
  ok "ambient isolation: ambient value nowhere in the build"
fi

# --- validation failures ------------------------------------------------------
printf 'ISO_CACHE_URL="http://x.lan a=b"\n' > "$sandbox/.env"
run_wrapper -- determinate-cli-proxied
expect "validation: malformed ISO_CACHE_URL fails fast" 1 "not a usable Cache URL"

printf 'ISO_INPUT_OVERRIDES="noequalsign"\n' > "$sandbox/.env"
run_wrapper -- determinate-cli-proxied
expect "validation: malformed override entry fails fast" 1 "not input=url"

# --- argument handling ---------------------------------------------------------
rm -f "$sandbox/.env"
run_wrapper -- installer-iso-nixos-graphical-proxied --print-out-paths
expect "args: full attr name accepted, extras passed through" 0 \
  "NIX-ARGS: build $sandbox#installer-iso-nixos-graphical-proxied --print-out-paths"
run_wrapper -- --help
expect "args: --help prints the product list" 0 "determinate-cli-proxied"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
