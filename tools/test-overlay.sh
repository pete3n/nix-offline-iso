#!/usr/bin/env bash
# Simulate the calamares-nixos-extensions overlay postInstall from the
# nixos-graphical-proxied variant (variants/nixos-graphical-proxied/iso.nix)
# against a real extensions source tree, without building anything. Catches
# the anchor/guard drift class of break (which bit the graphical branch
# twice) and functionally exercises the injected proxy-persist logic.
#
# Usage:
#   tools/test-overlay.sh /path/to/calamares-nixos-extensions/src
#
# The argument is the extensions source directory (the one containing
# modules/, config/, branding/) e.g. pkgs/by-name/ca/calamares-nixos-extensions/src
# in the pinned nixpkgs, or a checkout of the upstream repo.
set -euo pipefail

snap=${1:?usage: test-overlay.sh /path/to/calamares-nixos-extensions/src}
flake_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stand-in for the ${final.glibcLocales} store path.
fake_locales=/nix/store/00000000000000000000000000000000-fake-glibc-locales

# Cut everything before the extensions attr first so the range match lands on the right one.
sed -n '/calamares-nixos-extensions = prev.calamares-nixos-extensions.overrideAttrs/,$p' \
    "$flake_dir/variants/nixos-graphical-proxied/iso.nix" \
  | sed -n "/postInstall = (old.postInstall or/,/^      '';/{p; /^      '';/q}" \
  | sed '1d;$d' \
  | sed "s|\${../../calamares/welcome-proxied.conf}|$flake_dir/calamares/welcome-proxied.conf|g
         s|\${../../calamares/locale.conf}|$flake_dir/calamares/locale.conf|g
         s|\${../../calamares/inject/proxy-persist.py}|$flake_dir/calamares/inject/proxy-persist.py|g
         s|\${final.glibcLocales}|$fake_locales|g" \
  > "$work/postinstall.sh"

# Any leftover interpolation means flake.nix gained one this script does not
# know how to resolve: update the sed above.
# shellcheck disable=2016
if grep -n '\${' "$work/postinstall.sh"; then
  echo "FAIL: unresolved Nix interpolation in extracted postInstall"; exit 1
fi

out=$work/out
mkdir -p "$out/etc/calamares" "$out/lib/calamares" "$out/share/calamares"
cp -r "$snap/modules" "$out/lib/calamares/"
cp -r "$snap/config/." "$out/etc/calamares/"
cp -r "$snap/branding" "$out/share/calamares/"
chmod -R u+w "$out"
# The stock installPhase substitutes these before postInstall runs.
# Replicate so the overlay's own re-substitution of locale.conf is tested correctly.
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

# shellcheck disable=1091
. "$work/postinstall.sh"
echo "ok: postInstall ran to completion"

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
  grep -qE "^[[:space:]]*-[[:space:]]*${keep}[[:space:]]*\$" "$s" \
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
write_url("http://nix-proxy.lan\n")
cfg, warnings = run_block()
assert 'nix.settings.substituters = [ "http://nix-proxy.lan" ];' in cfg, cfg

# Validate the persisted settings the way the target itself will: the
# pkgs.formats.nixConf checkPhase runs `nix config show` with only the
# nix-command feature and promotes warnings to errors, inside
# nixos-install. This is the check that caught flake-registry being
# flakes-gated on a flakes-disabled target.
import os
import shutil
import subprocess
import tempfile

if shutil.which("nix"):
    conf_lines = []
    for line in cfg.splitlines():
        stripped = line.strip()
        if not stripped.startswith("nix.settings."):
            continue
        key, _, value = stripped[len("nix.settings."):].partition(" = ")
        value = value.rstrip(";").strip()
        if value.startswith("["):
            value = " ".join(
                part.strip().strip('"') for part in value.strip("[]").split()
            )
        else:
            value = value.strip('"')
        conf_lines.append("{} = {}".format(key, value))
    assert conf_lines, "expected at least one persisted nix.settings line"
    conf_dir = tempfile.mkdtemp()
    with open(os.path.join(conf_dir, "nix.conf"), "w") as conf_fh:
        conf_fh.write("\n".join(conf_lines) + "\n")
    check_env = {
        key: value
        for key, value in os.environ.items()
        if key not in ("NIX_CONFIG", "NIX_USER_CONF_FILES")
    }
    check_env["NIX_CONF_DIR"] = conf_dir
    result = subprocess.run(
        ["nix", "config", "show", "--no-net",
         "--option", "experimental-features", "nix-command"],
        capture_output=True, text=True, env=check_env,
    )
    problems = [
        line
        for line in (result.stderr + result.stdout).splitlines()
        if line.startswith(("warning:", "error:"))
    ]
    assert result.returncode == 0 and not problems, problems or result.stderr
    print("ok: persisted settings pass the target's nix.conf validation")
else:
    print("SKIP: nix not on PATH; target nix.conf validation not simulated")
assert cfg.startswith("BASE\n") and not warnings
print("ok: valid Cache URL appended to cfg")

# Case 2: IP:port form survives the validation.
write_url("http://192.168.100.5:80")
cfg, warnings = run_block()
assert '[ "http://192.168.100.5:80" ]' in cfg and not warnings
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

# Simulate the calamares-nixos desktop-entry patch against a fixture:
# The real calamares.desktop only exists in the built package; this tests
# capture/generate/rewrite logic against the Exec shape upstream ships
# (sh -c + pkexec). The build-time guards catch any upstream changes.
fake_proxy_screen=/nix/store/00000000000000000000000000000000-proxy-screen/bin/proxy-screen

sed -n '/calamares-nixos = prev.calamares-nixos.overrideAttrs/,$p' "$flake_dir/variants/nixos-graphical-proxied/iso.nix" \
  | sed -n "/postInstall = (old.postInstall or/,/^      '';/{p; /^      '';/q}" \
  | sed '1d;$d' \
  | sed "s|\${../../calamares/proxy-screen-launch.in}|$flake_dir/calamares/proxy-screen-launch.in|g
         s|\${final.proxy-screen}/bin/proxy-screen|$fake_proxy_screen|g" \
  > "$work/desktop-patch.sh"
# shellcheck disable=2016
if grep -n '\${' "$work/desktop-patch.sh"; then
  echo "FAIL: unresolved Nix interpolation in extracted desktop patch"; exit 1
fi

# stdenv's substitute, reduced to the --subst-var-by form.
substitute() {
  local src=$1 dst=$2; shift 2
  cp "$src" "$dst"
  while [ $# -gt 0 ]; do
    [ "$1" = --subst-var-by ] || { echo "substitute stub: unsupported $1"; return 1; }
    python3 -c 'import sys; p, f, t = sys.argv[1:4]; s = open(p).read(); open(p, "w").write(s.replace(f, t))' \
      "$dst" "@$2@" "$3"
    shift 3
  done
}

out=$work/calamares-out
mkdir -p "$out/share/applications" "$out/bin"
cat > "$out/share/applications/calamares.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Install System
Exec=sh -c "pkexec calamares"
Icon=calamares
DESKTOP


# shellcheck disable=1091
. "$work/desktop-patch.sh"

launcher=$out/bin/proxy-screen-launch
[ -x "$launcher" ] || { echo "FAIL: launcher not generated/executable"; exit 1; }
grep -qF "$fake_proxy_screen || exit \$?" "$launcher" \
  || { echo "FAIL: launcher does not gate on the Proxy screen"; exit 1; }
grep -qF 'exec sh -c "pkexec calamares"' "$launcher" \
  || { echo "FAIL: launcher lost the stock Exec command"; exit 1; }
grep -q "^Exec=$out/bin/proxy-screen-launch$" "$out/share/applications/calamares.desktop" \
  || { echo "FAIL: desktop Exec not rewritten to the launcher"; exit 1; }
sh -n "$launcher"
echo "ok: desktop entry rewired; generated launcher gates and preserves stock Exec"

echo "PASS: overlay simulation + proxy-persist + desktop-entry tests"
