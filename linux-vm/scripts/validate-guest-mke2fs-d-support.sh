#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
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
Usage: ./scripts/validate-guest-mke2fs-d-support.sh

Boots a temporary VM from the current rebuilt normal seed image, proves the
guest ext4 audit now reports an in-guest mke2fs -d path, builds a guest rootfs
artifact on that temporary VM, and verifies the artifact manifest records
seal_method = "guest-mke2fs-d".
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

mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/validate-guest-mke2fs-d.XXXXXX")"
known_hosts_file="$TMPDIR_HOST/known_hosts"
qemu_log="$TMPDIR_HOST/normal-qemu.log"
root_disk_image="$TMPDIR_HOST/root.img"
data_disk_image="$TMPDIR_HOST/data.img"
audit_root="$TMPDIR_HOST/ext4-audit"
candidate_root="$TMPDIR_HOST/rootfs-candidate"

PERSISTENT_DISK_IMAGE="$data_disk_image" "$ROOT_DIR/scripts/ensure-persistent-disk.sh" >/dev/null

(
  cd "$ROOT_DIR"
  ROOT_DISK_IMAGE="$root_disk_image" \
    PERSISTENT_DISK_IMAGE="$data_disk_image" \
    GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    ./scripts/run-phase2.sh >"$qemu_log" 2>&1
) &
VALIDATE_VM_PID=$!

if ! wait_for_guest_ssh "$known_hosts_file"; then
  echo "timed out waiting for temporary mke2fs-d validation guest SSH" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
HOST_GUEST_EXT4_AUDIT_ROOT="$audit_root" \
  "$ROOT_DIR/scripts/audit-guest-ext4-sealing.sh" >/dev/null

audit_report="$audit_root/current/report.txt"
if [[ ! -f "$audit_report" ]]; then
  echo "Missing copied ext4 audit report: $audit_report" >&2
  exit 1
fi

grep -Fq 'guest_native_ext4_ready: yes' "$audit_report"
grep -Fq 'guest_native_ext4_path: mke2fs-d' "$audit_report"
grep -Fq 'mke2fs_supports_populate_dir: yes' "$audit_report"

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
ALLOW_HOST_ROOTFS_SEAL_FALLBACK=0 \
  "$ROOT_DIR/scripts/build-guest-rootfs-artifacts.sh" >/dev/null

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
HOST_GUEST_ROOTFS_CANDIDATE_ROOT="$candidate_root" \
  "$ROOT_DIR/scripts/validate-guest-rootfs-artifacts.sh" >/dev/null

candidate_manifest="$candidate_root/current/manifest.toml"
if [[ ! -f "$candidate_manifest" ]]; then
  echo "Missing copied guest rootfs manifest: $candidate_manifest" >&2
  exit 1
fi

grep -Fq 'seal_method = "guest-mke2fs-d"' "$candidate_manifest"
grep -Fq 'seal_required = false' "$candidate_manifest"
grep -Fq 'staged_seal_method = "guest-mke2fs-d"' "$candidate_manifest"
grep -Fq 'staged_input_metadata = "rootfs-inputs.toml"' "$candidate_manifest"
grep -Fq 'staged_input_root_manifest = "input-root.manifest"' "$candidate_manifest"
grep -Fq 'source_post_fakeroot = "normal-post-fakeroot.sh"' "$candidate_manifest"
grep -Fq 'normal_seed_tree_manifest = "normal-rootfs-tree.manifest"' "$candidate_manifest"

shutdown_vm "$known_hosts_file"
echo "Validated in-guest mke2fs -d support and guest-native rootfs sealing."
echo "  audit_report: $audit_report"
echo "  candidate_manifest: $candidate_manifest"
