#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
BOOT_SELECTION_HELPER="$ROOT_DIR/scripts/boot-selection.sh"
HOST_PROMOTED_BOOT_ROOT="${HOST_GUEST_PROMOTED_BOOT_ROOT:-$ROOT_DIR/artifacts/guest-boot-promoted}"
PROMOTED_BOOT_CURRENT="$HOST_PROMOTED_BOOT_ROOT/current"
PROMOTED_ROOTFS_IMAGE="$PROMOTED_BOOT_CURRENT/rootfs.ext4"
PROMOTED_KERNEL_IMAGE="$PROMOTED_BOOT_CURRENT/Image"
PROMOTED_ROOTFS_MANIFEST="$PROMOTED_BOOT_CURRENT/rootfs.manifest.toml"
PROMOTED_ROOTFS_HANDOFF="$PROMOTED_BOOT_CURRENT/rootfs.host-handoff.toml"
PROMOTED_KERNEL_MANIFEST="$PROMOTED_BOOT_CURRENT/kernel.manifest.toml"
PROMOTED_KERNEL_HANDOFF="$PROMOTED_BOOT_CURRENT/kernel.host-handoff.toml"
PROMOTED_KERNEL_SYSTEM_MAP="$PROMOTED_BOOT_CURRENT/System.map"
PROMOTED_KERNEL_CONFIG="$PROMOTED_BOOT_CURRENT/linux.config"
PROMOTED_KERNEL_MODULES_ARCHIVE="$PROMOTED_BOOT_CURRENT/modules.tar.xz"
PROMOTED_KERNEL_MODULE_SYMVERS="$PROMOTED_BOOT_CURRENT/Module.symvers"
PROMOTION_METADATA="$PROMOTED_BOOT_CURRENT/promotion.toml"
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

if [[ ! -f "$BOOT_SELECTION_HELPER" ]]; then
  echo "Missing boot selection helper: $BOOT_SELECTION_HELPER" >&2
  exit 1
fi

for var_name in \
  HOST_PROMOTED_BOOT_ROOT \
  PROMOTED_BOOT_CURRENT \
  PROMOTED_ROOTFS_IMAGE \
  PROMOTED_KERNEL_IMAGE \
  PROMOTED_ROOTFS_MANIFEST \
  PROMOTED_ROOTFS_HANDOFF \
  PROMOTED_KERNEL_MANIFEST \
  PROMOTED_KERNEL_SYSTEM_MAP \
  PROMOTED_KERNEL_CONFIG \
  PROMOTED_KERNEL_MODULES_ARCHIVE \
  PROMOTED_KERNEL_MODULE_SYMVERS; do
  var_value="${!var_name}"
  if [[ "$var_value" != /* ]]; then
    printf -v "$var_name" '%s/%s' "$ROOT_DIR" "$var_value"
  fi
done

for var_name in PROMOTED_KERNEL_HANDOFF PROMOTION_METADATA; do
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
  "$PROMOTED_ROOTFS_MANIFEST" \
  "$PROMOTED_ROOTFS_HANDOFF" \
  "$PROMOTED_KERNEL_MANIFEST" \
  "$PROMOTED_KERNEL_HANDOFF" \
  "$PROMOTED_KERNEL_SYSTEM_MAP" \
  "$PROMOTED_KERNEL_CONFIG" \
  "$PROMOTED_KERNEL_MODULES_ARCHIVE" \
  "$PROMOTION_METADATA" \
  "$BUILDROOT_KERNEL_IMAGE" \
  "$BUILDROOT_ROOTFS_IMAGE"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing required boot artifact: $required" >&2
    exit 1
  fi
done

# shellcheck disable=SC1090
source "$BOOT_SELECTION_HELPER"
HOST_GUEST_PROMOTED_BOOT_ROOT="$HOST_PROMOTED_BOOT_ROOT"
resolve_promoted_boot_paths

python3 - "$PROMOTED_ROOTFS_IMAGE" "$PROMOTED_ROOTFS_MANIFEST" "$PROMOTED_ROOTFS_HANDOFF" "$PROMOTED_KERNEL_IMAGE" "$PROMOTED_KERNEL_MANIFEST" "$PROMOTED_KERNEL_HANDOFF" "$PROMOTED_KERNEL_SYSTEM_MAP" "$PROMOTED_KERNEL_CONFIG" "$PROMOTED_KERNEL_MODULES_ARCHIVE" "$PROMOTED_KERNEL_MODULE_SYMVERS" "$PROMOTION_METADATA" <<'PY'
import hashlib
import pathlib
import sys

rootfs_image = pathlib.Path(sys.argv[1])
rootfs_manifest = pathlib.Path(sys.argv[2])
rootfs_handoff = pathlib.Path(sys.argv[3])
kernel_image = pathlib.Path(sys.argv[4])
kernel_manifest = pathlib.Path(sys.argv[5])
kernel_handoff = pathlib.Path(sys.argv[6])
kernel_system_map = pathlib.Path(sys.argv[7])
kernel_config = pathlib.Path(sys.argv[8])
kernel_modules_archive = pathlib.Path(sys.argv[9])
kernel_module_symvers = pathlib.Path(sys.argv[10])
promotion = pathlib.Path(sys.argv[11])

def parse_toml(path: pathlib.Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        value = value.strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        data[key] = value
    return data

rootfs_manifest_data = parse_toml(rootfs_manifest)
rootfs_handoff_data = parse_toml(rootfs_handoff)
kernel_manifest_data = parse_toml(kernel_manifest)
kernel_handoff_data = parse_toml(kernel_handoff)
promotion_data = parse_toml(promotion)

if rootfs_manifest_data.get("schema_version") != "3":
    raise SystemExit("promoted rootfs manifest schema_version is not 3")
for key, expected in {
    "source_post_fakeroot": "normal-post-fakeroot.sh",
    "staged_input_metadata": "rootfs-inputs.toml",
    "staged_input_root_manifest": "input-root.manifest",
    "normal_seed_tree_manifest": "normal-rootfs-tree.manifest",
    "mutable_overlay_manifest": "rootfs-overlay.manifest",
    "image_name": "rootfs.ext4",
}.items():
    if rootfs_manifest_data.get(key) != expected:
        raise SystemExit(f"unexpected promoted rootfs manifest {key}: {rootfs_manifest_data.get(key)!r}")
if "staged_seal_method" not in rootfs_manifest_data:
    raise SystemExit("promoted rootfs manifest is missing staged_seal_method")

rootfs_image_sha = hashlib.sha256(rootfs_image.read_bytes()).hexdigest()
rootfs_manifest_sha = hashlib.sha256(rootfs_manifest.read_bytes()).hexdigest()
kernel_system_map_sha = hashlib.sha256(kernel_system_map.read_bytes()).hexdigest()
kernel_config_sha = hashlib.sha256(kernel_config.read_bytes()).hexdigest()
kernel_image_sha = hashlib.sha256(kernel_image.read_bytes()).hexdigest()
kernel_manifest_sha = hashlib.sha256(kernel_manifest.read_bytes()).hexdigest()
kernel_modules_archive_sha = hashlib.sha256(kernel_modules_archive.read_bytes()).hexdigest()

if kernel_manifest_data.get("schema_version") != "3":
    raise SystemExit("promoted kernel manifest schema_version is not 3")
for key, expected in {
    "image_name": "Image",
    "modules_archive_name": "modules.tar.xz",
    "system_map_name": "System.map",
    "resolved_config_name": "linux.config",
}.items():
    if kernel_manifest_data.get(key) != expected:
        raise SystemExit(f"unexpected promoted kernel manifest {key}: {kernel_manifest_data.get(key)!r}")
for required_key in (
    "input_root",
    "staged_input_metadata",
    "staged_input_root_manifest",
    "staged_patch_manifest",
):
    if required_key not in kernel_manifest_data:
        raise SystemExit(f"promoted kernel manifest is missing {required_key}")
if kernel_manifest_data.get("image_sha256") != kernel_image_sha:
    raise SystemExit("promoted kernel manifest image_sha256 does not match promoted kernel image")
if kernel_manifest_data.get("modules_archive_sha256") != kernel_modules_archive_sha:
    raise SystemExit("promoted kernel manifest modules_archive_sha256 does not match promoted modules archive")
if kernel_manifest_data.get("system_map_sha256") != kernel_system_map_sha:
    raise SystemExit("promoted kernel manifest system_map_sha256 does not match promoted System.map")
if kernel_manifest_data.get("resolved_config_sha256") != kernel_config_sha:
    raise SystemExit("promoted kernel manifest resolved_config_sha256 does not match promoted linux.config")

if rootfs_handoff_data.get("image_sha256") != rootfs_image_sha:
    raise SystemExit("promoted rootfs handoff image_sha256 does not match promoted rootfs image")
if rootfs_handoff_data.get("manifest_sha256") != rootfs_manifest_sha:
    raise SystemExit("promoted rootfs handoff manifest_sha256 does not match promoted rootfs manifest")
if kernel_handoff_data.get("manifest_schema_version") != kernel_manifest_data.get("schema_version"):
    raise SystemExit("promoted kernel handoff manifest_schema_version does not match promoted kernel manifest")
if kernel_handoff_data.get("image_sha256") != kernel_image_sha:
    raise SystemExit("promoted kernel handoff image_sha256 does not match promoted kernel image")
if kernel_handoff_data.get("manifest_sha256") != kernel_manifest_sha:
    raise SystemExit("promoted kernel handoff manifest_sha256 does not match promoted kernel manifest")
if kernel_handoff_data.get("modules_archive_sha256") != kernel_modules_archive_sha:
    raise SystemExit("promoted kernel handoff modules_archive_sha256 does not match promoted modules archive")
if kernel_handoff_data.get("system_map_sha256") != kernel_system_map_sha:
    raise SystemExit("promoted kernel handoff system_map_sha256 does not match promoted System.map")
if kernel_handoff_data.get("resolved_config_sha256") != kernel_config_sha:
    raise SystemExit("promoted kernel handoff resolved_config_sha256 does not match promoted linux.config")
if kernel_handoff_data.get("kernel_release") != kernel_manifest_data.get("kernel_release"):
    raise SystemExit("promoted kernel handoff kernel_release does not match promoted kernel manifest")

if kernel_module_symvers.is_file():
    kernel_module_symvers_sha = hashlib.sha256(kernel_module_symvers.read_bytes()).hexdigest()
    if kernel_manifest_data.get("module_symvers_sha256") != kernel_module_symvers_sha:
        raise SystemExit("promoted kernel manifest module_symvers_sha256 does not match promoted Module.symvers")
    if kernel_handoff_data.get("module_symvers_sha256") != kernel_module_symvers_sha:
        raise SystemExit("promoted kernel handoff module_symvers_sha256 does not match promoted Module.symvers")

for key, expected in {
    "rootfs_image_sha256": rootfs_image_sha,
    "rootfs_manifest_sha256": rootfs_manifest_sha,
    "kernel_image_sha256": kernel_image_sha,
    "kernel_manifest_sha256": kernel_manifest_sha,
    "kernel_modules_archive_sha256": kernel_modules_archive_sha,
    "kernel_system_map_sha256": kernel_system_map_sha,
    "kernel_resolved_config_sha256": kernel_config_sha,
}.items():
    if promotion_data.get(key) != expected:
        raise SystemExit(f"promotion metadata {key} does not match promoted artifact")

if kernel_module_symvers.is_file():
    kernel_module_symvers_sha = hashlib.sha256(kernel_module_symvers.read_bytes()).hexdigest()
    if promotion_data.get("kernel_module_symvers_sha256") != kernel_module_symvers_sha:
        raise SystemExit("promotion metadata kernel_module_symvers_sha256 does not match promoted Module.symvers")
PY

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

assert_root_disk_boot_selection_metadata() {
  local metadata_path="$1"
  local expected_scope="$2"
  local expected_rootfs_kind="$3"
  local expected_rootfs_image="$4"
  local expected_kernel_kind="$5"
  local expected_kernel_image="$6"
  local expected_promotion_root="$7"
  local expected_promotion_metadata="$8"

  if [[ ! -f "$metadata_path" ]]; then
    echo "Missing root disk boot selection metadata: $metadata_path" >&2
    exit 1
  fi

  python3 - "$metadata_path" "$expected_scope" "$expected_rootfs_kind" "$expected_rootfs_image" "$expected_kernel_kind" "$expected_kernel_image" "$expected_promotion_root" "$expected_promotion_metadata" <<'PY'
import hashlib
import pathlib
import sys

metadata_path = pathlib.Path(sys.argv[1])
expected_scope = sys.argv[2]
expected_rootfs_kind = sys.argv[3]
expected_rootfs_image = sys.argv[4]
expected_kernel_kind = sys.argv[5]
expected_kernel_image = sys.argv[6]
expected_promotion_root = sys.argv[7]
expected_promotion_metadata = sys.argv[8]

data: dict[str, str] = {}
for line in metadata_path.read_text(encoding="utf-8").splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in stripped:
        continue
    key, value = stripped.split("=", 1)
    key = key.strip()
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    data[key] = value

for key, expected in {
    "schema_version": "1",
    "selected_by": "scripts/ensure-root-disk.sh",
    "selection_scope": expected_scope,
    "rootfs_source_kind": expected_rootfs_kind,
    "rootfs_source_image": expected_rootfs_image,
    "kernel_source_kind": expected_kernel_kind,
    "kernel_image": expected_kernel_image,
}.items():
    if data.get(key) != expected:
        raise SystemExit(f"unexpected root disk boot selection metadata {key}: {data.get(key)!r}")

rootfs_sha = hashlib.sha256(pathlib.Path(expected_rootfs_image).read_bytes()).hexdigest()
kernel_sha = hashlib.sha256(pathlib.Path(expected_kernel_image).read_bytes()).hexdigest()
if data.get("rootfs_source_sha256") != rootfs_sha:
    raise SystemExit("root disk boot selection metadata rootfs_source_sha256 does not match expected rootfs image")
if data.get("kernel_image_sha256") != kernel_sha:
    raise SystemExit("root disk boot selection metadata kernel_image_sha256 does not match expected kernel image")

if expected_promotion_root:
    if data.get("promotion_root") != expected_promotion_root:
        raise SystemExit("root disk boot selection metadata promotion_root is unexpected")
    if data.get("promotion_id") != pathlib.Path(expected_promotion_root).name:
        raise SystemExit("root disk boot selection metadata promotion_id is unexpected")
    if expected_promotion_metadata and data.get("promotion_metadata") != expected_promotion_metadata:
        raise SystemExit("root disk boot selection metadata promotion_metadata is unexpected")
else:
    for key in ("promotion_root", "promotion_id", "promotion_metadata"):
        if key in data:
            raise SystemExit(f"root disk boot selection metadata unexpectedly contains {key}")
PY
}

mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/validate-promoted-boot.XXXXXX")"

default_known_hosts_file="$TMPDIR_HOST/default-known_hosts"
default_qemu_log="$TMPDIR_HOST/default-normal-qemu.log"
default_root_disk_image="$TMPDIR_HOST/default-root.img"
default_data_disk_image="$TMPDIR_HOST/default-data.img"

boot_and_assert \
  "promoted default boot" \
  "$RESOLVED_PROMOTED_ROOTFS_IMAGE" \
  "$RESOLVED_PROMOTED_KERNEL_IMAGE" \
  "$default_root_disk_image" \
  "$default_data_disk_image" \
  "$default_known_hosts_file" \
  "$default_qemu_log" \
  "0"

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
KNOWN_HOSTS_FILE="$default_known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" "$remote_check"

shutdown_vm "$default_known_hosts_file"
assert_root_disk_boot_selection_metadata \
  "${default_root_disk_image}.boot-selection.toml" \
  "default" \
  "promoted-default" \
  "$RESOLVED_PROMOTED_ROOTFS_IMAGE" \
  "promoted-default" \
  "$RESOLVED_PROMOTED_KERNEL_IMAGE" \
  "$RESOLVED_PROMOTED_BOOT_ROOT" \
  "$RESOLVED_PROMOTED_BOOT_METADATA"

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
assert_root_disk_boot_selection_metadata \
  "${override_root_disk_image}.boot-selection.toml" \
  "explicit" \
  "explicit" \
  "$BUILDROOT_ROOTFS_IMAGE" \
  "explicit" \
  "$BUILDROOT_KERNEL_IMAGE" \
  "" \
  ""

echo "Validated promoted default normal boot selection."
echo "  promoted_rootfs: $RESOLVED_PROMOTED_ROOTFS_IMAGE"
echo "  promoted_kernel: $RESOLVED_PROMOTED_KERNEL_IMAGE"
