#!/usr/bin/env bash
# test-proxied-install — component probe for the proxied CLI installer.
#
# Exercises the decision logic of cli/proxy-setup.sh and
# cli/proxied-install.sh as a plain user against a localhost mock of the
# Cache proxy — no VM, no root, no appliance. The NIX_PROXY_TEST_PREFIX hook
# in both scripts relocates the system files they touch into a sandbox and
# skips root-only actions (daemon restart, real /etc writes).
#
# Needs: bash, curl, python3 (the mock), nix (lock parsing in the Pin match
# check — a pure fromJSON eval, no network).
#
# NOT covered here, by design (see README "Acceptance"): the
# substituter-declaration warning (needs a real NixOS eval), the install
# itself, and on-target rebuilds — those run against the live appliance.
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

# ---- mock Cache proxy ------------------------------------------------------
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

# ---- proxy-setup cases -----------------------------------------------------
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
  # Pre-seed a conf as the ISO would have it: our line must replace the
  # substituters line and keep the rest.
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
fi

sb="$sandbox/ps-badurl"
mkdir -p "$sb"
run_case "url shape: rejects a smuggled setting" 1 "Not a usable Cache URL" \
  -- ps_run "$sb" 'http://x.lan a=b'

# ---- proxied-install cases -------------------------------------------------
sb="$sandbox/pi-nosetup"
mkdir -p "$sb"
run_case "install: refuses without proxy-setup" 1 "proxy-setup" \
  -- pi_run "$sb"

# From here on, pretend proxy-setup ran.
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
# time, so the script must note the skipped Pin match and carry on to the
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
  # through the fixture's unevaluable config, and dies at the mount gate —
  # proving the decision chain order.
  run_case "pin match: match proceeds to the mount gate" 1 "Nothing is mounted" \
    -- pi_run "$sb" --config "$cfg" --root "$sandbox/not-a-mountpoint"
else
  echo "skip - nix unavailable: skipping the Pin match cases"
fi

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
