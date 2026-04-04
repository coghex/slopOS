#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
ROOTFS_SOURCE_IMAGE_OVERRIDE="${ROOTFS_SOURCE_IMAGE:-}"
ROOT_DISK_SOURCE_IMAGE_INTERNAL="${ROOT_DISK_SOURCE_IMAGE:-}"
BOOT_SELECTION_HELPER="$ROOT_DIR/scripts/boot-selection.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

if [[ ! -f "$BOOT_SELECTION_HELPER" ]]; then
  echo "Missing boot selection helper: $BOOT_SELECTION_HELPER" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck disable=SC1090
source "$BOOT_SELECTION_HELPER"

ROOT_DISK_IMAGE="${ROOT_DISK_IMAGE:-$ROOT_DIR/qemu/$ROOT_DISK_FILENAME}"
ROOT_DISK_BOOT_SELECTION_METADATA="${ROOT_DISK_BOOT_SELECTION_METADATA:-$(boot_selection_metadata_path_for_root_disk "$ROOT_DISK_IMAGE")}"

resolve_default_boot_pair

if [[ -n "$ROOT_DISK_SOURCE_IMAGE_INTERNAL" ]]; then
  SOURCE_IMAGE="$ROOT_DISK_SOURCE_IMAGE_INTERNAL"
  if [[ "$SOURCE_IMAGE" != /* ]]; then
    SOURCE_IMAGE="$ROOT_DIR/$SOURCE_IMAGE"
  fi
elif [[ -n "$ROOTFS_SOURCE_IMAGE_OVERRIDE" ]]; then
  SOURCE_IMAGE="$ROOTFS_SOURCE_IMAGE_OVERRIDE"
  if [[ "$SOURCE_IMAGE" != /* ]]; then
    SOURCE_IMAGE="$ROOT_DIR/$SOURCE_IMAGE"
  fi
else
  SOURCE_IMAGE="$DEFAULT_ROOTFS_SOURCE_IMAGE"
fi

if [[ ! -f "$SOURCE_IMAGE" ]]; then
  if [[ -n "$ROOT_DISK_SOURCE_IMAGE_INTERNAL" || -n "$ROOTFS_SOURCE_IMAGE_OVERRIDE" ]]; then
    echo "Missing configured rootfs source image: $SOURCE_IMAGE" >&2
  else
    echo "Missing ext4 rootfs image: $BUILDROOT_ROOTFS_IMAGE" >&2
    echo "Run ./scripts/build-phase2-lima.sh first." >&2
  fi
  exit 1
fi

ROOT_DISK_SELECTION_SCOPE="${ROOT_DISK_SELECTION_SCOPE:-default}"
if [[ -n "$ROOTFS_SOURCE_IMAGE_OVERRIDE" || -n "${KERNEL_IMAGE:-}" ]]; then
  ROOT_DISK_SELECTION_SCOPE="explicit"
fi

ROOT_DISK_ROOTFS_SOURCE_KIND="${ROOT_DISK_ROOTFS_SOURCE_KIND:-$DEFAULT_ROOTFS_SOURCE_KIND}"
if [[ -n "$ROOTFS_SOURCE_IMAGE_OVERRIDE" ]]; then
  ROOT_DISK_ROOTFS_SOURCE_KIND="explicit"
fi

if [[ -n "${ROOT_DISK_SELECTED_KERNEL_IMAGE:-}" ]]; then
  selected_kernel_image="$ROOT_DISK_SELECTED_KERNEL_IMAGE"
  if [[ "$selected_kernel_image" != /* ]]; then
    selected_kernel_image="$ROOT_DIR/$selected_kernel_image"
  fi
  ROOT_DISK_SELECTED_KERNEL_IMAGE="$selected_kernel_image"
elif [[ -n "${KERNEL_IMAGE:-}" ]]; then
  selected_kernel_image="${KERNEL_IMAGE}"
  if [[ "$selected_kernel_image" != /* ]]; then
    selected_kernel_image="$ROOT_DIR/$selected_kernel_image"
  fi
  ROOT_DISK_SELECTED_KERNEL_IMAGE="$selected_kernel_image"
else
  ROOT_DISK_SELECTED_KERNEL_IMAGE="$DEFAULT_KERNEL_IMAGE"
fi

ROOT_DISK_KERNEL_SOURCE_KIND="${ROOT_DISK_KERNEL_SOURCE_KIND:-$DEFAULT_KERNEL_SOURCE_KIND}"
if [[ -n "${KERNEL_IMAGE:-}" ]]; then
  ROOT_DISK_KERNEL_SOURCE_KIND="explicit"
fi

ROOT_DISK_SELECTED_ROOTFS_IMAGE="${ROOT_DISK_SELECTED_ROOTFS_IMAGE:-$SOURCE_IMAGE}"
if [[ -n "$ROOT_DISK_SOURCE_IMAGE_INTERNAL" ]]; then
  ROOT_DISK_SELECTED_ROOTFS_IMAGE="$SOURCE_IMAGE"
fi
if [[ -n "$ROOTFS_SOURCE_IMAGE_OVERRIDE" ]]; then
  ROOT_DISK_SELECTED_ROOTFS_IMAGE="$SOURCE_IMAGE"
fi

if [[ -z "${ROOT_DISK_SELECTED_PROMOTION_ROOT:-}" && "$ROOT_DISK_ROOTFS_SOURCE_KIND" == "promoted-default" ]]; then
  ROOT_DISK_SELECTED_PROMOTION_ROOT="$DEFAULT_PROMOTION_ROOT"
fi
if [[ -z "${ROOT_DISK_SELECTED_PROMOTION_METADATA:-}" && "$ROOT_DISK_ROOTFS_SOURCE_KIND" == "promoted-default" ]]; then
  ROOT_DISK_SELECTED_PROMOTION_METADATA="$DEFAULT_PROMOTION_METADATA"
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
write_root_disk_boot_selection_metadata "$ROOT_DISK_BOOT_SELECTION_METADATA"

if [[ "${RESET_ROOT_DISK:-0}" == "1" ]]; then
  echo "Reset root disk from $SOURCE_IMAGE"
else
  echo "Created root disk $ROOT_DISK_IMAGE from $SOURCE_IMAGE"
fi
echo "Recorded root disk boot selection metadata: $ROOT_DISK_BOOT_SELECTION_METADATA"
