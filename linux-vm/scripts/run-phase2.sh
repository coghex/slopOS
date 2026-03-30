#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
OUTPUT_DIR="$ROOT_DIR/artifacts/buildroot-output"
OVERRIDE_KERNEL_IMAGE="${KERNEL_IMAGE:-}"
KERNEL_IMAGE="$OUTPUT_DIR/images/Image"
PROMOTED_BOOT_ROOT="${HOST_GUEST_PROMOTED_BOOT_ROOT:-$ROOT_DIR/artifacts/guest-boot-promoted}"
PROMOTED_BOOT_CURRENT="$PROMOTED_BOOT_ROOT/current"
PROMOTED_KERNEL_IMAGE="$PROMOTED_BOOT_CURRENT/Image"
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

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -n "$OVERRIDE_GUEST_SSH_FORWARD_PORT" ]]; then
  GUEST_SSH_FORWARD_PORT="$OVERRIDE_GUEST_SSH_FORWARD_PORT"
fi

if [[ "$PROMOTED_BOOT_ROOT" != /* ]]; then
  PROMOTED_BOOT_ROOT="$ROOT_DIR/$PROMOTED_BOOT_ROOT"
  PROMOTED_BOOT_CURRENT="$PROMOTED_BOOT_ROOT/current"
  PROMOTED_KERNEL_IMAGE="$PROMOTED_BOOT_CURRENT/Image"
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

if [[ -n "$OVERRIDE_KERNEL_IMAGE" ]]; then
  KERNEL_IMAGE="$OVERRIDE_KERNEL_IMAGE"
  if [[ "$KERNEL_IMAGE" != /* ]]; then
    KERNEL_IMAGE="$ROOT_DIR/$KERNEL_IMAGE"
  fi
elif [[ -d "$PROMOTED_BOOT_CURRENT" || -L "$PROMOTED_BOOT_CURRENT" ]]; then
  if [[ ! -f "$PROMOTED_KERNEL_IMAGE" ]]; then
    echo "Promoted default boot kernel is incomplete: $PROMOTED_KERNEL_IMAGE" >&2
    exit 1
  fi
  KERNEL_IMAGE="$PROMOTED_KERNEL_IMAGE"
fi

ROOT_DISK_IMAGE="${OVERRIDE_ROOT_DISK_IMAGE:-$ROOT_DIR/qemu/$ROOT_DISK_FILENAME}"
PERSISTENT_DISK_IMAGE="${OVERRIDE_PERSISTENT_DISK_IMAGE:-$ROOT_DIR/qemu/$PERSISTENT_DISK_FILENAME}"
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
