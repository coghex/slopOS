#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
BUILDROOT_OUTPUT_DIR="$ROOT_DIR/artifacts/buildroot-output/images"
BUILDROOT_KERNEL_IMAGE="$BUILDROOT_OUTPUT_DIR/Image"
BUILDROOT_ROOTFS_IMAGE="$BUILDROOT_OUTPUT_DIR/rootfs.ext4"
BUILDROOT_ROOTFS_EXT2_IMAGE="$BUILDROOT_OUTPUT_DIR/rootfs.ext2"
HOST_RECIPE_ROOT="${HOST_RECIPE_ROOT:-$ROOT_DIR/packages}"
SLOPPKG_RECIPE_DIR="$(find "$HOST_RECIPE_ROOT/sloppkg" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1 || true)"
PUBLISH_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-publish-http-repo"
SYNC_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-sync-world"
CANONICAL_WORLD_TARGET="${CANONICAL_WORLD_TARGET:-selfhost-world}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-180}"
RESET_PREFLIGHT_SLOPPKG_BIN="${RESET_PREFLIGHT_SLOPPKG_BIN:-/tmp/sloppkg-reset-preflight}"
STAGE_CURRENT_RECIPE_ROOT="${STAGE_CURRENT_RECIPE_ROOT:-1}"
STAGED_GUEST_RECIPE_ROOT="${STAGED_GUEST_RECIPE_ROOT:-/tmp/packages}"
GUEST_PUBLISH_HELPER_DEST="${GUEST_PUBLISH_HELPER_DEST:-/tmp/slopos-publish-http-repo}"
GUEST_SYNC_HELPER_DEST="${GUEST_SYNC_HELPER_DEST:-/tmp/slopos-sync-world}"
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
SOURCE_PERSISTENT_DISK_FROZEN=0
VALIDATE_KNOWN_HOSTS_FILE=""

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-reset-to-world.sh

Boots an isolated temporary VM from a fresh Buildroot root disk plus a cloned
persistent data disk, then proves the documented reset-to-world recovery flow:
  1. fresh boot still exposes the seeded guest orchestration helpers
  2. in-guest slopos-sync-world replays the managed world from persistent state
  3. in-guest slopos-validate-managed-world confirms the restored surface
  4. a reboot preserves the managed handoffs and leaves sloppkg healthy
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
    echo "Missing required Buildroot boot artifact: $required" >&2
    exit 1
  fi
done

# shellcheck disable=SC1090
source "$CONFIG_FILE"

SOURCE_PERSISTENT_DISK_IMAGE="${SOURCE_PERSISTENT_DISK_IMAGE:-$ROOT_DIR/qemu/$PERSISTENT_DISK_FILENAME}"
if [[ ! -f "$SOURCE_PERSISTENT_DISK_IMAGE" ]]; then
  echo "Missing source persistent disk image: $SOURCE_PERSISTENT_DISK_IMAGE" >&2
  echo "Boot the main guest once and ensure $SOURCE_PERSISTENT_DISK_IMAGE exists before running reset validation." >&2
  exit 1
fi

cleanup() {
  local status=$?
  if [[ "$SOURCE_PERSISTENT_DISK_FROZEN" == "1" ]]; then
    "$ROOT_DIR/scripts/ssh-guest.sh" "fsfreeze -u '$PERSISTENT_MOUNTPOINT'" >/dev/null 2>&1 || true
    SOURCE_PERSISTENT_DISK_FROZEN=0
  fi
  if [[ -n "$VALIDATE_VM_PID" ]] && kill -0 "$VALIDATE_VM_PID" 2>/dev/null; then
    if [[ -n "$VALIDATE_KNOWN_HOSTS_FILE" ]]; then
      shutdown_vm "$VALIDATE_KNOWN_HOSTS_FILE"
    else
      kill "$VALIDATE_VM_PID" 2>/dev/null || true
      wait "$VALIDATE_VM_PID" 2>/dev/null || true
      VALIDATE_VM_PID=""
    fi
  fi
  if [[ -n "$TMPDIR_HOST" && -d "$TMPDIR_HOST" ]]; then
    if [[ "$status" -eq 0 ]]; then
      rm -rf "$TMPDIR_HOST"
    else
      echo "Preserved reset-to-world validation artifacts under $TMPDIR_HOST" >&2
    fi
  fi
  return "$status"
}

handle_signal() {
  local signal="$1"
  trap - EXIT
  cleanup
  case "$signal" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    HUP) exit 129 ;;
    *) exit 1 ;;
  esac
}

trap cleanup EXIT
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM
trap 'handle_signal HUP' HUP

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

reboot_and_wait() {
  local known_hosts_file="$1"
  local qemu_log="$2"

  GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    KNOWN_HOSTS_FILE="$known_hosts_file" \
    "$ROOT_DIR/scripts/ssh-guest.sh" 'reboot' >/dev/null 2>&1 || true

  local down_deadline=$((SECONDS + 60))
  while (( SECONDS < down_deadline )); do
    if ! GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
      KNOWN_HOSTS_FILE="$known_hosts_file" \
      "$ROOT_DIR/scripts/ssh-guest.sh" 'true' >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! wait_for_guest_ssh "$known_hosts_file"; then
    echo "timed out waiting for reset-to-world reboot" >&2
    tail -n 80 "$qemu_log" >&2 || true
    exit 1
  fi
}

clone_persistent_disk() {
  local source_image="$1"
  local target_image="$2"
  local status=0

  if "$ROOT_DIR/scripts/ssh-guest.sh" \
    "command -v fsfreeze >/dev/null 2>&1 && mountpoint -q '$PERSISTENT_MOUNTPOINT'" \
    >/dev/null 2>&1; then
    "$ROOT_DIR/scripts/ssh-guest.sh" "sync && fsfreeze -f '$PERSISTENT_MOUNTPOINT'" >/dev/null
    SOURCE_PERSISTENT_DISK_FROZEN=1
  fi

  if cp -c "$source_image" "$target_image" 2>/dev/null; then
    status=0
  else
    cp "$source_image" "$target_image" || status=$?
  fi

  if [[ "$SOURCE_PERSISTENT_DISK_FROZEN" == "1" ]]; then
    "$ROOT_DIR/scripts/ssh-guest.sh" "fsfreeze -u '$PERSISTENT_MOUNTPOINT'" >/dev/null 2>&1 || true
    SOURCE_PERSISTENT_DISK_FROZEN=0
  fi

  return "$status"
}

read -r -d '' pre_sync_check <<'EOF' || true
python3 - <<'PY'
import os

required_exec = (
    "/usr/sbin/slopos-publish-http-repo",
    "/usr/sbin/slopos-sync-world",
    "/usr/sbin/slopos-validate-managed-world",
    "/usr/local/bin/sloppkg",
    "/bin/login",
    "/bin/dash",
)
for path in required_exec:
    if not os.access(path, os.X_OK):
        raise SystemExit(f"missing required executable on fresh reset boot: {path}")

if os.path.lexists("/bin/ash"):
    raise SystemExit("unexpected BusyBox shell path present after reset: /bin/ash")

if os.path.realpath("/sbin/getty") != os.path.realpath("/sbin/agetty"):
    raise SystemExit("/sbin/getty does not resolve to the seeded agetty provider")
PY
EOF

read -r -d '' post_reboot_check <<EOF || true
python3 - <<'PY'
import os
import subprocess

required_exec = (
    "/usr/sbin/slopos-publish-http-repo",
    "/usr/sbin/slopos-sync-world",
    "/usr/sbin/slopos-validate-managed-world",
    "/usr/local/bin/sloppkg",
    "/usr/local/bin/sqlite3",
)
for path in required_exec:
    if not os.access(path, os.X_OK):
        raise SystemExit(f"missing executable after reset-to-world reboot: {path}")

if os.path.realpath("/bin/sh") != "/usr/local/bin/dash":
    raise SystemExit(f"/bin/sh did not resolve to managed dash: {os.path.realpath('/bin/sh')}")

if os.path.realpath("/sbin/getty") != "/usr/local/sbin/agetty":
    raise SystemExit(f"/sbin/getty did not resolve to managed agetty: {os.path.realpath('/sbin/getty')}")

if os.path.lexists("/bin/ash"):
    raise SystemExit("unexpected BusyBox shell path present after reset-to-world reboot: /bin/ash")

dropbear_path = os.path.realpath("/usr/sbin/dropbear")
if not dropbear_path.startswith("/Volumes/slopos-data/"):
    raise SystemExit(f"persistent Dropbear handoff missing after reboot: {dropbear_path}")

doctor_output = subprocess.check_output(
    ["/usr/local/bin/sloppkg", "--state-root", "/Volumes/slopos-data/pkg", "doctor"],
    text=True,
)
if "status: ok" not in doctor_output:
    raise SystemExit(f"sloppkg doctor did not report status ok:\\n{doctor_output}")

packages_line = ""
for line in doctor_output.splitlines():
    if line.startswith("packages: "):
        packages_line = line
        break
if not packages_line:
    raise SystemExit(f"sloppkg doctor did not report package count:\\n{doctor_output}")

package_count = int(packages_line.split(": ", 1)[1])
if package_count < 1:
    raise SystemExit(f"sloppkg doctor reported no packages after reset-to-world replay: {doctor_output}")

world_target = "${CANONICAL_WORLD_TARGET}"
world_db = "/Volumes/slopos-data/pkg/db/state.sqlite"
if not os.path.exists(world_db):
    raise SystemExit(f"missing world database after reset-to-world replay: {world_db}")

sql_world_target = world_target.replace("'", "''")
query = f"select count(*) from world where package_name = '{sql_world_target}';"
result = subprocess.check_output(
    ["/usr/local/bin/sqlite3", world_db, query],
    text=True,
).strip()
if result == "0":
    raise SystemExit(f"canonical world target {world_target} is not recorded in the world table")
PY
EOF

mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/validate-reset-to-world.XXXXXX")"

known_hosts_file="$TMPDIR_HOST/known_hosts"
VALIDATE_KNOWN_HOSTS_FILE="$known_hosts_file"
qemu_log="$TMPDIR_HOST/reset-to-world-qemu.log"
root_disk_image="$TMPDIR_HOST/reset-root.img"
data_disk_image="$TMPDIR_HOST/reset-data.img"

clone_persistent_disk "$SOURCE_PERSISTENT_DISK_IMAGE" "$data_disk_image"

(
  cd "$ROOT_DIR"
  ROOT_DISK_IMAGE="$root_disk_image" \
    PERSISTENT_DISK_IMAGE="$data_disk_image" \
    ROOTFS_SOURCE_IMAGE="$BUILDROOT_ROOTFS_IMAGE" \
    KERNEL_IMAGE="$BUILDROOT_KERNEL_IMAGE" \
    RESET_ROOT_DISK=1 \
    GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    exec ./scripts/run-phase2.sh >"$qemu_log" 2>&1
) &
VALIDATE_VM_PID=$!

if ! wait_for_guest_ssh "$known_hosts_file"; then
  echo "timed out waiting for reset-to-world guest SSH" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

if ! grep -Fq "Reset root disk from $BUILDROOT_ROOTFS_IMAGE" "$qemu_log" \
  && ! grep -Fq "Created root disk $root_disk_image from $BUILDROOT_ROOTFS_IMAGE" "$qemu_log"; then
  echo "reset-to-world boot did not create or reseed the temporary root disk from $BUILDROOT_ROOTFS_IMAGE" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

if ! grep -Fq "Using normal boot kernel: $BUILDROOT_KERNEL_IMAGE" "$qemu_log"; then
  echo "reset-to-world boot did not select the Buildroot kernel $BUILDROOT_KERNEL_IMAGE" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" "$pre_sync_check"

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
INSTALL_PATH="$RESET_PREFLIGHT_SLOPPKG_BIN" \
  "$ROOT_DIR/scripts/build-sloppkg-guest.sh" >/dev/null

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/scp-to-guest.sh" "$PUBLISH_HELPER_SOURCE" "$GUEST_PUBLISH_HELPER_DEST"

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/scp-to-guest.sh" "$SYNC_HELPER_SOURCE" "$GUEST_SYNC_HELPER_DEST"

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" \
  "chmod 0755 '$GUEST_PUBLISH_HELPER_DEST' '$GUEST_SYNC_HELPER_DEST'"

if [[ "$STAGE_CURRENT_RECIPE_ROOT" == "1" ]]; then
  GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
  KNOWN_HOSTS_FILE="$known_hosts_file" \
    "$ROOT_DIR/scripts/ssh-guest.sh" "rm -rf '$STAGED_GUEST_RECIPE_ROOT'"

  GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
  KNOWN_HOSTS_FILE="$known_hosts_file" \
    "$ROOT_DIR/scripts/scp-to-guest.sh" "$HOST_RECIPE_ROOT" "$(dirname "$STAGED_GUEST_RECIPE_ROOT")/"

  if [[ -n "$SLOPPKG_RECIPE_DIR" ]]; then
    sloppkg_recipe_basename="$(basename "$SLOPPKG_RECIPE_DIR")"
    GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    KNOWN_HOSTS_FILE="$known_hosts_file" \
      "$ROOT_DIR/scripts/ssh-guest.sh" \
      "test -f '$RESET_PREFLIGHT_SLOPPKG_BIN' && mkdir -p '$STAGED_GUEST_RECIPE_ROOT/sloppkg/$sloppkg_recipe_basename/payload' && install -m 0755 '$RESET_PREFLIGHT_SLOPPKG_BIN' '$STAGED_GUEST_RECIPE_ROOT/sloppkg/$sloppkg_recipe_basename/payload/sloppkg'"
  fi
fi

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" \
  "rm -rf /Volumes/slopos-data/pkg/published /Volumes/slopos-data/pkg/build /Volumes/slopos-data/pkg/repos/snapshots && mkdir -p /Volumes/slopos-data/pkg/repos/snapshots"

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" \
  "SLOPOS_PUBLISH_HTTP_REPO=$GUEST_PUBLISH_HELPER_DEST GUEST_SLOPPKG_BIN=$RESET_PREFLIGHT_SLOPPKG_BIN GUEST_RECIPE_ROOT=$STAGED_GUEST_RECIPE_ROOT CANONICAL_WORLD_TARGET=$CANONICAL_WORLD_TARGET $GUEST_SYNC_HELPER_DEST --require-ready-cache && slopos-validate-managed-world --world-target $CANONICAL_WORLD_TARGET"

reboot_and_wait "$known_hosts_file" "$qemu_log"

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" "$post_reboot_check"

shutdown_vm "$known_hosts_file"

echo "Validated reset-to-world recovery flow."
echo "  world_target: $CANONICAL_WORLD_TARGET"
echo "  rootfs_seed: $BUILDROOT_ROOTFS_IMAGE"
echo "  kernel_seed: $BUILDROOT_KERNEL_IMAGE"
echo "  cloned_data_disk: $data_disk_image"
