#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

PERSISTENT_DISK_IMAGE="${PERSISTENT_DISK_IMAGE:-$ROOT_DIR/qemu/$PERSISTENT_DISK_FILENAME}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended to run on macOS." >&2
  exit 1
fi

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "qemu-img is required. Install QEMU first." >&2
  exit 1
fi

if [[ -f "$PERSISTENT_DISK_IMAGE" ]]; then
  existing_size_bytes="$(qemu-img info --output=json "$PERSISTENT_DISK_IMAGE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')"
  requested_size_bytes="$(python3 - "$PERSISTENT_DISK_SIZE" <<'PY'
import re
import sys

size = sys.argv[1].strip().upper()
match = re.fullmatch(r'([0-9]+)([KMGTP]?)', size)
if not match:
    raise SystemExit(f"unsupported size format: {size}")
value = int(match.group(1))
unit = match.group(2)
scale = {
    '': 1,
    'K': 1024,
    'M': 1024 ** 2,
    'G': 1024 ** 3,
    'T': 1024 ** 4,
    'P': 1024 ** 5,
}[unit]
print(value * scale)
PY
)"

  if (( requested_size_bytes > existing_size_bytes )); then
    qemu-img resize -f "$PERSISTENT_DISK_FORMAT" "$PERSISTENT_DISK_IMAGE" "$PERSISTENT_DISK_SIZE" >/dev/null
    echo "Resized persistent disk $PERSISTENT_DISK_IMAGE to $PERSISTENT_DISK_SIZE"
  else
    echo "Persistent disk ready: $PERSISTENT_DISK_IMAGE"
  fi
  exit 0
fi

if ! command -v limactl >/dev/null 2>&1; then
  echo "limactl is required to format the Linux filesystem. Install Lima with: brew install lima" >&2
  exit 1
fi

INSTANCE="${LIMA_INSTANCE:-slopos-builder}"
VM_TYPE="${LIMA_VM_TYPE:-vz}"
CPUS="${LIMA_CPUS:-4}"
MEMORY_GIB="${LIMA_MEMORY_GIB:-8}"
DISK_GIB="${LIMA_DISK_GIB:-40}"
MOUNT_TYPE="${LIMA_MOUNT_TYPE:-virtiofs}"

mkdir -p "$(dirname "$PERSISTENT_DISK_IMAGE")"
trap 'rm -f "$PERSISTENT_DISK_IMAGE"' ERR

if limactl list -q | grep -qx "$INSTANCE"; then
  limactl start "$INSTANCE" --yes >/dev/null
else
  limactl start \
    --name="$INSTANCE" \
    --vm-type="$VM_TYPE" \
    --cpus="$CPUS" \
    --memory="$MEMORY_GIB" \
    --disk="$DISK_GIB" \
    --mount-only "$PROJECT_ROOT:w" \
    --mount-type="$MOUNT_TYPE" \
    --containerd=none \
    --yes >/dev/null
fi

limactl shell --start "$INSTANCE" bash -lc '
  set -euo pipefail
  marker="$HOME/.slopos-disk-deps-ready"
  if [[ ! -f "$marker" ]]; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y e2fsprogs
    touch "$marker"
  fi
'

qemu-img create -f "$PERSISTENT_DISK_FORMAT" "$PERSISTENT_DISK_IMAGE" "$PERSISTENT_DISK_SIZE" >/dev/null

guest_cmd='set -euo pipefail; '
guest_cmd+="mkfs.ext4 -F -L $(printf '%q' "$PERSISTENT_DISK_LABEL") $(printf '%q' "$PERSISTENT_DISK_IMAGE")"
limactl shell --start --workdir "$PROJECT_ROOT" "$INSTANCE" bash -lc "$guest_cmd"

trap - ERR
echo "Created persistent disk $PERSISTENT_DISK_IMAGE (${PERSISTENT_DISK_SIZE}, label ${PERSISTENT_DISK_LABEL})"
