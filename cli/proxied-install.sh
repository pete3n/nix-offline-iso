# proxied-install: CLI NixOS installer for binary cache proxies. 
# Installs the Flake target the user cloned to /tmp/nix-cfg, pulling every 
# dependency through the cache proxy that proxy-setup declared. 
ROOT=/mnt
DISK=""
HOST=""
NO_DISKO=0
NO_VERIFY=0
CFG=""
CACHE_URL=""

# Test hook (tools/test-proxied-install.sh): relocate the system files this
# script reads and skip root-only steps, so the decision logic can run as a
# plain user inside a sandbox. Unset in production.
TEST_PREFIX="${NIX_PROXY_TEST_PREFIX:-}"
URL_FILE="${TEST_PREFIX:+$TEST_PREFIX/nix-cache-url}"
URL_FILE="${URL_FILE:-/run/nix-cache-url}"
PIN_FILE="${TEST_PREFIX:+$TEST_PREFIX/determinate-pin}"
PIN_FILE="${PIN_FILE:-/etc/determinate-pin}"

usage() {
  cat <<EOF
Usage: proxied-install [--disk /dev/DEVICE] [--host NAME] [--root DIR]
                       [--no-disko] [--no-verify] [--config DIR] [--cache-url URL]

  --disk DEV       Wipe DEV and create a single-disk layout (GPT: 1024MiB ESP
                   + ext4 root), mount it at --root, then install. DESTROYS
                   ALL DATA ON DEV. Omit to install into an already-mounted
                   --root (default /mnt).
  --host NAME      nixosConfigurations.<NAME> to install. Default: one named
                   "nixos", else the sole entry, else the current hostname.
  --root DIR       Target mount point (default /mnt).
  --no-disko       Do not let disko partition, even if the config declares a
                   layout. You must partition and mount yourself (or use
                   --disk); disko still owns the fileSystems config.
  --no-verify      Skip the post-install read-back verification of the
                   target's Nix store (it re-reads the copied closure from
                   disk to catch storage that silently loses writes).
  --config DIR     The Flake target to install (default /tmp/nix-cfg — where
                   the MOTD flow clones your Config repo).
  --cache-url URL  Override the Cache URL recorded by proxy-setup.

Run 'sudo proxy-setup' first: this installer refuses to start without a
declared, probed Cache URL — every dependency is pulled through it.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --disk) DISK="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    --no-disko) NO_DISKO=1; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --config) CFG="$2"; shift 2 ;;
    --cache-url) CACHE_URL="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$TEST_PREFIX" ] && [ "$(id -u)" -ne 0 ]; then
  echo "proxied-install must run as root (try: sudo proxied-install ...)" >&2
  exit 1
fi

# The Proxied install's gate: no declared Cache URL, no install. proxy-setup
# records the URL only after its Reachability probe passed and the live
# substituters were rerouted, so the file's existence means "setup done".
if [ -z "$CACHE_URL" ] && [ -r "$URL_FILE" ]; then
  CACHE_URL="$(head -n 1 "$URL_FILE")"
fi
if [ -z "$CACHE_URL" ]; then
  echo "No Cache URL. Run 'sudo proxy-setup' first (or pass --cache-url)." >&2
  exit 1
fi

# Every nix this script spawns must (a) have the flakes features on and
# (b) substitute through the cache proxy. The script's own `nix` is
# Determinate's client (system path, runtimeInputs deliberately carries no
# pkgs.nix), but nixos-install bundles an upstream nix internally, and
# upstream clients do not reliably read the Determinate-generated config
# Env-level config covers every client uniformly. Appended (not overwritten) 
# so any inherited NIX_CONFIG survives.
export NIX_CONFIG="${NIX_CONFIG:-}
extra-experimental-features = nix-command flakes
substituters = $CACHE_URL"

# Locate the flake target: the working copy the user cloned (or edited) 
# per the MOTD flow.
src="${CFG:-/tmp/nix-cfg}"
if [ ! -e "$src/flake.nix" ]; then
  echo "No flake.nix in $src." >&2
  echo "Clone your config repo first:  git clone <your-repo-url> $src" >&2
  echo "(This branch installs Flake targets only: a plain configuration.nix" >&2
  echo "cannot declare the proxied substituter and input URLs it needs.)" >&2
  exit 1
fi
echo ">> Using configuration from $src"

# Pin match (CONTEXT.md): Determinate's nix outputs are not substitutable
# from any anonymous cache. A config pinning the determinate rev this ISO
# was built with installs those outputs straight from the live store; any
# other pin means compiling Nix from source through the proxy. narHash is
# the identity — tarball locks carry no git rev, and the URL may
# legitimately differ while the content matches.
#
# A missing lock is NOT an error: locking at install time is just another
# fetch through the Cache proxy, and an unreachable input URL is an
# appliance allow-list concern that surfaces as an ordinary fetch error —
# never an installer gate. The check is simply skipped.
iso_pin=""
if [ -r "$PIN_FILE" ]; then
  iso_pin="$(grep '^narHash: ' "$PIN_FILE" | head -n 1 | cut -d' ' -f2)"
fi
cfg_pin=""
if [ ! -e "$src/flake.lock" ]; then
  echo ">> note: $src has no flake.lock — skipping the Pin match check. The"
  echo "   build resolves and locks the inputs through the Cache proxy, and"
  echo "   the installed /etc/nixos keeps the written lock (it is your clone:"
  echo "   commit it back to your Config repo for reproducible reinstalls)."
else
  cfg_pin="$(nix eval --raw --impure --expr "
    let
      lock = builtins.fromJSON (builtins.readFile \"$src/flake.lock\");
      ref = (lock.nodes.\${lock.root}.inputs or { }).determinate or null;
    in
    if ref == null || !builtins.isString ref then
      \"\"
    else
      (lock.nodes.\${ref}.locked or { }).narHash or \"\"
  " 2>/dev/null || true)"
fi
if [ ! -e "$src/flake.lock" ]; then
  : # note already printed above
elif [ -z "$iso_pin" ]; then
  echo ">> note: no readable $PIN_FILE on this installer; skipping the Pin"
  echo "   match check."
elif [ -z "$cfg_pin" ]; then
  echo ">> note: no 'determinate' input in $src/flake.lock — skipping the Pin"
  echo "   match check. (If the config uses Determinate under another input"
  echo "   name, a mismatched pin still compiles Nix from source.)"
elif [ "$cfg_pin" != "$iso_pin" ]; then
  echo "WARNING: Pin mismatch. Your config pins determinate"
  echo "           $cfg_pin"
  echo "         but this ISO was built with"
  echo "           $iso_pin"
  echo "         Determinate's nix is not on any anonymous cache, so this"
  echo "         install will COMPILE NIX FROM SOURCE through the proxy —"
  echo "         expect a long build. Pin the ISO's rev (shown in"
  echo "         $PIN_FILE) to install it from the live store instead."
  printf 'Type YES to continue anyway: '
  read -r confirm
  if [ "$confirm" != "YES" ]; then
    echo "aborted"
    exit 1
  fi
else
  echo ">> Pin match: the config pins the determinate this ISO carries."
fi

# Resolve the flake config to install when --host was not given: prefer one
# named "nixos", else the sole entry. Fall back to the hostname. The
# trailing `|| true` is load-bearing — this script runs under `set -e`
# (writeShellApplication), where a bare HOST="$(cmd)" assignment adopts the
# command's exit status, so a failing eval would abort the script here
# instead of falling through to the hostname fallback.
if [ -z "$HOST" ]; then
  echo ">> Resolving the install target from the flake (first use fetches"
  echo "   the flake's inputs through the Cache proxy)..."
  HOST="$(nix eval --raw "$src#nixosConfigurations" --apply '
    cfgs:
    let names = builtins.attrNames cfgs; in
    if cfgs ? nixos then "nixos"
    else if builtins.length names == 1 then builtins.head names
    else ""' 2>/dev/null || true)"
fi
if [ -z "$HOST" ]; then
  HOST="$(uname -n)"
fi
echo ">> Target config: nixosConfigurations.$HOST"

# One full module evaluation answers two pre-flight questions: does the
# config declare a disko layout (then disko owns partitioning), and do its
# declared substituters include the Cache URL (else the first rebuild after
# reboot cannot reach the proxy — persistence is declared in the Config
# repo, never injected here; see ADR 0003).
is_disko=0
subs_warned=0
echo ">> Evaluating nixosConfigurations.$HOST (full config evaluation — this"
echo "   can take minutes, and the first run fetches inputs through the"
echo "   Cache proxy; no output is normal)..."
eval_json="$(nix eval --json \
  "$src#nixosConfigurations.$HOST.config" \
  --apply 'cfg: {
    disko = cfg.system.build ? diskoScript;
    diskoDevices =
      if cfg.system.build ? diskoScript then
        map (disk: disk.device) (builtins.attrValues (cfg.disko.devices.disk or { }))
      else
        [ ];
    subs = cfg.nix.settings.substituters or [ ];
  }' 2>/dev/null || true)"
# The device list disko will wipe, extracted from the JSON without jq
# (space-separated; empty when unknown).
disko_devices="$(printf '%s' "$eval_json" \
  | grep -o '"diskoDevices":\[[^]]*\]' \
  | sed 's/.*\[//; s/\]//; s/"//g; s/,/ /g' || true)"
if [ -z "$eval_json" ]; then
  echo ">> note: could not evaluate the config here; skipping the disko and"
  echo "   substituter pre-flight checks (the build below will surface real"
  echo "   errors)."
else
  case "$eval_json" in
    *'"disko":true'*)
      if [ "$NO_DISKO" -eq 0 ]; then
        is_disko=1
      fi
      ;;
  esac
  if ! printf '%s' "$eval_json" | grep -qF "\"$CACHE_URL\""; then
    subs_warned=1
    echo "WARNING: the target's declared substituters do not include the"
    echo "         Cache URL used for this install ($CACHE_URL)."
    echo "         After reboot, the first nixos-rebuild will NOT reach the"
    echo "         Cache proxy. Declare it in your Config repo, e.g.:"
    echo "           nix.settings.substituters = [ \"http://nix-proxy.lan\" ];"
    echo "         (Also check the alias-vs-IP case: declaring the .lan name"
    echo "         while installing via IP means the name must resolve on"
    echo "         the installed machine.)"
  fi
fi

if [ "$is_disko" -eq 1 ]; then
  # disko owns the disk layout: it wipes the device(s) DECLARED IN THE CONFIG,
  # and --disk cannot redirect it. Silently proceeding on the declared disk
  # when the operator explicitly named a different one is how the wrong disk
  # gets erased — refuse instead.
  if [ -n "$DISK" ]; then
    echo "ERROR: --disk $DISK conflicts with this config's disko layout, which" >&2
    echo "partitions the device(s) it declares: ${disko_devices:-(unknown)}" >&2
    echo "Refusing to guess which disk you meant. Either:" >&2
    echo "  - re-run WITHOUT --disk to let disko wipe the declared device(s), or" >&2
    echo "  - edit the disko device in $src to $DISK and re-run, or" >&2
    echo "  - pass --no-disko (with --disk or manual partitioning); note the" >&2
    echo "    config's disko-declared fileSystems must still match what you make." >&2
    exit 1
  fi
  # A declared device that does not exist on this machine means the config was
  # written for different hardware (common in VMs: virtio disks appear as
  # /dev/vda, not /dev/sda). Catch it before disko tries to wipe anything.
  for device in $disko_devices; do
    if [ ! -e "$device" ]; then
      echo "ERROR: the config's disko layout declares $device, which does not" >&2
      echo "exist on this machine. Available disks:" >&2
      lsblk -dno NAME,SIZE,MODEL 2>/dev/null | sed 's/^/  /' >&2 || true
      echo "Edit the disko device in $src to match, then re-run." >&2
      exit 1
    fi
  done
  echo ">> disko target: this WIPES and partitions the disk(s) declared in your"
  echo "   config, then formats and mounts them at /mnt:"
  echo "     ${disko_devices:-(devices could not be determined from the config)}"
  printf 'Type YES to continue: '
  read -r confirm
  if [ "$confirm" != "YES" ]; then
    echo "aborted"
    exit 1
  fi
  echo ">> Resolving the disko script (re-evaluates the config, and may fetch"
  echo "   or build through the Cache proxy; takes a few minutes, then"
  echo "   partitioning starts)..."
  disko_script="$(nix build --no-link --print-out-paths \
    "$src#nixosConfigurations.$HOST.config.system.build.diskoScript")"
  "$disko_script"
  # disko mounts at its declared rootMountPoint (default /mnt).
  ROOT=/mnt
elif [ -n "$DISK" ]; then
  echo ">> This will ERASE all data on $DISK and create:"
  echo "     GPT  ->  1024MiB ESP (FAT32, /boot)  +  ext4 root (rest)"
  printf 'Type YES to continue: '
  read -r confirm
  if [ "$confirm" != "YES" ]; then
    echo "aborted"
    exit 1
  fi

  wipefs -a "$DISK"
  parted -s "$DISK" -- \
    mklabel gpt \
    mkpart ESP fat32 1MiB 1023MiB \
    set 1 esp on \
    mkpart root ext4 1023MiB 100%
  partprobe "$DISK" || true
  udevadm settle || true

  # nvme/mmc devices name partitions p1/p2; sd*/vd* name them 1/2.
  case "$DISK" in
    *[0-9]) part1="${DISK}p1"; part2="${DISK}p2" ;;
    *) part1="${DISK}1"; part2="${DISK}2" ;;
  esac

  # Wait for the partition device nodes to appear before touching them.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -b "$part1" ] && [ -b "$part2" ] && break
    udevadm settle || true
    sleep 1
  done

  # Scrub any leftover filesystem signatures inside the new partitions. Without
  # this, a residual FAT signature (e.g. from a previous ESP at this location)
  # makes `mount`'s blkid autodetection pick the wrong type and fail with
  # "FAT-fs: Can't find valid FAT filesystem" on the ext4 root.
  wipefs -a "$part1" "$part2"
  mkfs.fat -F 32 -n boot "$part1"
  mkfs.ext4 -F -L nixos "$part2"
  sync
  udevadm settle || true

  # Mount with explicit filesystem types so mount never guesses. Mount the ESP
  # with umask=0077 (owner-only) so the random seed isn't world-readable in the
  # window before nixos-install remounts it per the generated config.
  mount -t ext4 "$part2" "$ROOT"
  mkdir -p "$ROOT/boot"
  mount -t vfat -o umask=0077 "$part1" "$ROOT/boot"
fi

if ! mountpoint -q "$ROOT"; then
  echo "Nothing is mounted at $ROOT." >&2
  echo "Partition and mount your target there first, or pass --disk /dev/DEVICE." >&2
  exit 1
fi

if [ "$is_disko" -eq 1 ]; then
  # disko already declares every fileSystems entry, so nixos-generate-config
  # must NOT run — a second fileSystems."/" definition is an eval conflict. The
  # committed hardware-configuration.nix supplies kernel modules only.
  mkdir -p "$ROOT/etc/nixos"
  cp -rT "$src" "$ROOT/etc/nixos"
  chmod -R u+w "$ROOT/etc/nixos"
else
  nixos-generate-config --root "$ROOT"
  hw="$ROOT/etc/nixos/hardware-configuration.nix"
  # NixOS 26.05's nixos-generate-config records the ESP with fmask=0022 dmask=0022
  # (files 0644 — world-readable), which trips systemd-boot's random-seed warning.
  sed -i 's/\(fmask\|dmask\|umask\)=0022/\1=0077/g' "$hw"
  hw_saved="$(mktemp)"
  cp "$hw" "$hw_saved"
  cp -rT "$src" "$ROOT/etc/nixos"
  chmod -R u+w "$ROOT/etc/nixos"
  cp -f "$hw_saved" "$hw"
  rm -f "$hw_saved"
fi

# Building here (not via `nixos-install --flake`/chroot) keeps the build in
# the live store, whose substituters point at the Cache proxy (both via
# proxy-setup's reroute and this script's NIX_CONFIG); `--system` then just
# copies the closure onto the target.
echo ">> Building nixosConfigurations.$HOST through the Cache proxy"
top="$(nix build --no-link --print-out-paths \
  "$ROOT/etc/nixos#nixosConfigurations.$HOST.config.system.build.toplevel")"

# --no-channel-copy: a flake-managed system has no use for a root channel,
# and copying one would realize the channel derivation inside the target
# chroot for nothing.
nixos-install --system "$top" --root "$ROOT" --no-root-passwd --no-channel-copy

# Read the installed store back from disk before declaring success. A
# completed install only proves the closure existed in the page cache;
# storage that silently loses writeback (thin-provisioned pools out of real
# space, VM disk cache modes that drop flushes, failing media) surfaces
# after reboot as "invalid ELF header" in random binaries. Dropping the page
# cache forces the verification to read the platter, not the cache.
if [ "$NO_VERIFY" -eq 0 ]; then
  echo ">> Verifying the installed store (read-back from disk; takes a minute)..."
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  if ! nix store verify --offline --store "$ROOT" --all --no-trust; then
    echo "ERROR: the installed Nix store failed read-back verification:" >&2
    echo "data written during this install did not survive on disk. Common" >&2
    echo "causes: a thin-provisioned/overcommitted disk that ran out of real" >&2
    echo "space mid-write, a VM disk cache mode that loses flushes, or" >&2
    echo "failing media. Do NOT boot this system; fix the storage and" >&2
    echo "re-run the install." >&2
    exit 1
  fi
  echo ">> Store verification passed."
fi

echo ">> Installation complete."
if [ "$subs_warned" -eq 1 ]; then
  echo "REMINDER: the installed system's declared substituters do not include"
  echo "          $CACHE_URL — fix your Config repo before the first rebuild,"
  echo "          or it will not reach the Cache proxy."
fi
echo ">> Reboot into your new system. Log in with the credentials from your"
echo "   configuration; rebuilds substitute through the Cache proxy your"
echo "   config declares."
