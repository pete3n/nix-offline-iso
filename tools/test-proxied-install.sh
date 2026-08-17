#!/usr/bin/env bash
# test-proxied-install: component probe for the proxied CLI installer.
#
# Exercises the decision logic of cli/proxy-setup.sh and
# cli/proxied-install.sh as a plain user against a localhost simulation of the
# Cache proxy. The NIX_PROXY_TEST_PREFIX hook in both scripts relocates the system 
# files they touch into a sandbox and skips root-only actions (daemon restart, real /etc writes).
#
# Needs: bash, curl, python3 (the sim), nix (lock parsing in the pin match
# check with a pure fromJSON eval).
#
# Not covered here: the substituter-declaration warning (needs a real NixOS eval), 
# the install itself, and on-target rebuilds.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
sandbox="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2> /dev/null || true
  rm -rf "$sandbox"
}
trap cleanup EXIT

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

# run_case NAME WANT_EXIT WANT_PATTERN [--stdin TEXT] -- CMD...
# Runs CMD, asserts its exit code and that combined output matches the
# pattern (grep -E).
run_case() {
  local name="$1" want_status="$2" want_out="$3"
  shift 3
  local stdin_text=""
  if [ "$1" = "--stdin" ]; then
    stdin_text="$2"
    shift 2
  fi
  [ "$1" = "--" ] && shift
  local out status=0
  out="$(printf '%s\n' "$stdin_text" | "$@" 2>&1)" || status=$?
  if [ "$status" -eq "$want_status" ] && printf '%s' "$out" | grep -Eq "$want_out"; then
    ok "$name"
  else
    bad "$name"
    note "exit $status (wanted $want_status); wanted output /$want_out/"
    note "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 220)"
  fi
}

ps_run() {
  local prefix="$1"
  shift
  NIX_PROXY_TEST_PREFIX="$prefix" bash -eu -o pipefail "$repo/cli/proxy-setup.sh" "$@"
}
pi_run() {
  local prefix="$1"
  shift
  NIX_PROXY_TEST_PREFIX="$prefix" bash -eu -o pipefail "$repo/cli/proxied-install.sh" "$@"
}

# Simulated Cache proxy:
# /nix-cache-info answers like a binary cache; /junk/nix-cache-info answers
# 200 with junk (a captive-portal-ish wrong answer); anything else 404.
python3 - "$sandbox" <<'PY' &
import http.server, socketserver, sys, os

sandbox = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/nix-cache-info":
            body = b"StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 40\n"
        elif self.path == "/junk/nix-cache-info":
            body = b"<html>definitely not a nix cache</html>\n"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(os.path.join(sandbox, "port"), "w") as port_file:
        port_file.write(str(server.server_address[1]))
    server.serve_forever()
PY
server_pid=$!

for _ in $(seq 50); do
  [ -s "$sandbox/port" ] && break
  sleep 0.1
done
if [ ! -s "$sandbox/port" ]; then
  echo "mock appliance did not start" >&2
  exit 1
fi
port="$(cat "$sandbox/port")"
mock_url="http://127.0.0.1:$port"

# curl (which proxy-setup itself needs) or loopback may be unavailable in
# restricted sandboxes; check once and skip the network-dependent cases
# honestly rather than fail them.
loopback=1
if ! command -v curl > /dev/null 2>&1; then
  loopback=0
  echo "skip - curl unavailable here: skipping the probe cases; run on a"
  echo "       normal host to exercise them"
elif ! curl --silent --fail --max-time 5 "$mock_url/nix-cache-info" | grep -q StoreDir; then
  loopback=0
  echo "skip - loopback unavailable: skipping the probe cases; run on a"
  echo "       normal host to exercise them"
fi

# Proxy-setup cases
if [ "$loopback" -eq 1 ]; then
  sb="$sandbox/ps-unreachable"
  mkdir -p "$sb"
  run_case "probe: unreachable proxy fails the setup" 1 "Reachability probe FAILED" \
    -- ps_run "$sb" "http://127.0.0.1:9"

  sb="$sandbox/ps-junk"
  mkdir -p "$sb"
  run_case "probe: 200-but-not-a-cache fails the setup" 1 "not like a Nix binary" \
    -- ps_run "$sb" "$mock_url/junk"

  sb="$sandbox/ps-happy"
  mkdir -p "$sb"
  # Pre-seed a conf as the ISO would have it: 
	# replace the substituters line and keep the rest.
  printf 'substituters = \nexperimental-features = nix-command flakes\n' > "$sb/nix.custom.conf"
  run_case "probe: good proxy passes and configures" 0 "Cache proxy configured" \
    -- ps_run "$sb" "$mock_url"
  if [ "$(grep -c '^substituters = ' "$sb/nix.custom.conf")" = 1 ] \
    && grep -qxF "substituters = $mock_url" "$sb/nix.custom.conf" \
    && grep -qF "experimental-features = nix-command flakes" "$sb/nix.custom.conf"; then
    ok "conf rewrite: one substituters line, ours, rest preserved"
  else
    bad "conf rewrite: unexpected nix.custom.conf content"
    note "$(cat "$sb/nix.custom.conf")"
  fi
  if [ "$(cat "$sb/nix-cache-url")" = "$mock_url" ]; then
    ok "url handoff: /run-equivalent file holds the Cache URL"
  else
    bad "url handoff: wrong or missing recorded URL"
  fi
  # Idempotence: run again (with a trailing slash for the normalizer) and the
  # conf must still hold exactly one substituters line.
  ps_run "$sb" "$mock_url/" > /dev/null
  if [ "$(grep -c '^substituters = ' "$sb/nix.custom.conf")" = 1 ] \
    && grep -qxF "substituters = $mock_url" "$sb/nix.custom.conf"; then
    ok "idempotent re-run + trailing-slash normalization"
  else
    bad "re-run duplicated or mangled the substituters line"
  fi

  # Builder prefill (ADR 0009): a baked /etc-equivalent installer-prefills
  # file replaces the prompt's default, and an empty (Enter) answer accepts
  # it.
  sb="$sandbox/ps-prefill"
  mkdir -p "$sb"
  printf 'ISO_CACHE_URL=%s\n' "$mock_url" > "$sb/installer-prefills"
  run_case "prefill: empty input accepts the baked Cache URL" 0 "Cache proxy configured" \
    --stdin "" -- ps_run "$sb"
  if [ "$(cat "$sb/nix-cache-url" 2> /dev/null)" = "$mock_url" ]; then
    ok "prefill: recorded URL is the baked one"
  else
    bad "prefill: wrong or missing recorded URL"
  fi

  # An explicit argument always wins over the prefill.
  sb="$sandbox/ps-prefill-arg"
  mkdir -p "$sb"
  printf 'ISO_CACHE_URL=%s\n' "http://127.0.0.1:9" > "$sb/installer-prefills"
  run_case "prefill: explicit argument wins over the prefill" 0 "Cache proxy configured" \
    -- ps_run "$sb" "$mock_url"

  # An accepted prefill still passes through the Reachability probe — a
  # prefill may never weaken the gate (ADR 0009). If acceptance ever
  # short-circuits the probe, this unreachable prefill would succeed.
  sb="$sandbox/ps-prefill-gated"
  mkdir -p "$sb"
  printf 'ISO_CACHE_URL=http://127.0.0.1:9\n' > "$sb/installer-prefills"
  run_case "prefill: accepted prefill is still probe-gated" 1 "Reachability probe FAILED" \
    --stdin "" -- ps_run "$sb"
fi

# A prefills file without the key leaves the tracked default in place — the
# script must not treat an unrelated line as a Cache URL. Assert on which
# URL gets probed (echoed before curl runs), not the probe's outcome:
# whether nix-proxy.lan resolves is an environment accident this harness
# must not depend on, and the case then needs neither curl nor loopback.
sb="$sandbox/ps-prefill-nokey"
mkdir -p "$sb"
printf 'SOME_OTHER_KEY=http://unrelated.example\n' > "$sb/installer-prefills"
nokey_out="$(printf '\n' | ps_run "$sb" 2>&1 || true)"
if printf '%s' "$nokey_out" | grep -q 'Probing http://nix-proxy\.lan'; then
  ok "prefill: unrelated keys are ignored (default kept)"
else
  bad "prefill: unrelated key changed the default"
  note "got: $(printf '%s' "$nokey_out" | tr '\n' ' ' | head -c 220)"
fi

# The positive twin, equally curl-free: a prefilled URL must be the one the
# probe goes for when the (non-tty) answer is empty. Without this case a
# curl-less environment would never notice the prefill feature deleted.
sb="$sandbox/ps-prefill-probed"
mkdir -p "$sb"
printf 'ISO_CACHE_URL=http://prefilled.example\n' > "$sb/installer-prefills"
probed_out="$(printf '\n' | ps_run "$sb" 2>&1 || true)"
if printf '%s' "$probed_out" | grep -q 'Probing http://prefilled\.example'; then
  ok "prefill: baked Cache URL reaches the probe on empty input"
else
  bad "prefill: baked Cache URL never reached the probe"
  note "got: $(printf '%s' "$probed_out" | tr '\n' ' ' | head -c 220)"
fi

# Producer/consumer drift tripwires: the iso.nix bakes and the script read
# must agree on the file name and key, and builderPrefills must stay the
# single getEnv read point (ADR 0009). Textual on purpose — a full closure
# needs a NixOS eval, which this harness excludes by design.
for producer in variants/determinate-cli-proxied/iso.nix variants/nixos-graphical-proxied/iso.nix; do
  if grep -q '"installer-prefills"' "$repo/$producer" \
    && grep -q 'ISO_CACHE_URL=' "$repo/$producer"; then
    ok "drift: $producer bakes installer-prefills with ISO_CACHE_URL"
  else
    bad "drift: $producer no longer bakes what cli/proxy-setup.sh reads"
  fi
done
if grep -q '/etc/installer-prefills' "$repo/cli/proxy-setup.sh" \
  && grep -q '\^ISO_CACHE_URL=' "$repo/cli/proxy-setup.sh"; then
  ok "drift: proxy-setup reads the baked file name and key"
else
  bad "drift: proxy-setup's prefills read diverged from the bake"
fi
getenv_files="$(grep -rl 'builtins\.getEnv' "$repo" --include='*.nix' 2> /dev/null | sort)"
if [ "$getenv_files" = "$repo/nix/lib.nix" ]; then
  ok "drift: builtins.getEnv appears only in nix/lib.nix"
else
  bad "drift: getEnv read outside the builderPrefills allow-list"
  note "found in: $getenv_files"
fi

# Telemetry policy tripwire: both determinate installers must carry the
# DETSYS_IDS_TELEMETRY disable (offline: zero network attempts, ADR 0007
# amendment; proxied: unreachable endpoints). Runtime policy, not a prefill.
if grep -q 'DETSYS_IDS_TELEMETRY' "$repo/nix/lib.nix"; then
  ok "policy: shared telemetry-off module sets DETSYS_IDS_TELEMETRY"
else
  bad "policy: DETSYS_IDS_TELEMETRY disable missing from nix/lib.nix"
fi
for det_variant in variants/determinate-cli-proxied/iso.nix variants/determinate-cli-offline/iso.nix; do
  if grep -q 'determinateTelemetryOff' "$repo/$det_variant"; then
    ok "policy: $det_variant imports the telemetry-off module"
  else
    bad "policy: $det_variant dropped the telemetry-off module"
  fi
done

# builderPrefills eval matrix (no network: nixpkgs is never forced).
if command -v nix > /dev/null 2>&1; then
  matrix_expr="(import $repo/nix/lib.nix { nixpkgs = null; }).builderPrefills.cacheUrl"
  matrix_eval() {
    # lib.nix uses the bare `fetchTree` global, in scope only with the
    # flakes feature — enable it or the import fails as undefined variable.
    nix --extra-experimental-features 'nix-command flakes' eval --impure --expr "$matrix_expr" 2>&1
  }
  if [ "$(env -u ISO_CACHE_URL "$(command -v nix)" --extra-experimental-features 'nix-command flakes' \
    eval --impure --expr "$matrix_expr" 2> /dev/null)" = "null" ]; then
    ok "builderPrefills: unset ISO_CACHE_URL evaluates to null (pure default)"
  else
    bad "builderPrefills: unset ISO_CACHE_URL did not yield null"
  fi
  if [ "$(ISO_CACHE_URL=http://cache.example matrix_eval)" = '"http://cache.example"' ]; then
    ok "builderPrefills: valid ISO_CACHE_URL passes through"
  else
    bad "builderPrefills: valid ISO_CACHE_URL mangled"
  fi
  malformed_out="$(ISO_CACHE_URL='http://x.lan a=b' matrix_eval || true)"
  if printf '%s' "$malformed_out" | grep -q 'not a usable Cache URL'; then
    ok "builderPrefills: malformed ISO_CACHE_URL kills the eval"
  else
    bad "builderPrefills: malformed ISO_CACHE_URL was accepted"
    note "got: $(printf '%s' "$malformed_out" | tr '\n' ' ' | head -c 220)"
  fi
else
  echo "skip - nix unavailable: skipping the builderPrefills eval cases"
fi

sb="$sandbox/ps-badurl"
mkdir -p "$sb"
run_case "url shape: rejects a smuggled setting" 1 "Not a usable Cache URL" \
  -- ps_run "$sb" 'http://x.lan a=b'

# Proxied-install cases
sb="$sandbox/pi-nosetup"
mkdir -p "$sb"
run_case "install: refuses without proxy-setup" 1 "proxy-setup" \
  -- pi_run "$sb"

# Pretend proxy-setup ran.
mkurl() {
  mkdir -p "$1"
  printf '%s\n' "$mock_url" > "$1/nix-cache-url"
}

sb="$sandbox/pi-nocfg"
mkurl "$sb"
cfg="$sandbox/cfg-empty"
mkdir -p "$cfg"
run_case "install: refuses without a flake.nix" 1 "No flake\.nix" \
  -- pi_run "$sb" --config "$cfg"

# Lock-less configs are allowed: locking happens through the proxy at build
# time, so the script must note the skipped pin match and carry on to the
# mount gate. nix may write a lock into the fixture on first eval, so each
# case gets a fresh fixture.
write_lockless() {
  mkdir -p "$1"
  echo '{ outputs = _: { nixosConfigurations = { }; }; }' > "$1/flake.nix"
}
mkdir -p "$sandbox/not-a-mountpoint"

sb="$sandbox/pi-nolock-note"
mkurl "$sb"
cfg="$sandbox/cfg-nolock-note"
write_lockless "$cfg"
run_case "install: lock-less config notes the skipped Pin match" 1 "no flake\.lock" \
  -- pi_run "$sb" --config "$cfg" --root "$sandbox/not-a-mountpoint"

sb="$sandbox/pi-nolock-flow"
mkurl "$sb"
cfg="$sandbox/cfg-nolock-flow"
write_lockless "$cfg"
run_case "install: lock-less config proceeds to the mount gate" 1 "Nothing is mounted" \
  -- pi_run "$sb" --config "$cfg" --root "$sandbox/not-a-mountpoint"

# A minimal committed lock pinning determinate at a known narHash, plus the
# fixture flake above (no inputs — nothing to fetch, works offline).
write_fixture() {
  local dir="$1" hash="$2"
  mkdir -p "$dir"
  echo '{ outputs = _: { nixosConfigurations = { }; }; }' > "$dir/flake.nix"
  cat > "$dir/flake.lock" <<EOF
{
  "nodes": {
    "determinate": {
      "locked": {
        "narHash": "$hash",
        "type": "tarball",
        "url": "https://example.invalid/determinate.tar.gz"
      }
    },
    "root": {
      "inputs": {
        "determinate": "determinate"
      }
    }
  },
  "root": "root",
  "version": 7
}
EOF
}

hash_a="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
hash_b="sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="

if command -v nix > /dev/null 2>&1; then
  sb="$sandbox/pi-pinmismatch"
  mkurl "$sb"
  printf 'narHash: %s\nurl: https://example.invalid/iso.tar.gz\n' "$hash_a" > "$sb/determinate-pin"
  cfg="$sandbox/cfg-mismatch"
  write_fixture "$cfg" "$hash_b"
  run_case "pin match: mismatch warns and aborts on anything but YES" 1 "Pin mismatch" \
    --stdin "no" -- pi_run "$sb" --config "$cfg"

  sb="$sandbox/pi-pinmatch"
  mkurl "$sb"
  printf 'narHash: %s\nurl: https://example.invalid/iso.tar.gz\n' "$hash_a" > "$sb/determinate-pin"
  cfg="$sandbox/cfg-match"
  write_fixture "$cfg" "$hash_a"
  mkdir -p "$sandbox/not-a-mountpoint"
  # A matching pin sails past the check (no prompt), degrades gracefully
  # through the fixture's unevaluable config, and dies at the mount gate,
  # proving the decision chain order.
  run_case "pin match: match proceeds to the mount gate" 1 "Nothing is mounted" \
    -- pi_run "$sb" --config "$cfg" --root "$sandbox/not-a-mountpoint"
else
  echo "skip - nix unavailable: skipping the Pin match cases"
fi

# ---- Flake-ref install cases (ADR 0010) -------------------------------------
sb="$sandbox/pi-conflict"
mkdir -p "$sb"
run_case "flake-ref: --flake and --config conflict" 1 "conflict" \
  -- pi_run "$sb" --flake "path:/x" --config "/y"

# The Cache-URL gate is mode-independent: a ref install without proxy-setup
# refuses before touching the ref.
sb="$sandbox/pi-flake-nosetup"
mkdir -p "$sb"
run_case "flake-ref: still gated on proxy-setup" 1 "proxy-setup" \
  -- pi_run "$sb" --flake "path:/x"

# The ref-touching cases need a nix that can fetch a path flake (a store
# write); probe once and skip honestly where it cannot.
if command -v nix > /dev/null 2>&1; then
  probe_flake="$sandbox/flake-probe"
  write_lockless "$probe_flake"
  if nix --extra-experimental-features 'nix-command flakes' \
    flake metadata --json "path:$probe_flake" > /dev/null 2>&1; then
    sb="$sandbox/pi-flake-unreachable"
    mkurl "$sb"
    run_case "flake-ref: unreachable ref fails early with the SSH-key hint" 1 "GIT_SSH_COMMAND" \
      -- pi_run "$sb" --flake "path:$sandbox/does-not-exist"

    sb="$sandbox/pi-flake-flow"
    mkurl "$sb"
    cfg="$sandbox/cfg-flake-flow"
    write_lockless "$cfg"
    run_case "flake-ref: lockless ref reaches the mount gate (no copy, no generate)" 1 "Nothing is mounted" \
      -- pi_run "$sb" --flake "path:$cfg" --root "$sandbox/not-a-mountpoint"

    # Config names like "user@host-1" are valid nixosConfigurations attrs
    # but invalid as UNQUOTED attr-path components — the script must quote
    # $HOST at every nix call. The subs warning below only prints when the
    # quoted config eval actually succeeded (an unquoted path is a parse
    # error, which degrades to the could-not-evaluate note instead).
    sb="$sandbox/pi-flake-atname"
    mkurl "$sb"
    cfg="$sandbox/cfg-flake-atname"
    mkdir -p "$cfg"
    echo '{ outputs = _: { nixosConfigurations."alice@host-1" = { config = { system.build = { }; nix.settings.substituters = [ ]; }; }; }; }' > "$cfg/flake.nix"
    run_case "flake-ref: '@' config names resolve and evaluate (quoted attr paths)" 1 \
      "declared substituters do not include" \
      -- pi_run "$sb" --flake "path:$cfg" --root "$sandbox/not-a-mountpoint"

    # The same credential-less fixture must trip the lockout preflight:
    # nixos-install runs --no-root-passwd, so a config with no user
    # credential installs an unloggable system (field-found).
    run_case "flake-ref: credential-less config warns about lockout" 1 \
      "login credential" \
      -- pi_run "$sb" --flake "path:$cfg" --root "$sandbox/not-a-mountpoint"

    # And a config WITH a credential must not warn.
    sb="$sandbox/pi-flake-cred"
    mkurl "$sb"
    cfg="$sandbox/cfg-flake-cred"
    mkdir -p "$cfg"
    echo '{ outputs = _: { nixosConfigurations."bob@host-2" = { config = { system.build = { }; nix.settings.substituters = [ ]; users.users.bob = { initialPassword = "changeme"; }; }; }; }; }' > "$cfg/flake.nix"
    cred_out="$(pi_run "$sb" --flake "path:$cfg" --root "$sandbox/not-a-mountpoint" 2>&1 || true)"
    if printf '%s' "$cred_out" | grep -q "login credential"; then
      bad "flake-ref: credentialed config still warned about lockout"
      note "got: $(printf '%s' "$cred_out" | tr '\n' ' ' | head -c 220)"
    else
      ok "flake-ref: credentialed config does not warn about lockout"
    fi
  else
    echo "skip - nix cannot fetch path flakes here: skipping the flake-ref ref cases"
  fi
else
  echo "skip - nix unavailable: skipping the flake-ref ref cases"
fi

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
