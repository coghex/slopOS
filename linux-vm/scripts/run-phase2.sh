#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
OUTPUT_DIR="$ROOT_DIR/artifacts/buildroot-output"
BOOT_SELECTION_HELPER="$ROOT_DIR/scripts/boot-selection.sh"
OVERRIDE_KERNEL_IMAGE="${KERNEL_IMAGE:-}"
OVERRIDE_ROOTFS_SOURCE_IMAGE="${ROOTFS_SOURCE_IMAGE:-}"
KERNEL_IMAGE="$OUTPUT_DIR/images/Image"
RECOVERY_OUTPUT_DIR="$ROOT_DIR/artifacts/buildroot-recovery-output"
RECOVERY_KERNEL_IMAGE="$RECOVERY_OUTPUT_DIR/images/Image"
RECOVERY_INITRAMFS_IMAGE="$RECOVERY_OUTPUT_DIR/images/rootfs.cpio.gz"
BOOT_MODE="${BOOT_MODE:-normal}"
RECOVERY_ATTACH_DISKS="${RECOVERY_ATTACH_DISKS:-0}"
ROOT_DISK_SCRIPT="$ROOT_DIR/scripts/ensure-root-disk.sh"
PERSISTENT_DISK_SCRIPT="$ROOT_DIR/scripts/ensure-persistent-disk.sh"
OVERRIDE_GUEST_SSH_FORWARD_PORT="${GUEST_SSH_FORWARD_PORT:-}"
OVERRIDE_ROOT_DISK_IMAGE="${ROOT_DISK_IMAGE:-}"
OVERRIDE_PERSISTENT_DISK_IMAGE="${PERSISTENT_DISK_IMAGE:-}"

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

if [[ -n "$OVERRIDE_GUEST_SSH_FORWARD_PORT" ]]; then
  GUEST_SSH_FORWARD_PORT="$OVERRIDE_GUEST_SSH_FORWARD_PORT"
fi

case "$BOOT_MODE" in
  normal|recovery)
    ;;
  *)
    echo "Unsupported BOOT_MODE: $BOOT_MODE" >&2
    echo "Use BOOT_MODE=normal or BOOT_MODE=recovery." >&2
    exit 1
    ;;
esac

ROOT_DISK_IMAGE="${OVERRIDE_ROOT_DISK_IMAGE:-$ROOT_DIR/qemu/$ROOT_DISK_FILENAME}"
PERSISTENT_DISK_IMAGE="${OVERRIDE_PERSISTENT_DISK_IMAGE:-$ROOT_DIR/qemu/$PERSISTENT_DISK_FILENAME}"
ROOT_DISK_BOOT_SELECTION_METADATA="$(boot_selection_metadata_path_for_root_disk "$ROOT_DISK_IMAGE")"

resolve_default_boot_pair

default_rootfs_source_image="$DEFAULT_ROOTFS_SOURCE_IMAGE"
default_rootfs_source_kind="$DEFAULT_ROOTFS_SOURCE_KIND"
default_kernel_image="$DEFAULT_KERNEL_IMAGE"
default_kernel_source_kind="$DEFAULT_KERNEL_SOURCE_KIND"
default_promotion_root="$DEFAULT_PROMOTION_ROOT"
default_promotion_metadata="$DEFAULT_PROMOTION_METADATA"

resolved_rootfs_override=""
if [[ -n "$OVERRIDE_ROOTFS_SOURCE_IMAGE" ]]; then
  resolved_rootfs_override="$OVERRIDE_ROOTFS_SOURCE_IMAGE"
  if [[ "$resolved_rootfs_override" != /* ]]; then
    resolved_rootfs_override="$ROOT_DIR/$resolved_rootfs_override"
  fi
fi

root_disk_selection_scope="default"
root_disk_rootfs_source_kind="$default_rootfs_source_kind"
root_disk_kernel_source_kind="$default_kernel_source_kind"
root_disk_source_image="$default_rootfs_source_image"
root_disk_promotion_root="$default_promotion_root"
root_disk_promotion_metadata="$default_promotion_metadata"

if [[ -n "$resolved_rootfs_override" ]]; then
  root_disk_selection_scope="explicit"
  root_disk_rootfs_source_kind="explicit"
  root_disk_source_image="$resolved_rootfs_override"
  root_disk_promotion_root=""
  root_disk_promotion_metadata=""
fi

if [[ -n "$OVERRIDE_KERNEL_IMAGE" ]]; then
  KERNEL_IMAGE="$OVERRIDE_KERNEL_IMAGE"
  if [[ "$KERNEL_IMAGE" != /* ]]; then
    KERNEL_IMAGE="$ROOT_DIR/$KERNEL_IMAGE"
  fi
  root_disk_selection_scope="explicit"
  root_disk_kernel_source_kind="explicit"
elif [[ -f "$ROOT_DISK_IMAGE" && "${RESET_ROOT_DISK:-0}" != "1" && -f "$ROOT_DISK_BOOT_SELECTION_METADATA" ]]; then
  KERNEL_IMAGE="$(toml_value "$ROOT_DISK_BOOT_SELECTION_METADATA" kernel_image)"
  if [[ ! -f "$KERNEL_IMAGE" ]]; then
    echo "Recorded root disk kernel is missing: $KERNEL_IMAGE" >&2
    echo "Boot selection metadata: $ROOT_DISK_BOOT_SELECTION_METADATA" >&2
    echo "Reset the root disk or repair the promoted boot root before booting again." >&2
    exit 1
  fi
  echo "Using recorded root disk boot selection: $ROOT_DISK_BOOT_SELECTION_METADATA"
elif [[ -f "$ROOT_DISK_IMAGE" && "${RESET_ROOT_DISK:-0}" != "1" && ! -f "$ROOT_DISK_BOOT_SELECTION_METADATA" && "$default_kernel_source_kind" == "promoted-default" ]]; then
  KERNEL_IMAGE="$default_kernel_image"
  echo "Legacy root disk without boot selection metadata; defaulting kernel to current promoted boot selection." >&2
  echo "Reset the root disk to record an atomic rootfs+kernel pairing." >&2
else
  KERNEL_IMAGE="$default_kernel_image"
fi

qemu_args=(
  -accel "$QEMU_ACCEL"
  -M "$QEMU_MACHINE"
  -cpu cortex-a53
  -smp 2
  -m "${QEMU_MEMORY_MB:-1024}"
  -nographic
)

if [[ "$BOOT_MODE" == "normal" ]]; then
  if [[ ! -x "$ROOT_DISK_SCRIPT" ]]; then
    echo "Missing root disk helper: $ROOT_DISK_SCRIPT" >&2
    exit 1
  fi

  if [[ ! -x "$PERSISTENT_DISK_SCRIPT" ]]; then
    echo "Missing persistent disk helper: $PERSISTENT_DISK_SCRIPT" >&2
    exit 1
  fi

  if [[ ! -f "$KERNEL_IMAGE" ]]; then
    if [[ -n "$OVERRIDE_KERNEL_IMAGE" ]]; then
      echo "Missing configured kernel image: $KERNEL_IMAGE" >&2
    else
      echo "Missing kernel image: $KERNEL_IMAGE" >&2
    fi
    exit 1
  fi

  ROOT_DISK_SOURCE_IMAGE="$root_disk_source_image" \
    ROOT_DISK_SELECTION_SCOPE="$root_disk_selection_scope" \
    ROOT_DISK_ROOTFS_SOURCE_KIND="$root_disk_rootfs_source_kind" \
    ROOT_DISK_KERNEL_SOURCE_KIND="$root_disk_kernel_source_kind" \
    ROOT_DISK_SELECTED_ROOTFS_IMAGE="$root_disk_source_image" \
    ROOT_DISK_SELECTED_KERNEL_IMAGE="$KERNEL_IMAGE" \
    ROOT_DISK_SELECTED_PROMOTION_ROOT="$root_disk_promotion_root" \
    ROOT_DISK_SELECTED_PROMOTION_METADATA="$root_disk_promotion_metadata" \
    ROOT_DISK_BOOT_SELECTION_METADATA="$ROOT_DISK_BOOT_SELECTION_METADATA" \
    "$ROOT_DISK_SCRIPT"
  "$PERSISTENT_DISK_SCRIPT"
  echo "Using normal boot kernel: $KERNEL_IMAGE"

  qemu_args+=(
    -kernel "$KERNEL_IMAGE"
    -append "console=$LINUX_CONSOLE root=/dev/$ROOT_DISK_DEVICE rw rootwait rootfstype=ext4"
    -drive if=none,file="$PERSISTENT_DISK_IMAGE",format="$PERSISTENT_DISK_FORMAT",id=datadisk0
    -device virtio-blk-device,drive=datadisk0
    -drive if=none,file="$ROOT_DISK_IMAGE",format="$ROOT_DISK_FORMAT",id=rootdisk0
    -device virtio-blk-device,drive=rootdisk0
  )
else
  if [[ ! -f "$RECOVERY_KERNEL_IMAGE" ]]; then
    echo "Missing recovery kernel image: $RECOVERY_KERNEL_IMAGE" >&2
    echo "Run ./scripts/build-recovery-lima.sh first." >&2
    exit 1
  fi

  if [[ ! -f "$RECOVERY_INITRAMFS_IMAGE" ]]; then
    RECOVERY_INITRAMFS_IMAGE="$RECOVERY_OUTPUT_DIR/images/rootfs.cpio"
  fi

  if [[ ! -f "$RECOVERY_INITRAMFS_IMAGE" ]]; then
    echo "Missing recovery initramfs image in $RECOVERY_OUTPUT_DIR/images" >&2
    echo "Run ./scripts/build-recovery-lima.sh first." >&2
    exit 1
  fi

  qemu_args+=(
    -kernel "$RECOVERY_KERNEL_IMAGE"
    -initrd "$RECOVERY_INITRAMFS_IMAGE"
    -append "console=$LINUX_CONSOLE rdinit=/init"
  )

  if [[ "$RECOVERY_ATTACH_DISKS" == "1" && -f "$PERSISTENT_DISK_IMAGE" ]]; then
    qemu_args+=(
      -drive if=none,file="$PERSISTENT_DISK_IMAGE",format="$PERSISTENT_DISK_FORMAT",id=datadisk0
      -device virtio-blk-device,drive=datadisk0
    )
  fi

  if [[ "$RECOVERY_ATTACH_DISKS" == "1" && -f "$ROOT_DISK_IMAGE" ]]; then
    qemu_args+=(
      -drive if=none,file="$ROOT_DISK_IMAGE",format="$ROOT_DISK_FORMAT",id=rootdisk0
      -device virtio-blk-device,drive=rootdisk0
    )
  fi
fi

if [[ "$BOOT_MODE" == "normal" ]]; then
  qemu_args+=(
    -netdev user,id=eth0,hostfwd=tcp:127.0.0.1:${GUEST_SSH_FORWARD_PORT}-:22
    -device virtio-net-device,netdev=eth0
  )
else
  qemu_args+=(
    -netdev user,id=eth0
    -device virtio-net-device,netdev=eth0
  )
fi

exec "$QEMU_SYSTEM" "${qemu_args[@]}"
