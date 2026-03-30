#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
HOST_CANDIDATE_ROOT="${HOST_GUEST_ROOTFS_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-rootfs-candidate}"
CANDIDATE_IMAGE="${HOST_GUEST_ROOTFS_CANDIDATE_IMAGE:-$HOST_CANDIDATE_ROOT/current/rootfs.ext4}"
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
Usage: ./scripts/validate-guest-rootfs-boot-candidate.sh

Boots a temporary VM through ./scripts/run-phase2.sh using the host-side
validated guest rootfs candidate as ROOTFS_SOURCE_IMAGE, while keeping the
default Buildroot kernel, then verifies the normal seed contract over SSH.
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

if [[ "$CANDIDATE_IMAGE" != /* ]]; then
  CANDIDATE_IMAGE="$ROOT_DIR/$CANDIDATE_IMAGE"
fi

if [[ ! -f "$CANDIDATE_IMAGE" ]]; then
  echo "Missing host-side guest rootfs candidate: $CANDIDATE_IMAGE" >&2
  echo "Run ./scripts/validate-guest-rootfs-artifacts.sh first." >&2
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

repo_owned_paths_literal="$(python3 - "$ROOT_DIR/rootfs/bootstrap-manifest.toml" <<'PY'
import sys

paths = []
capture = False
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        stripped = line.strip()
        if stripped == "repo_owned_paths = [":
            capture = True
            continue
        if capture:
            if stripped == "]":
                break
            if stripped.endswith(","):
                stripped = stripped[:-1]
            paths.append(stripped.strip('"'))

print(repr(paths))
PY
)"

mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/validate-guest-rootfs-boot.XXXXXX")"
known_hosts_file="$TMPDIR_HOST/known_hosts"
qemu_log="$TMPDIR_HOST/normal-qemu.log"
root_disk_image="$TMPDIR_HOST/root.img"
data_disk_image="$TMPDIR_HOST/data.img"

PERSISTENT_DISK_IMAGE="$data_disk_image" "$ROOT_DIR/scripts/ensure-persistent-disk.sh" >/dev/null

(
  cd "$ROOT_DIR"
  ROOT_DISK_IMAGE="$root_disk_image" \
    PERSISTENT_DISK_IMAGE="$data_disk_image" \
    ROOTFS_SOURCE_IMAGE="$CANDIDATE_IMAGE" \
    RESET_ROOT_DISK=1 \
    GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    ./scripts/run-phase2.sh >"$qemu_log" 2>&1
) &
VALIDATE_VM_PID=$!

if ! wait_for_guest_ssh "$known_hosts_file"; then
  echo "timed out waiting for candidate boot guest SSH" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

if ! grep -Fq "Reset root disk from $CANDIDATE_IMAGE" "$qemu_log" \
  && ! grep -Fq "Created root disk $root_disk_image from $CANDIDATE_IMAGE" "$qemu_log"; then
  echo "candidate boot did not create or reseed the temporary root disk from $CANDIDATE_IMAGE" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

read -r -d '' remote_check <<EOF || true
python3 - <<'PY'
import os

repo_owned_paths = $repo_owned_paths_literal

for unexpected in ("/bin/busybox", "/linuxrc", "/bin/ash"):
    if os.path.lexists(unexpected):
        raise SystemExit(f"unexpected live path present: {unexpected}")

for required in ("/bin/sh", "/sbin/getty", "/usr/sbin/seedrng"):
    if not os.path.lexists(required):
        raise SystemExit(f"missing live path: {required}")

for required in repo_owned_paths:
    if not os.path.lexists(required):
        raise SystemExit(f"missing live repo-owned seed path: {required}")

for helper_path in repo_owned_paths:
    if not helper_path.startswith("/usr/sbin/slopos-"):
        continue
    if not os.access(helper_path, os.X_OK):
        raise SystemExit(f"live helper is not executable: {helper_path}")

compatibility_links = {
    "/bin/sh": "/bin/dash",
    "/sbin/getty": "/sbin/agetty",
    "/sbin/ifup": "/usr/sbin/ifup",
    "/sbin/ifdown": "/usr/sbin/ifdown",
}

for link_path, expected_target in compatibility_links.items():
    if not os.path.islink(link_path):
        raise SystemExit(f"live compatibility path is not a symlink: {link_path}")
    link_target = os.readlink(link_path)
    if link_target != expected_target:
        raise SystemExit(
            f"unexpected live compatibility target for {link_path}: {link_target} (expected {expected_target})"
        )

mounted = False
with open("/proc/mounts", "r", encoding="utf-8") as fh:
    for line in fh:
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "/Volumes/slopos-data":
            mounted = True
            break

if not mounted:
    raise SystemExit("persistent data mount is missing at /Volumes/slopos-data")

managed_leaks = []
if os.path.lexists("/usr/local"):
    for dirpath, dirnames, filenames in os.walk("/usr/local"):
        dirnames.sort()
        filenames.sort()
        for dirname in list(dirnames):
            full_dir = os.path.join(dirpath, dirname)
            if os.path.islink(full_dir):
                managed_leaks.append(full_dir)
        for filename in filenames:
            managed_leaks.append(os.path.join(dirpath, filename))

if managed_leaks:
    raise SystemExit(
        "unexpected managed /usr/local content in candidate boot: "
        + ", ".join(sorted(managed_leaks))
    )

bad = []
for directory in ("/bin", "/sbin", "/usr/bin", "/usr/sbin"):
    for entry in os.listdir(directory):
        full_path = os.path.join(directory, entry)
        if not os.path.islink(full_path):
            continue
        target = os.readlink(full_path)
        if "busybox" in target.split("/"):
            bad.append(f"{full_path}->{target}")

if bad:
    raise SystemExit("unexpected live BusyBox symlinks in candidate boot: " + ", ".join(sorted(bad)))

print("guest rootfs candidate boot validation passed")
PY
EOF

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
  KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" "$remote_check"

shutdown_vm "$known_hosts_file"
echo "Validated run-phase2 opt-in boot from $CANDIDATE_IMAGE"
