#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
OUTPUT_DIR="$ROOT_DIR/artifacts/buildroot-output"
KERNEL_IMAGE="$OUTPUT_DIR/images/Image"
ROOT_DISK_SCRIPT="$ROOT_DIR/scripts/ensure-root-disk.sh"
PERSISTENT_DISK_SCRIPT="$ROOT_DIR/scripts/ensure-persistent-disk.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ ! -x "$ROOT_DISK_SCRIPT" ]]; then
  echo "Missing root disk helper: $ROOT_DISK_SCRIPT" >&2
  exit 1
fi

if [[ ! -x "$PERSISTENT_DISK_SCRIPT" ]]; then
  echo "Missing persistent disk helper: $PERSISTENT_DISK_SCRIPT" >&2
  exit 1
fi

if [[ ! -f "$KERNEL_IMAGE" ]]; then
  echo "Missing kernel image: $KERNEL_IMAGE" >&2
  exit 1
fi

ROOT_DISK_IMAGE="$ROOT_DIR/qemu/$ROOT_DISK_FILENAME"
PERSISTENT_DISK_IMAGE="$ROOT_DIR/qemu/$PERSISTENT_DISK_FILENAME"
"$ROOT_DISK_SCRIPT"
"$PERSISTENT_DISK_SCRIPT"

exec "$QEMU_SYSTEM" \
  -accel "$QEMU_ACCEL" \
  -M "$QEMU_MACHINE" \
  -cpu cortex-a53 \
  -smp 2 \
  -m "${QEMU_MEMORY_MB:-1024}" \
  -nographic \
  -kernel "$KERNEL_IMAGE" \
  -append "console=$LINUX_CONSOLE root=/dev/$ROOT_DISK_DEVICE rw rootwait rootfstype=ext4" \
  -drive if=none,file="$PERSISTENT_DISK_IMAGE",format="$PERSISTENT_DISK_FORMAT",id=datadisk0 \
  -device virtio-blk-device,drive=datadisk0 \
  -drive if=none,file="$ROOT_DISK_IMAGE",format="$ROOT_DISK_FORMAT",id=rootdisk0 \
  -device virtio-blk-device,drive=rootdisk0 \
  -netdev user,id=eth0,hostfwd=tcp:127.0.0.1:${GUEST_SSH_FORWARD_PORT}-:22 \
  -device virtio-net-device,netdev=eth0
