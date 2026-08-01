# proxy-setup — point the live installer's Nix at the Cache proxy.
#
# Step 4 of the Proxied install (see CONTEXT.md: Proxy setup): confirm or
# replace the prefilled Cache URL, gate on the Reachability probe, then
# declare the URL as the live environment's only substituter and record it
# for proxied-install. There is no --direct mode: a failing probe means no
# Proxied install.

DEFAULT_URL="http://nix-proxy.lan"

# Test hook (tools/test-proxied-install.sh): relocate the files this script
# writes and skip root-only actions (daemon restart, the nix self-check), so
# the decision logic can run as a plain user inside a sandbox. Unset in
# production.
TEST_PREFIX="${NIX_PROXY_TEST_PREFIX:-}"
CUSTOM_CONF="${TEST_PREFIX:+$TEST_PREFIX/nix.custom.conf}"
CUSTOM_CONF="${CUSTOM_CONF:-/etc/nix/nix.custom.conf}"
URL_FILE="${TEST_PREFIX:+$TEST_PREFIX/nix-cache-url}"
URL_FILE="${URL_FILE:-/run/nix-cache-url}"

usage() {
  cat <<EOF
Usage: proxy-setup [CACHE_URL]

Point the live installer's Nix at the Cache proxy. CACHE_URL is a Nix
substituter base URL (e.g. http://nix-proxy.lan, or the IP form when the
name does not resolve) — never an http_proxy value. With no argument,
prompts with an editable default.
EOF
}

url="${1:-}"
case "$url" in
  -h | --help)
    usage
    exit 0
    ;;
esac

if [ -z "$TEST_PREFIX" ] && [ "$(id -u)" -ne 0 ]; then
  echo "proxy-setup must run as root (try: sudo proxy-setup)" >&2
  exit 1
fi

if [ -z "$url" ]; then
  # -e/-i: an editable prefill, so the common case is pressing Enter.
  read -r -e -i "$DEFAULT_URL" -p "Cache URL: " url
fi

# Normalize away trailing slashes; nix joins request paths itself.
while [ "${url%/}" != "$url" ]; do url="${url%/}"; done

# The same shape check the graphical sibling applies before interpolating
# the URL into nix.conf syntax: refuse anything that could smuggle in a
# second setting or break the line.
if ! printf '%s' "$url" | grep -Eq '^https?://[A-Za-z0-9.:/_-]+$'; then
  echo "Not a usable Cache URL: $url" >&2
  echo "Expected http(s)://host[:port][/path] with no spaces or quotes." >&2
  exit 1
fi

# Reachability probe: the Cache proxy must answer /nix-cache-info like a
# binary cache. This replaces any notion of an internet check — it probes
# the appliance, not the internet.
echo ">> Probing $url/nix-cache-info ..."
if ! info="$(curl --fail --silent --show-error --max-time 10 "$url/nix-cache-info")"; then
  echo "Reachability probe FAILED: no answer from $url" >&2
  echo "Check the LAN link and the Cache proxy address (the IP form works" >&2
  echo "when the .lan name does not resolve), then re-run proxy-setup." >&2
  exit 1
fi
if ! printf '%s\n' "$info" | grep -q '^StoreDir:'; then
  echo "Reachability probe FAILED: $url answered, but not like a Nix binary" >&2
  echo "cache (no StoreDir in /nix-cache-info). Is this the Cache proxy?" >&2
  exit 1
fi

# Declare the substituter at the Determinate include point. On the live ISO
# /etc/nix/nix.custom.conf is an environment.etc symlink into the read-only
# store (the determinate module retargets the generated nix.conf there), so
# replace the symlink with a real file: the original content minus any
# substituters line, plus ours. determinate-nixd's generated /etc/nix/nix.conf
# includes this file, so clients pick it up on their next read; restart the
# daemon (nix-daemon.service execs determinate-nixd) so daemon-side
# substitution re-reads it too.
tmp="$(mktemp)"
if [ -e "$CUSTOM_CONF" ]; then
  # grep exits 1 when nothing survives the filter; that is a valid result
  # (a conf that held only a substituters line), not an error.
  grep -Ev '^[[:space:]]*substituters[[:space:]]*=' "$CUSTOM_CONF" > "$tmp" || true
fi
printf 'substituters = %s\n' "$url" >> "$tmp"
rm -f "$CUSTOM_CONF"
install -m 0644 "$tmp" "$CUSTOM_CONF"
rm -f "$tmp"

if [ -z "$TEST_PREFIX" ]; then
  if ! systemctl restart nix-daemon.service; then
    echo "warning: could not restart nix-daemon.service; daemon-side" >&2
    echo "substitution may keep the old (empty) substituters until it is" >&2
    echo "restarted. Client-side nix reads the new setting immediately." >&2
  fi
fi

# Record the URL for proxied-install only after the reroute is in place:
# the installer gates on this file, so its existence means "setup done".
printf '%s\n' "$url" > "$URL_FILE"
chmod 0644 "$URL_FILE"

echo ">> Cache proxy configured: $url"
echo ">> The live environment now substitutes only from the Cache proxy."

# Soft self-check through nix itself (headers, redirects, compression —
# things curl alone does not prove). Informational: the probe above already
# gated the install.
if [ -z "$TEST_PREFIX" ] && command -v nix > /dev/null 2>&1; then
  if nix store info --store "$url" > /dev/null 2>&1; then
    echo ">> nix reaches the Cache proxy as a store: OK"
  else
    echo ">> note: 'nix store info --store $url' did not succeed; the curl"
    echo "   probe passed, so this is worth a look but not necessarily fatal."
  fi
fi

echo ">> Next: sudo proxied-install"
