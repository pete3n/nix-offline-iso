# offline-install — minimal CLI offline NixOS installer (nix-offline-iso).
#
# This is the BODY of a writeShellApplication wrapper (see flake.nix): the
# wrapper supplies the shebang, `set -euo pipefail`, and the PATH (runtimeInputs),
# so this file has neither. It reproduces, in shell, what the graphical
# (Calamares) variant's config-copy step does: copy the baked/edited config into
# the target, preserve the freshly generated hardware-configuration.nix, build
# the system in the LIVE installer store, and install it with `nixos-install
# --system` — all fully offline.

ROOT=/mnt
DISK=""
HOST="$(uname -n)"

usage() {
  cat <<EOF
Usage: offline-install [--disk /dev/DEVICE] [--host NAME] [--root DIR]

  --disk DEV   Wipe DEV and create a single-disk layout (GPT: 512MiB ESP + ext4
               root), mount it at --root, then install. DESTROYS ALL DATA ON DEV.
               Omit to install into an already-mounted --root (default /mnt).
  --host NAME  Flake configs only: nixosConfigurations.<NAME> to install
               (default: current hostname "$HOST").
  --root DIR   Target mount point (default /mnt).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --disk) DISK="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "offline-install must run as root (try: sudo offline-install ...)" >&2
  exit 1
fi

# --- optional single-disk auto-partition ------------------------------------
if [ -n "$DISK" ]; then
  echo ">> This will ERASE all data on $DISK and create:"
  echo "     GPT  ->  512MiB ESP (FAT32, /boot)  +  ext4 root (rest)"
  printf 'Type YES to continue: '
  read -r confirm
  if [ "$confirm" != "YES" ]; then
    echo "aborted"
    exit 1
  fi
  wipefs -a "$DISK"
  parted -s "$DISK" -- mklabel gpt
  parted -s "$DISK" -- mkpart ESP fat32 1MiB 513MiB
  parted -s "$DISK" -- set 1 esp on
  parted -s "$DISK" -- mkpart root ext4 513MiB 100%
  # nvme/mmc devices name partitions p1/p2; sd*/vd* name them 1/2.
  case "$DISK" in
    *[0-9]) part1="${DISK}p1"; part2="${DISK}p2" ;;
    *) part1="${DISK}1"; part2="${DISK}2" ;;
  esac
  udevadm settle || true
  mkfs.fat -F 32 -n boot "$part1"
  mkfs.ext4 -F -L nixos "$part2"
  mount "$part2" "$ROOT"
  mkdir -p "$ROOT/boot"
  mount "$part1" "$ROOT/boot"
fi

if ! mountpoint -q "$ROOT"; then
  echo "Nothing is mounted at $ROOT." >&2
  echo "Partition and mount your target there first, or pass --disk /dev/DEVICE." >&2
  exit 1
fi

# --- choose the config source -----------------------------------------------
# /tmp/nix-cfg (edited after boot) wins over the baked-in /iso/nix-cfg.
src=/tmp/nix-cfg
if [ ! -e "$src/configuration.nix" ] && [ ! -e "$src/flake.nix" ]; then
  src=/iso/nix-cfg
fi
if [ ! -e "$src/configuration.nix" ] && [ ! -e "$src/flake.nix" ]; then
  echo "No configuration.nix or flake.nix in /tmp/nix-cfg or /iso/nix-cfg." >&2
  exit 1
fi
echo ">> Using configuration from $src"

# --- generate hardware config, then overlay the user's config ---------------
nixos-generate-config --root "$ROOT"
hw="$ROOT/etc/nixos/hardware-configuration.nix"
hw_saved="$(mktemp)"
cp "$hw" "$hw_saved"
cp -rT "$src" "$ROOT/etc/nixos"
chmod -R u+w "$ROOT/etc/nixos"
cp -f "$hw_saved" "$hw"
rm -f "$hw_saved"

# --- build in the LIVE store, then install the finished path with --system ---
# Building here (not via `nixos-install --flake`/chroot) keeps the build in the
# store that actually has the inputs; `--system` then just copies the closure.
if [ -e "$ROOT/etc/nixos/flake.nix" ]; then
  echo ">> Flake install: building nixosConfigurations.$HOST in the live store"
  top="$(nix build --offline --no-link --print-out-paths \
    "$ROOT/etc/nixos#nixosConfigurations.$HOST.config.system.build.toplevel")"
else
  echo ">> Channels install: building the system in the live store"
  top="$(nix-build --offline --no-out-link \
    '<nixpkgs/nixos>' -A system \
    -I "nixos-config=$ROOT/etc/nixos/configuration.nix")"
fi

nixos-install --system "$top" --root "$ROOT" --no-root-passwd

echo ">> Installation complete. Reboot into your new system."
echo "   Log in with the credentials from your configuration."
