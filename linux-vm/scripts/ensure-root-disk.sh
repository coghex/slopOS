#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
ROOTFS_EXT4_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext4"
ROOTFS_EXT2_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext2"
ROOTFS_SOURCE_IMAGE_OVERRIDE="${ROOTFS_SOURCE_IMAGE:-}"
PROMOTED_BOOT_ROOT="${HOST_GUEST_PROMOTED_BOOT_ROOT:-$ROOT_DIR/artifacts/guest-boot-promoted}"
PROMOTED_BOOT_CURRENT="$PROMOTED_BOOT_ROOT/current"
PROMOTED_ROOTFS_IMAGE="$PROMOTED_BOOT_CURRENT/rootfs.ext4"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

ROOT_DISK_IMAGE="${ROOT_DISK_IMAGE:-$ROOT_DIR/qemu/$ROOT_DISK_FILENAME}"
if [[ "$PROMOTED_BOOT_ROOT" != /* ]]; then
  PROMOTED_BOOT_ROOT="$ROOT_DIR/$PROMOTED_BOOT_ROOT"
  PROMOTED_BOOT_CURRENT="$PROMOTED_BOOT_ROOT/current"
  PROMOTED_ROOTFS_IMAGE="$PROMOTED_BOOT_CURRENT/rootfs.ext4"
fi
if [[ -n "$ROOTFS_SOURCE_IMAGE_OVERRIDE" ]]; then
  SOURCE_IMAGE="$ROOTFS_SOURCE_IMAGE_OVERRIDE"
  if [[ "$SOURCE_IMAGE" != /* ]]; then
    SOURCE_IMAGE="$ROOT_DIR/$SOURCE_IMAGE"
  fi
elif [[ -d "$PROMOTED_BOOT_CURRENT" || -L "$PROMOTED_BOOT_CURRENT" ]]; then
  if [[ ! -f "$PROMOTED_ROOTFS_IMAGE" ]]; then
    echo "Promoted default boot rootfs is incomplete: $PROMOTED_ROOTFS_IMAGE" >&2
    exit 1
  fi
  SOURCE_IMAGE="$PROMOTED_ROOTFS_IMAGE"
else
  SOURCE_IMAGE="$ROOTFS_EXT4_IMAGE"
  if [[ ! -f "$SOURCE_IMAGE" && -f "$ROOTFS_EXT2_IMAGE" ]]; then
    SOURCE_IMAGE="$ROOTFS_EXT2_IMAGE"
  fi
fi

if [[ ! -f "$SOURCE_IMAGE" ]]; then
  if [[ -n "$ROOTFS_SOURCE_IMAGE_OVERRIDE" ]]; then
    echo "Missing configured rootfs source image: $SOURCE_IMAGE" >&2
  else
    echo "Missing ext4 rootfs image: $ROOTFS_EXT4_IMAGE" >&2
    echo "Run ./scripts/build-phase2-lima.sh first." >&2
  fi
  exit 1
fi

mkdir -p "$(dirname "$ROOT_DISK_IMAGE")"

if [[ -f "$ROOT_DISK_IMAGE" && "${RESET_ROOT_DISK:-0}" != "1" ]]; then
  echo "Root disk ready: $ROOT_DISK_IMAGE"
  if [[ -n "$ROOTFS_SOURCE_IMAGE_OVERRIDE" ]]; then
    echo "Existing root disk retained; ROOTFS_SOURCE_IMAGE only applies when creating or resetting the root disk."
  fi
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
