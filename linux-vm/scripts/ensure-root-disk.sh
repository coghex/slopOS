#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
ROOTFS_EXT4_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext4"
ROOTFS_EXT2_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext2"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

ROOT_DISK_IMAGE="${ROOT_DISK_IMAGE:-$ROOT_DIR/qemu/$ROOT_DISK_FILENAME}"
SOURCE_IMAGE="$ROOTFS_EXT4_IMAGE"
if [[ ! -f "$SOURCE_IMAGE" && -f "$ROOTFS_EXT2_IMAGE" ]]; then
  SOURCE_IMAGE="$ROOTFS_EXT2_IMAGE"
fi

if [[ ! -f "$SOURCE_IMAGE" ]]; then
  echo "Missing ext4 rootfs image: $ROOTFS_EXT4_IMAGE" >&2
  echo "Run ./scripts/build-phase2-lima.sh first." >&2
  exit 1
fi

mkdir -p "$(dirname "$ROOT_DISK_IMAGE")"

if [[ -f "$ROOT_DISK_IMAGE" && "${RESET_ROOT_DISK:-0}" != "1" ]]; then
  echo "Root disk ready: $ROOT_DISK_IMAGE"
  exit 0
fi

tmp_image="$ROOT_DISK_IMAGE.tmp"
trap 'rm -f "$tmp_image"' ERR

cp "$SOURCE_IMAGE" "$tmp_image"
mv "$tmp_image" "$ROOT_DISK_IMAGE"

trap - ERR

if [[ "${RESET_ROOT_DISK:-0}" == "1" ]]; then
  echo "Reset root disk from $SOURCE_IMAGE"
else
  echo "Created root disk $ROOT_DISK_IMAGE from $SOURCE_IMAGE"
fi
