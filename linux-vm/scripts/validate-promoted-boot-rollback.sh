#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
BUILDROOT_KERNEL_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/Image"
BUILDROOT_ROOTFS_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext4"
BUILDROOT_ROOTFS_EXT2_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext2"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-180}"
DEFAULT_VALIDATE_SSH_PORT="$(python3 - <<'PY'
import random
import socket

for _ in range(128):
    port = random.randint(20000, 45000)
    with socket.socket() as sock:
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            continue
        print(port)
        break
else:
    raise SystemExit("unable to allocate validation SSH port")
PY
)"
VALIDATE_SSH_PORT="${VALIDATE_SSH_PORT:-$DEFAULT_VALIDATE_SSH_PORT}"
VALIDATE_VM_PID=""
TMPDIR_HOST=""
PROMOTED_BOOT_ROOT=""

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-promoted-boot-rollback.sh

Validates the promoted-default rollback boundary in an isolated temporary
promotion root:
  1. promote the current guest kernel/rootfs candidates into that isolated root
  2. reuse validate-promoted-boot-default.sh to prove the promoted pair boots by default
  3. clear the promoted default
  4. boot again with no explicit overrides and prove default selection falls back
     to the Buildroot rootfs and kernel artifacts
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

if [[ ! -f "$IDENTITY_PATH_FILE" ]]; then
  echo "Missing guest SSH identity path file: $IDENTITY_PATH_FILE" >&2
  echo "Run ./scripts/prepare-guest-ssh.sh first." >&2
  exit 1
fi

if [[ ! -f "$BUILDROOT_ROOTFS_IMAGE" && -f "$BUILDROOT_ROOTFS_EXT2_IMAGE" ]]; then
  BUILDROOT_ROOTFS_IMAGE="$BUILDROOT_ROOTFS_EXT2_IMAGE"
fi

for required in "$BUILDROOT_KERNEL_IMAGE" "$BUILDROOT_ROOTFS_IMAGE"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing required boot artifact: $required" >&2
    exit 1
  fi
done

# shellcheck disable=SC1090
source "$CONFIG_FILE"

cleanup() {
  if [[ -n "$VALIDATE_VM_PID" ]] && kill -0 "$VALIDATE_VM_PID" 2>/dev/null; then
    kill "$VALIDATE_VM_PID" 2>/dev/null || true
    wait "$VALIDATE_VM_PID" 2>/dev/null || true
  fi
  if [[ -n "$TMPDIR_HOST" && -d "$TMPDIR_HOST" ]]; then
    rm -rf "$TMPDIR_HOST"
  fi
}

trap cleanup EXIT

wait_for_guest_ssh() {
  local known_hosts_file="$1"
  local deadline=$((SECONDS + BOOT_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    if GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
      KNOWN_HOSTS_FILE="$known_hosts_file" \
      "$ROOT_DIR/scripts/ssh-guest.sh" 'true' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

shutdown_vm() {
  local known_hosts_file="$1"
  local deadline

  GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    KNOWN_HOSTS_FILE="$known_hosts_file" \
    "$ROOT_DIR/scripts/ssh-guest.sh" 'poweroff' >/dev/null 2>&1 || true

  if [[ -n "$VALIDATE_VM_PID" ]]; then
    deadline=$((SECONDS + 60))
    while kill -0 "$VALIDATE_VM_PID" 2>/dev/null; do
      if (( SECONDS >= deadline )); then
        kill "$VALIDATE_VM_PID" 2>/dev/null || true
        break
      fi
      sleep 1
    done
    wait "$VALIDATE_VM_PID" || true
    VALIDATE_VM_PID=""
  fi
}

read -r -d '' remote_check <<'EOF' || true
python3 - <<'PY'
import os

for unexpected in ("/bin/busybox", "/linuxrc", "/bin/ash"):
    if os.path.lexists(unexpected):
        raise SystemExit(f"unexpected live path present: {unexpected}")

for required in ("/bin/sh", "/sbin/getty", "/usr/sbin/seedrng"):
    if not os.path.lexists(required):
        raise SystemExit(f"missing live path: {required}")

mounted = False
with open("/proc/mounts", "r", encoding="utf-8") as fh:
    for line in fh:
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "/Volumes/slopos-data":
            mounted = True
            break

if not mounted:
    raise SystemExit("persistent data mount is missing at /Volumes/slopos-data")
PY
EOF

mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/validate-promoted-rollback.XXXXXX")"
PROMOTED_BOOT_ROOT="$TMPDIR_HOST/promoted-root"
mkdir -p "$PROMOTED_BOOT_ROOT"

HOST_GUEST_PROMOTED_BOOT_ROOT="$PROMOTED_BOOT_ROOT" \
  "$ROOT_DIR/scripts/promote-guest-boot-default.sh" >/dev/null

HOST_GUEST_PROMOTED_BOOT_ROOT="$PROMOTED_BOOT_ROOT" \
  "$ROOT_DIR/scripts/validate-promoted-boot-default.sh"

HOST_GUEST_PROMOTED_BOOT_ROOT="$PROMOTED_BOOT_ROOT" \
  "$ROOT_DIR/scripts/promote-guest-boot-default.sh" --clear >/dev/null

if [[ -L "$PROMOTED_BOOT_ROOT/current" || -e "$PROMOTED_BOOT_ROOT/current" ]]; then
  echo "Promoted current entry still exists after --clear: $PROMOTED_BOOT_ROOT/current" >&2
  exit 1
fi

known_hosts_file="$TMPDIR_HOST/rollback-known_hosts"
qemu_log="$TMPDIR_HOST/rollback-normal-qemu.log"
root_disk_image="$TMPDIR_HOST/rollback-root.img"
data_disk_image="$TMPDIR_HOST/rollback-data.img"

PERSISTENT_DISK_IMAGE="$data_disk_image" "$ROOT_DIR/scripts/ensure-persistent-disk.sh" >/dev/null

(
  cd "$ROOT_DIR"
  HOST_GUEST_PROMOTED_BOOT_ROOT="$PROMOTED_BOOT_ROOT" \
    ROOT_DISK_IMAGE="$root_disk_image" \
    PERSISTENT_DISK_IMAGE="$data_disk_image" \
    RESET_ROOT_DISK=1 \
    GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    ./scripts/run-phase2.sh >"$qemu_log" 2>&1
) &
VALIDATE_VM_PID=$!

if ! wait_for_guest_ssh "$known_hosts_file"; then
  echo "timed out waiting for rollback guest SSH" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

if ! grep -Fq "Reset root disk from $BUILDROOT_ROOTFS_IMAGE" "$qemu_log" \
  && ! grep -Fq "Created root disk $root_disk_image from $BUILDROOT_ROOTFS_IMAGE" "$qemu_log"; then
  echo "rollback boot did not create or reseed the temporary root disk from $BUILDROOT_ROOTFS_IMAGE" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

if ! grep -Fq "Using normal boot kernel: $BUILDROOT_KERNEL_IMAGE" "$qemu_log"; then
  echo "rollback boot did not select the Buildroot kernel $BUILDROOT_KERNEL_IMAGE" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" "$remote_check"

shutdown_vm "$known_hosts_file"

echo "Validated promoted default rollback boundary."
echo "  promoted_root: $PROMOTED_BOOT_ROOT"
echo "  default_rootfs_after_clear: $BUILDROOT_ROOTFS_IMAGE"
echo "  default_kernel_after_clear: $BUILDROOT_KERNEL_IMAGE"
