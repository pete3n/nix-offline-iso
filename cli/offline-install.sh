# offline-install — minimal CLI offline NixOS installer (nix-offline-iso).
#

ROOT=/mnt
DISK=""
HOST=""
NO_DISKO=0

usage() {
  cat <<EOF
Usage: offline-install [--disk /dev/DEVICE] [--host NAME] [--root DIR] [--no-disko]

  --disk DEV   Wipe DEV and create a single-disk layout (GPT: 1024MiB ESP + ext4
               root), mount it at --root, then install. DESTROYS ALL DATA ON DEV.
               Omit to install into an already-mounted --root (default /mnt).
  --host NAME  Flake configs only: nixosConfigurations.<NAME> to install.
               Default: the sole nixosConfigurations entry, or one named
               "nixos" — matching the config the ISO baked. Falls back to the
               current hostname if neither applies.
  --root DIR   Target mount point (default /mnt).
  --no-disko   Flake configs only: do not let disko partition, even if the
               config declares a layout. You must partition and mount yourself
               (or use --disk); disko still owns the fileSystems config.

If the flake config declares a disko layout, disko partitions, formats and
mounts the disk(s) it describes (at /mnt) — --disk and manual partitioning are
not used, and nixos-generate-config is skipped (disko owns fileSystems).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --disk) DISK="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    --no-disko) NO_DISKO=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "offline-install must run as root (try: sudo offline-install ...)" >&2
  exit 1
fi

# Locate the configuration source. /tmp/nix-cfg (editable copy seeded at boot)
# wins over the baked-in read-only /iso/nix-cfg. Found before partitioning
# because a disko target partitions the disk(s) declared in this config.
src=/tmp/nix-cfg
if [ ! -e "$src/configuration.nix" ] && [ ! -e "$src/flake.nix" ]; then
  src=/iso/nix-cfg
fi
if [ ! -e "$src/configuration.nix" ] && [ ! -e "$src/flake.nix" ]; then
  echo "No configuration.nix or flake.nix in /tmp/nix-cfg or /iso/nix-cfg." >&2
  exit 1
fi
echo ">> Using configuration from $src"

# Resolve the flake config to install when --host was not given. Mirror the
# builder's pick so we target the config whose closure is actually baked into
# the ISO: prefer one named "nixos", else the sole entry. Fall back to the
# hostname (e.g. a channels target, or a resolution failure) so behaviour is
# never worse than before.
if [ -z "$HOST" ] && [ -e "$src/flake.nix" ]; then
  echo ">> Resolving the install target from the flake (offline evaluation)..."
  # Best-effort: pick the baked config's name. The trailing `|| true` is load-
  # bearing — this script runs under `set -e` (writeShellApplication), and a
  # bare `HOST="$(cmd)"` assignment adopts the command's exit status, so a
  # non-zero `nix eval` (e.g. an input that won't resolve offline) would abort
  # the whole script here instead of falling through to the hostname fallback
  # below. Keep the failure from being fatal and silent.
  HOST="$(nix eval --offline --raw "$src#nixosConfigurations" --apply '
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

# Detect a disko target: a flake whose selected config exposes a disko layout
# (system.build.diskoScript). Such a config owns BOTH the partition layout and
# the fileSystems config, so we let disko do the partitioning/mounting and skip
# the imperative parted + nixos-generate-config path entirely.
is_disko=0
if [ "$NO_DISKO" -eq 0 ] && [ -e "$src/flake.nix" ]; then
  # This eval forces the full NixOS module evaluation of the selected config.
  # `nix eval` prints nothing while it works and its stderr is discarded below,
  # so without a heads-up the console just sits blank for minutes before the
  # disk-erase prompt appears.
  echo ">> Evaluating nixosConfigurations.$HOST (full config evaluation --"
  echo "   this can take a few minutes on live media; no output is normal)..."
  if [ "$(nix eval --offline --raw \
            "$src#nixosConfigurations.$HOST.config.system.build" \
            --apply 'build: if build ? diskoScript then "yes" else "no"' \
            2>/dev/null)" = "yes" ]; then
    is_disko=1
  fi
fi

if [ "$is_disko" -eq 1 ]; then
  # disko owns the disk layout; our simple --disk layout would conflict with it.
  if [ -n "$DISK" ]; then
    echo "Ignoring --disk $DISK: this is a disko target and partitions the" >&2
    echo "disk(s) declared in its config. Pass --no-disko to override." >&2
  fi
  echo ">> disko target: this WIPES and partitions the disk(s) declared in your"
  echo "   config, then formats and mounts them at /mnt."
  printf 'Type YES to continue: '
  read -r confirm
  if [ "$confirm" != "YES" ]; then
    echo "aborted"
    exit 1
  fi
  # diskoScript's output is baked into the ISO store, so the build itself is
  # just a store lookup — but `nix build` still re-evaluates the config to
  # find that path, which is another silent multi-minute wait.
  echo ">> Resolving the disko script (re-evaluates the config; takes a few"
  echo "   minutes, then partitioning starts)..."
  disko_script="$(nix build --offline --no-link --print-out-paths \
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

# Building here (not via `nixos-install --flake`/chroot) keeps the build in the
# store that actually has the inputs; `--system` then just copies the closure.
if [ -e "$ROOT/etc/nixos/flake.nix" ]; then
  echo ">> Flake install: building nixosConfigurations.$HOST in the live store"
  top="$(nix build --offline --no-link --print-out-paths \
    "$ROOT/etc/nixos#nixosConfigurations.$HOST.config.system.build.toplevel")"
else
  echo ">> Channels install: building the system in the live store"
  top="$(nix-build --no-out-link \
    '<nixpkgs/nixos>' -A system \
    -I "nixos-config=$ROOT/etc/nixos/configuration.nix")"
fi

# Flake targets have no use for a root channel, and copying one realizes the
# channel derivation inside the target chroot with the *target's* nix.conf
# (default substituter cache.nixos.org) — a real network attempt when offline.
# Channels targets NEED the channel copy: it is exactly what `nixos-rebuild`
# evaluates after reboot, so keep it for them (the realization resolves from
# local paths; only the substituter probe warns).
if [ -e "$ROOT/etc/nixos/flake.nix" ]; then
  nixos-install --system "$top" --root "$ROOT" --no-root-passwd --no-channel-copy
else
  nixos-install --system "$top" --root "$ROOT" --no-root-passwd
fi

# Seed the target store with the flake's input source trees so the installed
# system can re-evaluate its own flake offline. The baked flake.lock pins every
# input to a /nix/store/*-source path that lives in this installer's store (it
# was seeded into the ISO) but is only consumed at evaluation time.
if [ -e "$ROOT/etc/nixos/flake.nix" ]; then
  echo ">> Copying flake input sources into the target store (for offline rebuilds)"
  # Pull every path-pinned input out of the baked lock. Non-path nodes (and the
  # lockfile root node, which has no `locked`) fall through to null via `or` and
  # are filtered out.
  mapfile -t src_paths < <(
    nix eval --offline --raw --impure --expr "
      let lock = builtins.fromJSON (builtins.readFile \"$ROOT/etc/nixos/flake.lock\");
      in builtins.concatStringsSep \"\n\" (
        builtins.filter (path: path != null)
          (map (node: node.locked.path or null) (builtins.attrValues lock.nodes)))
    "
  )
  if [ "${#src_paths[@]}" -gt 0 ]; then
    # `--to "$ROOT"`: a bare path is a chroot local store rooted there, so this
    # populates $ROOT/nix/store and registers the paths in the target's Nix DB.
    nix copy --offline --no-check-sigs --to "$ROOT" "${src_paths[@]}"
  fi
fi

echo ">> Installation complete. Reboot into your new system."
echo "   Log in with the credentials from your configuration."
