# shellcheck disable=2148
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
                       [--no-disko] [--no-verify] [--config DIR | --flake REF]
                       [--cache-url URL]

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
  --flake REF      Flake-ref install (see CONTEXT.md): build the committed
                   rev straight from a flake reference to your Config repo
                   (e.g. 'git+ssh://git.lan/srv/git/nix.git'), cloning
                   nothing. The ref must already commit this host's hardware
                   config or a disko layout — there is no generate-and-merge
                   — and the Target keeps no /etc/nixos checkout (it rebuilds
                   by ref). For SSH refs, put the key in root's ~/.ssh/config
                   (a Host entry with IdentityFile): nix's git fetcher
                   ignores GIT_SSH_COMMAND.
  --cache-url URL  Override the Cache URL recorded by proxy-setup.

Run 'sudo proxy-setup' first: this installer refuses to start without a
declared, probed Cache URL — every dependency is pulled through it.
EOF
}

FLAKE_REF=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --disk) DISK="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    --no-disko) NO_DISKO=1; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --config) CFG="$2"; shift 2 ;;
    --flake) FLAKE_REF="$2"; shift 2 ;;
    --cache-url) CACHE_URL="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

# One source per install: a working copy or a flake ref, never both.
if [ -n "$FLAKE_REF" ] && [ -n "$CFG" ]; then
  echo "--flake and --config conflict: pick the working copy or the ref." >&2
  exit 1
fi

if [ -z "$TEST_PREFIX" ] && [ "$(id -u)" -ne 0 ]; then
  echo "proxied-install must run as root (try: sudo proxied-install ...)" >&2
  exit 1
fi

# The proxied install's check: no declared cache URL, no install. proxy-setup
# records the URL only after its connectivity check passed and the live
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

# Default to turning of Determinate telemetry (it wouldn't reach them anyway).
export DETSYS_IDS_TELEMETRY=disabled

# Locate the flake target: a flake ref straight to the config repo, or the 
# working copy the user cloned (and maybe edited) per the MOTD flow. 
if [ -n "$FLAKE_REF" ]; then
  src="$FLAKE_REF"
  echo ">> Flake-ref install from $src"
  echo "   The committed rev is what installs: this host's hardware config"
  echo "   (or a disko layout) must already be committed, but nothing is"
  echo "   generated or merged, and the target keeps no /etc/nixos"
  echo "   checkout: it rebuilds by ref."
  echo "   A committed flake.lock is strongly recommended here: a lockless"
  echo "   ref resolves its inputs NOW and records the result nowhere (no"
  echo "   working copy exists to keep a written lock)."
else
	# Locate the flake target: the working copy the user cloned (or edited) 
	# per the MOTD flow.
  src="${CFG:-/tmp/nix-cfg}"
  if [ ! -e "$src/flake.nix" ]; then
    echo "No flake.nix in $src." >&2
    echo "Clone your Config repo first:  git clone <your-repo-url> $src" >&2
    echo "(or install a committed rev without cloning: --flake REF; see" >&2
    echo "--help for the SSH key setup that needs)" >&2
    echo "(This branch installs Flake targets only: a plain configuration.nix" >&2
    echo "cannot declare the proxied substituter and input URLs it needs.)" >&2
    exit 1
  fi
  echo ">> Using configuration from $src"
fi

# Determinate's nix outputs are not substitutable from any anonymous cache. 
# A config pinning the determinate rev this ISO was built with installs those 
# outputs straight from the live store; any other pin means compiling Nix from 
# source through the proxy.
#
# A missing lock is not an error: locking at install time is just another
# fetch through the cache proxy, and an unreachable input URL is a proxy 
# allow-list concern that creates a fetch error. This isn't an installer
# concern, so the check is skipped.
# A remote ref is read-only for nix: it cannot write back a freshly
# resolved lock, and without this flag a lockless ref dies with "cannot
# write modified lock file" instead of installing. The clone flow keeps the
# write on purpose — the installed /etc/nixos keeps the written lock so it
# can be committed back to the Config repo.
lock_flags=()
if [ -n "$FLAKE_REF" ]; then
  lock_flags+=(--no-write-lock-file)
  # nix caches git ref resolution (~1h TTL): without this, "install main"
  # can silently install a rev cached from an earlier attempt instead of
  # the tip just pushed. An installer must install the ref as of NOW.
  lock_flags+=(--refresh)
fi

iso_pin=""
if [ -r "$PIN_FILE" ]; then
  iso_pin="$(grep '^narHash: ' "$PIN_FILE" | head -n 1 | cut -d' ' -f2)"
fi
cfg_pin=""
pin_skipped=0
if [ -n "$FLAKE_REF" ]; then
  # A ref has no local lock to read: `nix flake metadata` fetches the flake
  # which is the first LAN/SSH touch of this install. This should fail loudly 
	# and early with the key hint. A lockless repo resolves its inputs through the 
	# cache proxy, the same install-time locking the clone method uses.
  meta_json="$(mktemp)"
  if ! nix flake metadata "${lock_flags[@]}" --json "$src" > "$meta_json" 2> "$meta_json.err"; then
    echo "Could not fetch the flake at $src:" >&2
    sed 's/^/  /' "$meta_json.err" >&2 || true
    echo "For git+ssh refs, nix's git fetcher ignores GIT_SSH_COMMAND: the" >&2
    echo "Provisioning key must come from root's ~/.ssh/config (a Host entry" >&2
    echo "with IdentityFile). Check the LAN git host is reachable, then" >&2
    echo "re-run." >&2
    rm -f "$meta_json" "$meta_json.err"
    exit 1
  fi
  rm -f "$meta_json.err"
  cfg_pin="$(nix eval --raw --impure --expr "
    let
      lock = (builtins.fromJSON (builtins.readFile \"$meta_json\")).locks;
      ref = (lock.nodes.\${lock.root}.inputs or { }).determinate or null;
    in
    if ref == null || !builtins.isString ref then
      \"\"
    else
      (lock.nodes.\${ref}.locked or { }).narHash or \"\"
  " 2>/dev/null || true)"
  rm -f "$meta_json"
elif [ ! -e "$src/flake.lock" ]; then
  pin_skipped=1
  echo ">> note: $src has no flake.lock — skipping the pin match check. The"
  echo "   build resolves and locks the inputs through the cache proxy, and"
  echo "   the installed /etc/nixos keeps the written lock (it is your clone:"
  echo "   commit it back to your config repo for reproducible reinstalls)."
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
if [ "$pin_skipped" -eq 1 ]; then
  : # note already printed above
elif [ -z "$iso_pin" ]; then
  echo ">> note: no readable $PIN_FILE on this installer; skipping the pin"
  echo "   match check."
elif [ -z "$cfg_pin" ]; then
  echo ">> note: no 'determinate' input in the lock of $src — skipping the"
  echo "   pin match check. (If the config uses Determinate under another"
  echo "   input name, a mismatched pin still compiles Nix from source.)"
elif [ "$cfg_pin" != "$iso_pin" ]; then
  echo "WARNING: Pin mismatch. Your config pins determinate"
  echo "           $cfg_pin"
  echo "         but this ISO was built with"
  echo "           $iso_pin"
  echo "         Determinate's nix is not on any anonymous cache, so this"
  echo "         install will COMPILE NIX FROM SOURCE through the proxy: "
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
# trailing `|| true` is required because this script runs under `set -e`
# (writeShellApplication), where a bare HOST="$(cmd)" assignment adopts the
# command's exit status, so a failing eval would abort the script here
# instead of falling through to the hostname fallback.
if [ -z "$HOST" ]; then
  echo ">> Resolving the install target from the flake (first use fetches"
  echo "   the flake's inputs through the Cache proxy)..."
  HOST="$(nix eval --raw "${lock_flags[@]}" "$src#nixosConfigurations" --apply '
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

# One full module evaluation answers two pre-install questions: does the
# config declare a disko layout (then disko owns partitioning), and do its
# declared substituters include the cache URL (else the first rebuild after
# reboot cannot reach the proxy.
is_disko=0
subs_warned=0
echo ">> Evaluating nixosConfigurations.$HOST (full config evaluation, this"
echo "   can take minutes, and the first run fetches inputs through the"
echo "   cache proxy; no output is normal)..."
eval_json="$(nix eval --json "${lock_flags[@]}" \
  "$src#nixosConfigurations.\"$HOST\".config" \
  --apply 'cfg: {
    disko = cfg.system.build ? diskoScript;
    diskoDevices =
      if cfg.system.build ? diskoScript then
        map (disk: disk.device) (builtins.attrValues (cfg.disko.devices.disk or { }))
      else
        [ ];
    subs = cfg.nix.settings.substituters or [ ];
    # nixos-install runs --no-root-passwd on purpose (credentials are
    # declared, never typed at install) — so a config in which no user
    # carries any credential produces a perfect, unloggable system.
    loginOk = builtins.any (
      user:
      (user.hashedPassword or null) != null
      || (user.password or null) != null
      || (user.initialPassword or null) != null
      || (user.initialHashedPassword or null) != null
      || (user.hashedPasswordFile or null) != null
      || (user.openssh.authorizedKeys.keys or [ ]) != [ ]
      || (user.openssh.authorizedKeys.keyFiles or [ ]) != [ ]
    ) (builtins.attrValues (cfg.users.users or { }));
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
  if printf '%s' "$eval_json" | grep -qF '"loginOk":false'; then
    echo "WARNING: no user in this config declares any login credential"
    echo "         (hashed/initial password, password file, or SSH key)."
    echo "         The installer never sets a root password (--no-root-passwd:"
    echo "         credentials are declared, not typed), so the installed"
    echo "         system may be impossible to log in to. Declare a user"
    echo "         credential in your Config repo. (Ignore this if login is"
    echo "         provided by a mechanism this check cannot see, e.g. LDAP.)"
  fi
  if ! printf '%s' "$eval_json" | grep -qF "\"$CACHE_URL\""; then
    subs_warned=1
    echo "WARNING: the target's declared substituters do not include the"
    echo "         cache URL used for this install ($CACHE_URL)."
    echo "         After reboot, the first nixos-rebuild will not reach the"
    echo "         cache proxy. Declare it in your config repo, e.g.:"
    echo "           nix.settings.substituters = [ \"$CACHE_URL\" ];"
    echo "         (Also check the alias-vs-IP case: declaring the .lan name"
    echo "         while installing via IP means the name must resolve on"
    echo "         the installed machine.)"
  fi
fi

if [ "$is_disko" -eq 1 ]; then
  # disko owns the disk layout: it wipes the device(s) declared in the config,
  # and --disk cannot redirect it. Silently proceeding on the declared disk
  # when the user explicitly named a different one. Prevent the wrong disk from
	# getting erased by refusing this operations.
  if [ -n "$DISK" ]; then
    echo "ERROR: --disk $DISK conflicts with this config's disko layout, which" >&2
    echo "partitions the device(s) it declares: ${disko_devices:-(unknown)}" >&2
    echo "Refusing to guess which disk you meant. Either:" >&2
    echo "  - re-run without --disk to let disko partition the declared device(s), or" >&2
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
  echo ">> disko target: this ERASES and partitions the disk(s) declared in your"
  echo "   config, then formats and mounts them at /mnt:"
  echo "     ${disko_devices:-(devices could not be determined from the config)}"
  printf 'Type YES to continue: '
  read -r confirm
  if [ "$confirm" != "YES" ]; then
    echo "aborted"
    exit 1
  fi
  echo ">> Resolving the disko script (re-evaluates the config, and may fetch"
  echo "   or build through the cache proxy; takes a few minutes, then"
  echo "   partitioning starts)..."
  disko_script="$(nix build --no-link --print-out-paths --print-build-logs "${lock_flags[@]}" \
    "$src#nixosConfigurations.\"$HOST\".config.system.build.diskoScript")"
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

if [ -n "$FLAKE_REF" ]; then
  # Flake-ref install: nothing lands in /etc/nixos, and the committed rev is 
	# the only source. The target rebuilds by ref, and nixos-generate-config is 
	# not utilized. There is no working copy to merge its output into, which is 
	# why the ref must commit this host's hardware config (or a disko layout, 
	# which skips generation in every mode).
  build_src="$src"
elif [ "$is_disko" -eq 1 ]; then
  # disko already declares every fileSystems entry, so nixos-generate-config
  # must NOT run a second fileSystems. "/" definition is an eval conflict. The
  # committed hardware-configuration.nix supplies kernel modules only.
  mkdir -p "$ROOT/etc/nixos"
  cp -rT "$src" "$ROOT/etc/nixos"
  chmod -R u+w "$ROOT/etc/nixos"
  build_src="$ROOT/etc/nixos"
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
  build_src="$ROOT/etc/nixos"
fi

# Building here (not via `nixos-install --flake`/chroot) keeps the build in
# the live store, whose substituters point at the Cache proxy (both via
# proxy-setup's reroute and this script's NIX_CONFIG); `--system` then just
# copies the closure onto the target.
echo ">> Building nixosConfigurations.$HOST through the cache proxy"
top="$(nix build --no-link --print-out-paths --print-build-logs "${lock_flags[@]}" \
  "$build_src#nixosConfigurations.\"$HOST\".config.system.build.toplevel")"

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
  echo "          $CACHE_URL — fix your config repo before the first rebuild,"
  echo "          or it will not reach the cache proxy."
fi
if [ -n "$FLAKE_REF" ]; then
  echo ">> Flake-ref install: this system keeps no /etc/nixos checkout."
  echo "   Rebuild it by ref, e.g."
  echo "     nixos-rebuild switch --flake '$src#\"$HOST\"'"
  echo "   Repo access on the installed machine comes from what its own"
	echo "   configuration declares (keys, known hosts), nothing was copied"
  echo "   from this installer environment."
fi
echo ">> Reboot into your new system. Log in with the credentials from your"
echo "   configuration; rebuilds substitute through the cache proxy your"
echo "   config declares."
