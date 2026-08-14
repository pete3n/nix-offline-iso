#!/usr/bin/env bash
# Argument-safety regression test for cli/offline-install.sh
# Any stubbed destructive call is recorded and fails the test. 
# Ensures that the manual --disk partitioning flag cannot be used with a disko
# configuration and vice-versa.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
installer=$script_dir/../cli/offline-install.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/offline-install-args.XXXXXX")
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/cfg"
touch "$work/cfg/flake.nix"
destructive_log=$work/destructive.log
: > "$destructive_log"

# Root check passes without root.
printf '#!/usr/bin/env bash\necho 0\n' > "$work/bin/id"

# Checks the two evaluations the installer makes: host resolution and the
# disko probe. TEST_DISKO_PROBE carries the probe answer (device list or the
# @no-disko@ sentinel).
cat > "$work/bin/nix" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *nixosConfigurations.nixos.config*) printf '%s' "${TEST_DISKO_PROBE:-@no-disko@}" ;;
  *nixosConfigurations*) printf 'nixos' ;;
  *) echo "unexpected nix invocation in test: $*" >&2; exit 99 ;;
esac
EOF

# Destructive tools: record and pretend to succeed. Any entry in the log
# means the installer touched a disk before it should have.
for tool in wipefs parted partprobe mkfs.fat mkfs.ext4 mount nixos-install nixos-generate-config; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> %q\n' "$tool" "$destructive_log" > "$work/bin/$tool"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/udevadm"
printf '#!/usr/bin/env bash\necho "  sda 10G TESTDISK"\n' > "$work/bin/lsblk"
chmod +x "$work/bin/"*

overall=0
# run_installer <case> <expected-exit> <stdin> <must-match-regex> [args...]
run_installer() {
  local case_name=$1 expected_exit=$2 stdin_text=$3 must_match=$4
  shift 4
  local out_log=$work/$case_name.log rc=0
  PATH="$work/bin:$PATH" TEST_DISKO_PROBE="${TEST_DISKO_PROBE:-@no-disko@}" \
    bash -e -u -o pipefail "$installer" --config "$work/cfg" "$@" \
    <<< "$stdin_text" > "$out_log" 2>&1 || rc=$?
  if [ "$rc" != "$expected_exit" ]; then
    echo ">> [$case_name] FAIL: exit $rc, expected $expected_exit"
    sed 's/^/   | /' "$out_log" | tail -6
    overall=1
    return
  fi
  # must_match is one or more line regexes joined with '&&'.
  local pattern
  while IFS= read -r pattern; do
    if ! grep -qE "$pattern" "$out_log"; then
      echo ">> [$case_name] FAIL: output does not match: $pattern"
      sed 's/^/   | /' "$out_log" | tail -6
      overall=1
      return
    fi
  done < <(sed 's/ *&& */\n/g' <<< "$must_match")
  echo ">> [$case_name] PASS"
}

# 1. Explicit --disk against a disko target must hard-error, naming
# both the requested and the declared devices.
TEST_DISKO_PROBE="/dev/testdisk-declared" \
  run_installer disk-vs-disko 1 "" \
  "disk /dev/vda conflicts with this config's disko layout && declares: /dev/testdisk-declared" \
  --disk /dev/vda

# 2. A declared device absent from this machine fails before the prompt.
TEST_DISKO_PROBE="/dev/testdisk-declared" \
  run_installer disko-missing-device 1 "" "declares /dev/testdisk-declared, which does not"

# 3. The disko prompt names the device(s) it will wipe; declining aborts.
TEST_DISKO_PROBE="/dev/null" \
  run_installer disko-names-devices 1 "no" 'WIPES and partitions && ^     /dev/null$ && aborted'

# 4. Plain --disk without disko still reaches its own confirm; declining aborts.
TEST_DISKO_PROBE="@no-disko@" \
  run_installer plain-disk 1 "no" "ERASE all data on /dev/vda"  --disk /dev/vda

# 5. The double-override (--no-disko --disk) skips the disko probe
#    and uses the --disk path.
TEST_DISKO_PROBE="/dev/testdisk-declared" \
  run_installer no-disko-override 1 "no" "ERASE all data on /dev/vda" --no-disko --disk /dev/vda

if [ -s "$destructive_log" ]; then
  echo ">> FAIL: destructive tools were invoked:"
  sed 's/^/   | /' "$destructive_log"
  overall=1
fi

if [ "$overall" -eq 0 ]; then
  echo "PASS: offline-install argument safety"
else
  echo "FAIL: see cases above" >&2
fi
exit "$overall"
