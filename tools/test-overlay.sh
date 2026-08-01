#!/usr/bin/env bash
# Simulate the calamares-nixos-extensions overlay postInstall from flake.nix
# against a real extensions source tree, without building anything. Catches
# the anchor/guard drift class of break (which bit the graphical branch
# twice) and functionally exercises the injected proxy-persist logic.
#
# Usage:
#   tools/test-overlay.sh /path/to/calamares-nixos-extensions/src
#
# The argument is the extensions *source* directory (the one containing
# modules/, config/, branding/) — e.g. pkgs/by-name/ca/calamares-nixos-extensions/src
# in the pinned nixpkgs, or a checkout of the upstream repo.
set -euo pipefail

snap=${1:?usage: test-overlay.sh /path/to/calamares-nixos-extensions/src}
flake_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stand-in for the ${final.glibcLocales} store path.
fake_locales=/nix/store/00000000000000000000000000000000-fake-glibc-locales

# --- extract the postInstall body and resolve its Nix interpolations ---
sed -n "/postInstall = (old.postInstall or/,/^          '';/p" "$flake_dir/flake.nix" \
  | sed '1d;$d' \
  | sed "s|\${./calamares/welcome.conf}|$flake_dir/calamares/welcome.conf|g
         s|\${./calamares/locale.conf}|$flake_dir/calamares/locale.conf|g
         s|\${./calamares/inject/proxy-persist.py}|$flake_dir/calamares/inject/proxy-persist.py|g
         s|\${final.glibcLocales}|$fake_locales|g" \
  > "$work/postinstall.sh"

# Any leftover interpolation means flake.nix gained one this script does not
# know how to resolve — update the sed above.
if grep -n '\${' "$work/postinstall.sh"; then
  echo "FAIL: unresolved Nix interpolation in extracted postInstall"; exit 1
fi

# --- fake $out mirroring the extensions installPhase (incl. its substitutions) ---
out=$work/out
mkdir -p "$out/etc/calamares" "$out/lib/calamares" "$out/share/calamares"
cp -r "$snap/modules" "$out/lib/calamares/"
cp -r "$snap/config/." "$out/etc/calamares/"
cp -r "$snap/branding" "$out/share/calamares/"
chmod -R u+w "$out"
# The stock installPhase substitutes these BEFORE postInstall runs; replicate
# so the overlay's own re-substitution of locale.conf is tested honestly.
sed -i "s|@out@|$out|g" "$out/etc/calamares/settings.conf"
sed -i "s|@glibcLocales@|$fake_locales|g" "$out/etc/calamares/modules/locale.conf"

# stdenv's substituteInPlace, reduced to the --replace-fail form we use.
substituteInPlace() {
  local file=$1 flag=$2 from=$3 to=$4
  [ "$flag" = --replace-fail ] || { echo "substituteInPlace stub: unsupported flag $flag"; return 1; }
  grep -qF "$from" "$file" || { echo "substituteInPlace: pattern not found in $file: $from"; return 1; }
  python3 -c 'import sys; p, f, t = sys.argv[1:4]; s = open(p).read(); open(p, "w").write(s.replace(f, t))' \
    "$file" "$from" "$to"
}

# --- run the overlay steps ---
. "$work/postinstall.sh"
echo "ok: postInstall ran to completion"

# --- static assertions ---
w=$out/etc/calamares/modules/welcome.conf
grep -q 'Proxied-installer welcome.conf' "$w"
if grep -qE '^[[:space:]]*-[[:space:]]*internet[[:space:]]*$|^[[:space:]]*internetCheckUrl' "$w"; then
  echo "FAIL: functional internet requirement still present in welcome.conf"; exit 1
fi
echo "ok: welcome.conf replaced, internet requirement gone"

l=$out/etc/calamares/modules/locale.conf
if grep -qE '^[[:space:]]*geoip[[:space:]]*:' "$l"; then
  echo "FAIL: geoip block still present in locale.conf"; exit 1
fi
grep -q "localeGenPath: $fake_locales/share/i18n/SUPPORTED" "$l"
if grep -q '@glibcLocales@' "$l"; then
  echo "FAIL: @glibcLocales@ left unsubstituted in locale.conf"; exit 1
fi
echo "ok: locale.conf geoip-free, glibcLocales re-substituted"

s=$out/etc/calamares/settings.conf
for keep in welcome locale keyboard users packagechooser 'notesqml@unfree' \
            partition summary mount nixos umount finished; do
  grep -qE "^[[:space:]]*-[[:space:]]*$keep[[:space:]]*\$" "$s" \
    || { echo "FAIL: stock sequence entry '$keep' missing from settings.conf"; exit 1; }
done
echo "ok: full stock page/job sequence intact"

m=$out/lib/calamares/modules/nixos/main.py
python3 -m py_compile "$m"
[ "$(grep -c 'proxied-iso: persist the Cache URL' "$m")" = 1 ] \
  || { echo "FAIL: proxy-persist block not inserted exactly once"; exit 1; }
inj_line=$(grep -n 'proxied-iso: persist the Cache URL' "$m" | head -1 | cut -d: -f1)
tail_line=$(grep -nE '^[[:space:]]*cfg \+= cfgtail[[:space:]]*$' "$m" | head -1 | cut -d: -f1)
[ "$inj_line" -lt "$tail_line" ] \
  || { echo "FAIL: proxy-persist block landed after cfg += cfgtail"; exit 1; }
echo "ok: main.py compiles; persist block inserted once, before cfg += cfgtail"

# --- functional test of the injected block, extracted from the REAL main.py ---
sed -n '/# --- proxied-iso: persist the Cache URL into the target ---/,/# --- end proxied-iso persist ---/p' \
  "$m" > "$work/block.py"
python3 - "$work/block.py" "$work" <<'PYEOF'
import re
import sys
import textwrap
import types

block_path, work = sys.argv[1], sys.argv[2]
url_file = work + "/nix-cache-url"
block_src = open(block_path).read().replace("/run/nix-cache-url", url_file)
block = compile(textwrap.dedent(block_src), "proxy-persist-block", "exec")


def run_block():
    warnings = []
    libcalamares = types.SimpleNamespace(
        utils=types.SimpleNamespace(warning=warnings.append)
    )
    scope = {"re": re, "libcalamares": libcalamares, "cfg": "BASE\n"}
    exec(block, scope)
    return scope["cfg"], warnings


def write_url(content):
    with open(url_file, "w") as url_fh:
        url_fh.write(content)


# Case 1: Proxied install — plain host URL.
write_url("http://nix-cache.nxs.lan\n")
cfg, warnings = run_block()
assert 'nix.settings.substituters = [ "http://nix-cache.nxs.lan" ];' in cfg, cfg
assert 'nix.settings.flake-registry = "";' in cfg, cfg
assert cfg.startswith("BASE\n") and not warnings
print("ok: valid Cache URL appended to cfg")

# Case 2: IP:port form survives the validation.
write_url("http://10.201.200.160:80")
cfg, warnings = run_block()
assert '[ "http://10.201.200.160:80" ]' in cfg and not warnings
print("ok: IP:port Cache URL appended to cfg")

# Case 3: malformed URL (Nix string breakout attempt) is refused with a warning.
write_url('http://x"; bad = "y')
cfg, warnings = run_block()
assert cfg == "BASE\n", cfg
assert len(warnings) == 1 and "malformed cache URL" in warnings[0]
print("ok: malformed Cache URL refused, warning emitted, cfg untouched")

# Case 4: no file (Direct install) — nothing appended, no warning.
import os
os.remove(url_file)
cfg, warnings = run_block()
assert cfg == "BASE\n" and not warnings
print("ok: absent Cache URL file leaves cfg untouched")
PYEOF

echo "PASS: overlay simulation + proxy-persist functional tests"
