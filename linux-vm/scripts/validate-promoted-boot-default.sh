#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
HOST_PROMOTED_BOOT_ROOT="${HOST_GUEST_PROMOTED_BOOT_ROOT:-$ROOT_DIR/artifacts/guest-boot-promoted}"
PROMOTED_BOOT_CURRENT="$HOST_PROMOTED_BOOT_ROOT/current"
PROMOTED_ROOTFS_IMAGE="$PROMOTED_BOOT_CURRENT/rootfs.ext4"
PROMOTED_KERNEL_IMAGE="$PROMOTED_BOOT_CURRENT/Image"
PROMOTED_KERNEL_MANIFEST="$PROMOTED_BOOT_CURRENT/kernel.manifest.toml"
BUILDROOT_KERNEL_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/Image"
BUILDROOT_ROOTFS_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext4"
BUILDROOT_ROOTFS_EXT2_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext2"
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
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-180}"
VALIDATE_VM_PID=""
TMPDIR_HOST=""

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-promoted-boot-default.sh

Boots temporary VMs through ./scripts/run-phase2.sh to verify two behaviors:
  1. the promoted default boot pair is selected automatically when no explicit
     rootfs/kernel overrides are provided
  2. explicit ROOTFS_SOURCE_IMAGE/KERNEL_IMAGE overrides still win even when the
     promoted default is active
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

for var_name in \
  HOST_PROMOTED_BOOT_ROOT \
  PROMOTED_BOOT_CURRENT \
  PROMOTED_ROOTFS_IMAGE \
  PROMOTED_KERNEL_IMAGE \
  PROMOTED_KERNEL_MANIFEST; do
  var_value="${!var_name}"
  if [[ "$var_value" != /* ]]; then
    printf -v "$var_name" '%s/%s' "$ROOT_DIR" "$var_value"
  fi
done

if [[ ! -f "$BUILDROOT_ROOTFS_IMAGE" && -f "$BUILDROOT_ROOTFS_EXT2_IMAGE" ]]; then
  BUILDROOT_ROOTFS_IMAGE="$BUILDROOT_ROOTFS_EXT2_IMAGE"
fi

for required in \
  "$PROMOTED_ROOTFS_IMAGE" \
  "$PROMOTED_KERNEL_IMAGE" \
  "$PROMOTED_KERNEL_MANIFEST" \
  "$BUILDROOT_KERNEL_IMAGE" \
  "$BUILDROOT_ROOTFS_IMAGE"; do
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

expected_kernel_release="$(python3 - "$PROMOTED_KERNEL_MANIFEST" <<'PY'
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        if line.startswith("kernel_release = "):
            print(line.split("=", 1)[1].strip().strip('"'))
            break
    else:
        raise SystemExit("kernel_release not found in manifest")
PY
)"

read -r -d '' remote_check <<EOF || true
python3 - <<'PY'
import os
import subprocess

expected_kernel_release = "$expected_kernel_release"

running_kernel_release = subprocess.check_output(["uname", "-r"], text=True).strip()
if running_kernel_release != expected_kernel_release:
    raise SystemExit(
        f"unexpected running kernel release: {running_kernel_release} (expected {expected_kernel_release})"
    )

modules_dir = f"/lib/modules/{expected_kernel_release}"
if not os.path.isdir(modules_dir):
    raise SystemExit(f"missing live modules directory for running kernel: {modules_dir}")

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

boot_and_assert() {
  local mode_name="$1"
  local rootfs_image="$2"
  local kernel_image="$3"
  local root_disk_image="$4"
  local data_disk_image="$5"
  local known_hosts_file="$6"
  local qemu_log="$7"
  local use_explicit_overrides="$8"

  PERSISTENT_DISK_IMAGE="$data_disk_image" "$ROOT_DIR/scripts/ensure-persistent-disk.sh" >/dev/null

  if [[ "$use_explicit_overrides" == "1" ]]; then
    (
      cd "$ROOT_DIR"
      ROOT_DISK_IMAGE="$root_disk_image" \
        PERSISTENT_DISK_IMAGE="$data_disk_image" \
        ROOTFS_SOURCE_IMAGE="$rootfs_image" \
        KERNEL_IMAGE="$kernel_image" \
        RESET_ROOT_DISK=1 \
        GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
        ./scripts/run-phase2.sh >"$qemu_log" 2>&1
    ) &
  else
    (
      cd "$ROOT_DIR"
      ROOT_DISK_IMAGE="$root_disk_image" \
        PERSISTENT_DISK_IMAGE="$data_disk_image" \
        RESET_ROOT_DISK=1 \
        GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
        ./scripts/run-phase2.sh >"$qemu_log" 2>&1
    ) &
  fi
  VALIDATE_VM_PID=$!

  if ! wait_for_guest_ssh "$known_hosts_file"; then
    echo "timed out waiting for $mode_name guest SSH" >&2
    tail -n 80 "$qemu_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq "Reset root disk from $rootfs_image" "$qemu_log" \
    && ! grep -Fq "Created root disk $root_disk_image from $rootfs_image" "$qemu_log"; then
    echo "$mode_name did not create or reseed the temporary root disk from $rootfs_image" >&2
    tail -n 80 "$qemu_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq "Using normal boot kernel: $kernel_image" "$qemu_log"; then
    echo "$mode_name did not select the expected kernel $kernel_image" >&2
    tail -n 80 "$qemu_log" >&2 || true
    exit 1
  fi
}

mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/validate-promoted-boot.XXXXXX")"

default_known_hosts_file="$TMPDIR_HOST/default-known_hosts"
default_qemu_log="$TMPDIR_HOST/default-normal-qemu.log"
default_root_disk_image="$TMPDIR_HOST/default-root.img"
default_data_disk_image="$TMPDIR_HOST/default-data.img"

boot_and_assert \
  "promoted default boot" \
  "$PROMOTED_ROOTFS_IMAGE" \
  "$PROMOTED_KERNEL_IMAGE" \
  "$default_root_disk_image" \
  "$default_data_disk_image" \
  "$default_known_hosts_file" \
  "$default_qemu_log" \
  "0"

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$default_known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" "$remote_check"

shutdown_vm "$default_known_hosts_file"

override_known_hosts_file="$TMPDIR_HOST/override-known_hosts"
override_qemu_log="$TMPDIR_HOST/override-normal-qemu.log"
override_root_disk_image="$TMPDIR_HOST/override-root.img"
override_data_disk_image="$TMPDIR_HOST/override-data.img"

boot_and_assert \
  "explicit override boot" \
  "$BUILDROOT_ROOTFS_IMAGE" \
  "$BUILDROOT_KERNEL_IMAGE" \
  "$override_root_disk_image" \
  "$override_data_disk_image" \
  "$override_known_hosts_file" \
  "$override_qemu_log" \
  "1"

shutdown_vm "$override_known_hosts_file"

echo "Validated promoted default normal boot selection."
echo "  promoted_rootfs: $PROMOTED_ROOTFS_IMAGE"
echo "  promoted_kernel: $PROMOTED_KERNEL_IMAGE"
