#!/usr/bin/env bash
# Tests for calamares/proxy-screen.py
# URL validation, the nix.conf rewrite (including the
# symlink-into-the-store case the live ISO has), the --apply ordering
# contract, and the Reachability probe against a local HTTP fixture.
# The GTK path is exercised in the phase-4 VM matrix instead.
set -euo pipefail

flake_dir=$(cd "$(dirname "$0")/.." && pwd)
python3 -m py_compile "$flake_dir/calamares/proxy-screen.py"
echo "ok: proxy-screen.py compiles"

python3 - "$flake_dir/calamares/proxy-screen.py" <<'PYEOF'
import http.server
import importlib.util
import os
import sys
import tempfile
import threading

spec = importlib.util.spec_from_file_location("proxy_screen", sys.argv[1])
proxy_screen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy_screen)

# --- CACHE_URL_RE: what the screen lets through must be exactly what the
# --- proxy-persist injection accepts.
good = [
    "http://nix-proxy.lan",
    "http://10.201.200.160:80",
    "https://cache.example/with/path",
]
bad = [
    "ftp://nix-proxy.lan",       # not http(s)
    'http://x"; bad = "y',           # Nix string breakout
    "http://host with space",
    "http://host\nsubstituters = evil",  # nix.conf smuggling
    "nix-proxy.lan",             # no scheme
]
for url in good:
    assert proxy_screen.CACHE_URL_RE.match(url), url
for url in bad:
    assert not proxy_screen.CACHE_URL_RE.match(url), url
print("ok: CACHE_URL_RE accepts the real shapes, rejects breakouts")

# --- rewrite_nix_conf: live-ISO shape — /etc/nix/nix.conf is a symlink to a
# --- read-only store file.
work = tempfile.mkdtemp()
store_conf = os.path.join(work, "store-nix.conf")
with open(store_conf, "w") as fh:
    fh.write(
        "build-users-group = nixbld\n"
        "substituters = https://cache.nixos.org/\n"
        "flake-registry = https://channels.nixos.org/flake-registry.json\n"
        "trusted-users = root\n"
    )
os.chmod(store_conf, 0o444)
conf = os.path.join(work, "nix.conf")
os.symlink(store_conf, conf)

proxy_screen.rewrite_nix_conf("http://nix-proxy.lan", conf_path=conf)
assert not os.path.islink(conf), "symlink should be replaced by a file"
content = open(conf).read()
assert "substituters = http://nix-proxy.lan" in content
assert "cache.nixos.org" not in content, "old substituters line must be gone"
# The stock global flake-registry is unreachable behind the proxy; it must be
# emptied, not left pointing at channels.nixos.org.
assert "flake-registry =" in content
assert "channels.nixos.org" not in content, "stock flake-registry line must be gone"
assert "build-users-group = nixbld" in content
assert "trusted-users = root" in content
assert open(store_conf).read().count("cache.nixos.org") == 1, "store file untouched"
print("ok: rewrite_nix_conf swaps substituters and empties flake-registry")

# Idempotency: applying twice leaves exactly one substituters and one
# (empty) flake-registry line.
proxy_screen.rewrite_nix_conf("http://10.201.200.160:80", conf_path=conf)
content = open(conf).read()
lines = [l for l in content.splitlines() if l.startswith("substituters =")]
assert lines == ["substituters = http://10.201.200.160:80"], lines
reg_lines = [l for l in content.splitlines() if l.startswith("flake-registry")]
assert reg_lines == ["flake-registry ="], reg_lines
print("ok: rewrite_nix_conf is idempotent")

# --- apply_proxied: ordering contract and validation.
conf2 = os.path.join(work, "nix2.conf")
with open(conf2, "w") as fh:
    fh.write("substituters = https://cache.nixos.org/\n")
url_file = os.path.join(work, "nix-cache-url")

try:
    proxy_screen.apply_proxied("http://bad url", conf_path=conf2, url_file=url_file,
                               restart_daemon=False)
    raise AssertionError("malformed URL must raise")
except ValueError:
    pass
assert "cache.nixos.org" in open(conf2).read(), "no mutation on validation failure"
assert not os.path.exists(url_file)
print("ok: apply_proxied refuses malformed URLs before touching anything")

proxy_screen.apply_proxied("http://nix-proxy.lan", conf_path=conf2,
                           url_file=url_file, restart_daemon=False)
assert open(url_file).read() == "http://nix-proxy.lan\n"
assert "substituters = http://nix-proxy.lan" in open(conf2).read()
print("ok: apply_proxied rewrites conf and records the URL")

# --- probe against a local fixture.
class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/nix-cache-info":
            body = b"StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 40\n"
            self.send_response(200)
        elif self.path == "/wrong/nix-cache-info":
            body = b"<html>captive portal</html>"
            self.send_response(200)
        else:
            body = b"forbidden"
            self.send_response(403)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


try:
    server = http.server.HTTPServer(("127.0.0.1", 0), Fixture)
except OSError as error:
    print("SKIP: cannot bind a local socket in this sandbox ({})".format(error))
else:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:{}".format(server.server_address[1])

    ok, message = proxy_screen.probe(base)
    assert ok, message
    ok, message = proxy_screen.probe(base + "/")   # trailing slash normalized
    assert ok, message
    ok, message = proxy_screen.probe(base + "/wrong")
    assert not ok and "not like a Nix binary cache" in message, message
    ok, message = proxy_screen.probe(base + "/blocked")
    assert not ok and "HTTP 403" in message, message
    server.shutdown()

    ok, message = proxy_screen.probe("http://127.0.0.1:1", timeout_seconds=2)
    assert not ok and message.startswith("Unreachable"), message
    print("ok: probe accepts a cache answer; flags wrong-body, 403, unreachable")

print("PASS: proxy-screen logic tests")
PYEOF
