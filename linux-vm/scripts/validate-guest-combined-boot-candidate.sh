#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
HOST_ROOTFS_CANDIDATE_ROOT="${HOST_GUEST_ROOTFS_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-rootfs-candidate}"
HOST_KERNEL_CANDIDATE_ROOT="${HOST_GUEST_KERNEL_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-kernel-candidate}"
ROOTFS_CANDIDATE_IMAGE="${HOST_GUEST_ROOTFS_CANDIDATE_IMAGE:-$HOST_ROOTFS_CANDIDATE_ROOT/current/rootfs.ext4}"
ROOTFS_CANDIDATE_MANIFEST="${HOST_GUEST_ROOTFS_CANDIDATE_MANIFEST:-$HOST_ROOTFS_CANDIDATE_ROOT/current/manifest.toml}"
ROOTFS_CANDIDATE_HANDOFF="${HOST_GUEST_ROOTFS_CANDIDATE_HANDOFF:-$HOST_ROOTFS_CANDIDATE_ROOT/current/host-handoff.toml}"
KERNEL_CANDIDATE_IMAGE="${HOST_GUEST_KERNEL_CANDIDATE_IMAGE:-$HOST_KERNEL_CANDIDATE_ROOT/current/Image}"
KERNEL_CANDIDATE_MANIFEST="${HOST_GUEST_KERNEL_CANDIDATE_MANIFEST:-$HOST_KERNEL_CANDIDATE_ROOT/current/manifest.toml}"
KERNEL_CANDIDATE_HANDOFF="${HOST_GUEST_KERNEL_CANDIDATE_HANDOFF:-$HOST_KERNEL_CANDIDATE_ROOT/current/host-handoff.toml}"
KERNEL_CANDIDATE_SYSTEM_MAP="${HOST_GUEST_KERNEL_CANDIDATE_SYSTEM_MAP:-$HOST_KERNEL_CANDIDATE_ROOT/current/System.map}"
KERNEL_CANDIDATE_CONFIG="${HOST_GUEST_KERNEL_CANDIDATE_CONFIG:-$HOST_KERNEL_CANDIDATE_ROOT/current/linux.config}"
KERNEL_CANDIDATE_MODULES_ARCHIVE="${HOST_GUEST_KERNEL_CANDIDATE_MODULES_ARCHIVE:-$HOST_KERNEL_CANDIDATE_ROOT/current/modules.tar.xz}"
KERNEL_CANDIDATE_MODULE_SYMVERS="${HOST_GUEST_KERNEL_CANDIDATE_MODULE_SYMVERS:-$HOST_KERNEL_CANDIDATE_ROOT/current/Module.symvers}"
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
Usage: ./scripts/validate-guest-combined-boot-candidate.sh

Boots a temporary VM through ./scripts/run-phase2.sh using both host-side
guest-artifact candidates:
  - ROOTFS_SOURCE_IMAGE=artifacts/guest-rootfs-candidate/current/rootfs.ext4
  - KERNEL_IMAGE=artifacts/guest-kernel-candidate/current/Image

The validator confirms the temporary root disk was reseeded from the guest
rootfs candidate, that run-phase2 selected the guest kernel candidate, and that
the live guest reports the expected kernel release while preserving the normal
seed contract.
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

for var_name in ROOTFS_CANDIDATE_IMAGE ROOTFS_CANDIDATE_MANIFEST ROOTFS_CANDIDATE_HANDOFF KERNEL_CANDIDATE_IMAGE KERNEL_CANDIDATE_MANIFEST KERNEL_CANDIDATE_HANDOFF KERNEL_CANDIDATE_SYSTEM_MAP KERNEL_CANDIDATE_CONFIG KERNEL_CANDIDATE_MODULES_ARCHIVE KERNEL_CANDIDATE_MODULE_SYMVERS; do
  var_value="${!var_name}"
  if [[ "$var_value" != /* ]]; then
    printf -v "$var_name" '%s/%s' "$ROOT_DIR" "$var_value"
  fi
done

for required in "$ROOTFS_CANDIDATE_IMAGE" "$ROOTFS_CANDIDATE_MANIFEST" "$ROOTFS_CANDIDATE_HANDOFF"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing host-side guest rootfs candidate input: $required" >&2
    echo "Run ./scripts/validate-guest-rootfs-artifacts.sh first." >&2
    exit 1
  fi
done

for required in "$KERNEL_CANDIDATE_IMAGE" "$KERNEL_CANDIDATE_MANIFEST" "$KERNEL_CANDIDATE_HANDOFF" "$KERNEL_CANDIDATE_SYSTEM_MAP" "$KERNEL_CANDIDATE_CONFIG" "$KERNEL_CANDIDATE_MODULES_ARCHIVE"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing host-side guest kernel candidate input: $required" >&2
    echo "Run ./scripts/promote-guest-kernel-candidate.sh first." >&2
    exit 1
  fi
done

python3 - "$ROOTFS_CANDIDATE_IMAGE" "$ROOTFS_CANDIDATE_MANIFEST" "$ROOTFS_CANDIDATE_HANDOFF" "$KERNEL_CANDIDATE_IMAGE" "$KERNEL_CANDIDATE_MANIFEST" "$KERNEL_CANDIDATE_HANDOFF" "$KERNEL_CANDIDATE_SYSTEM_MAP" "$KERNEL_CANDIDATE_CONFIG" "$KERNEL_CANDIDATE_MODULES_ARCHIVE" "$KERNEL_CANDIDATE_MODULE_SYMVERS" <<'PY'
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
kernel_module_symvers = pathlib.Path(sys.argv[10]) if sys.argv[10] else None

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

if rootfs_manifest_data.get("schema_version") != "3":
    raise SystemExit("rootfs candidate manifest schema_version is not 3")
for key, expected in {
    "source_post_fakeroot": "normal-post-fakeroot.sh",
    "staged_input_metadata": "rootfs-inputs.toml",
    "staged_input_root_manifest": "input-root.manifest",
    "normal_seed_tree_manifest": "normal-rootfs-tree.manifest",
    "mutable_overlay_manifest": "rootfs-overlay.manifest",
    "image_name": "rootfs.ext4",
}.items():
    if rootfs_manifest_data.get(key) != expected:
        raise SystemExit(f"unexpected rootfs candidate manifest {key}: {rootfs_manifest_data.get(key)!r}")
if "staged_seal_method" not in rootfs_manifest_data:
    raise SystemExit("rootfs candidate manifest is missing staged_seal_method")

rootfs_image_sha = hashlib.sha256(rootfs_image.read_bytes()).hexdigest()
rootfs_manifest_sha = hashlib.sha256(rootfs_manifest.read_bytes()).hexdigest()
if rootfs_handoff_data.get("image_sha256") != rootfs_image_sha:
    raise SystemExit("rootfs candidate handoff image_sha256 does not match candidate image")
if rootfs_handoff_data.get("manifest_sha256") != rootfs_manifest_sha:
    raise SystemExit("rootfs candidate handoff manifest_sha256 does not match candidate manifest")

if kernel_manifest_data.get("schema_version") != "3":
    raise SystemExit("kernel candidate manifest schema_version is not 3")
for key, expected in {
    "image_name": "Image",
    "modules_archive_name": "modules.tar.xz",
    "system_map_name": "System.map",
    "resolved_config_name": "linux.config",
}.items():
    if kernel_manifest_data.get(key) != expected:
        raise SystemExit(f"unexpected kernel candidate manifest {key}: {kernel_manifest_data.get(key)!r}")
for required_key in (
    "input_root",
    "staged_input_metadata",
    "staged_input_root_manifest",
    "staged_patch_manifest",
):
    if required_key not in kernel_manifest_data:
        raise SystemExit(f"kernel candidate manifest is missing {required_key}")

kernel_image_sha = hashlib.sha256(kernel_image.read_bytes()).hexdigest()
kernel_manifest_sha = hashlib.sha256(kernel_manifest.read_bytes()).hexdigest()
kernel_modules_archive_sha = hashlib.sha256(kernel_modules_archive.read_bytes()).hexdigest()
kernel_system_map_sha = hashlib.sha256(kernel_system_map.read_bytes()).hexdigest()
kernel_config_sha = hashlib.sha256(kernel_config.read_bytes()).hexdigest()
if kernel_manifest_data.get("image_sha256") != kernel_image_sha:
    raise SystemExit("kernel candidate manifest image_sha256 does not match candidate image")
if kernel_manifest_data.get("modules_archive_sha256") != kernel_modules_archive_sha:
    raise SystemExit("kernel candidate manifest modules_archive_sha256 does not match candidate modules archive")
if kernel_manifest_data.get("system_map_sha256") != kernel_system_map_sha:
    raise SystemExit("kernel candidate manifest system_map_sha256 does not match candidate System.map")
if kernel_manifest_data.get("resolved_config_sha256") != kernel_config_sha:
    raise SystemExit("kernel candidate manifest resolved_config_sha256 does not match candidate linux.config")

if kernel_handoff_data.get("manifest_schema_version") != kernel_manifest_data.get("schema_version"):
    raise SystemExit("kernel candidate handoff manifest_schema_version does not match kernel manifest")
if kernel_handoff_data.get("image_sha256") != kernel_image_sha:
    raise SystemExit("kernel candidate handoff image_sha256 does not match candidate image")
if kernel_handoff_data.get("manifest_sha256") != kernel_manifest_sha:
    raise SystemExit("kernel candidate handoff manifest_sha256 does not match candidate manifest")
if kernel_handoff_data.get("modules_archive_sha256") != kernel_modules_archive_sha:
    raise SystemExit("kernel candidate handoff modules_archive_sha256 does not match candidate modules archive")
if kernel_handoff_data.get("system_map_sha256") != kernel_system_map_sha:
    raise SystemExit("kernel candidate handoff system_map_sha256 does not match candidate System.map")
if kernel_handoff_data.get("resolved_config_sha256") != kernel_config_sha:
    raise SystemExit("kernel candidate handoff resolved_config_sha256 does not match candidate linux.config")
if kernel_handoff_data.get("kernel_release") != kernel_manifest_data.get("kernel_release"):
    raise SystemExit("kernel candidate handoff kernel_release does not match kernel manifest")

if kernel_module_symvers is not None and kernel_module_symvers.is_file():
    kernel_module_symvers_sha = hashlib.sha256(kernel_module_symvers.read_bytes()).hexdigest()
    if kernel_manifest_data.get("module_symvers_sha256") != kernel_module_symvers_sha:
        raise SystemExit("kernel candidate manifest module_symvers_sha256 does not match candidate Module.symvers")
    if kernel_handoff_data.get("module_symvers_sha256") != kernel_module_symvers_sha:
        raise SystemExit("kernel candidate handoff module_symvers_sha256 does not match candidate Module.symvers")
PY

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

ownership_literals="$(python3 - "$ROOT_DIR/rootfs/bootstrap-manifest.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as fh:
    manifest = tomllib.load(fh)

normal_seed_tree = manifest["normal_seed_tree"]
etc_ownership = manifest["etc_ownership"]
print(repr(normal_seed_tree["repo_owned_paths"]))
print(repr(normal_seed_tree["mutable_overlay_paths"]))
print(repr(normal_seed_tree["compatibility_symlinks"]))
print(repr(normal_seed_tree["expected_empty_managed_prefixes"]))
print(repr(manifest["buildroot_seed_surface"].get("disallowed_paths", [])))
print(repr(etc_ownership["repo_owned_prefixes"]))
print(repr(etc_ownership["buildroot_provided_paths"]))
PY
)"
mapfile -t ownership_literal_lines <<<"$ownership_literals"
repo_owned_paths_literal="${ownership_literal_lines[0]}"
mutable_overlay_paths_literal="${ownership_literal_lines[1]}"
compatibility_symlinks_literal="${ownership_literal_lines[2]}"
expected_empty_managed_prefixes_literal="${ownership_literal_lines[3]}"
disallowed_seed_paths_literal="${ownership_literal_lines[4]}"
etc_repo_owned_prefixes_literal="${ownership_literal_lines[5]}"
etc_buildroot_provided_paths_literal="${ownership_literal_lines[6]}"

expected_kernel_release="$(python3 - "$KERNEL_CANDIDATE_MANIFEST" <<'PY'
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

mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/validate-guest-combined-boot.XXXXXX")"
known_hosts_file="$TMPDIR_HOST/known_hosts"
qemu_log="$TMPDIR_HOST/normal-qemu.log"
root_disk_image="$TMPDIR_HOST/root.img"
data_disk_image="$TMPDIR_HOST/data.img"

PERSISTENT_DISK_IMAGE="$data_disk_image" "$ROOT_DIR/scripts/ensure-persistent-disk.sh" >/dev/null

(
  cd "$ROOT_DIR"
  ROOT_DISK_IMAGE="$root_disk_image" \
    PERSISTENT_DISK_IMAGE="$data_disk_image" \
    ROOTFS_SOURCE_IMAGE="$ROOTFS_CANDIDATE_IMAGE" \
    KERNEL_IMAGE="$KERNEL_CANDIDATE_IMAGE" \
    RESET_ROOT_DISK=1 \
    GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    ./scripts/run-phase2.sh >"$qemu_log" 2>&1
) &
VALIDATE_VM_PID=$!

if ! wait_for_guest_ssh "$known_hosts_file"; then
  echo "timed out waiting for combined candidate boot guest SSH" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

if ! grep -Fq "Reset root disk from $ROOTFS_CANDIDATE_IMAGE" "$qemu_log" \
  && ! grep -Fq "Created root disk $root_disk_image from $ROOTFS_CANDIDATE_IMAGE" "$qemu_log"; then
  echo "combined boot did not create or reseed the temporary root disk from $ROOTFS_CANDIDATE_IMAGE" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

if ! grep -Fq "Using normal boot kernel: $KERNEL_CANDIDATE_IMAGE" "$qemu_log"; then
  echo "combined boot did not select the guest kernel candidate $KERNEL_CANDIDATE_IMAGE" >&2
  tail -n 80 "$qemu_log" >&2 || true
  exit 1
fi

read -r -d '' remote_check <<EOF || true
python3 - <<'PY'
import os
import subprocess

repo_owned_paths = $repo_owned_paths_literal
mutable_overlay_paths = $mutable_overlay_paths_literal
compatibility_symlinks = $compatibility_symlinks_literal
expected_empty_managed_prefixes = $expected_empty_managed_prefixes_literal
disallowed_seed_paths = $disallowed_seed_paths_literal
etc_repo_owned_prefixes = $etc_repo_owned_prefixes_literal
etc_buildroot_provided_paths = $etc_buildroot_provided_paths_literal
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

for required in repo_owned_paths:
    if not os.path.lexists(required):
        raise SystemExit(f"missing live repo-owned seed path: {required}")

for required in etc_repo_owned_prefixes:
    if not os.path.isdir(required):
        raise SystemExit(f"missing live repo-owned /etc subtree: {required}")

for required in etc_buildroot_provided_paths:
    if not os.path.lexists(required):
        raise SystemExit(f"missing live Buildroot-provided /etc path: {required}")

for required in mutable_overlay_paths:
    if not os.path.lexists(required):
        raise SystemExit(f"missing live mutable seed path: {required}")

for disallowed in disallowed_seed_paths:
    if os.path.lexists(disallowed):
        raise SystemExit(f"unexpected live disallowed seed path present: {disallowed}")

for helper_path in repo_owned_paths:
    if not helper_path.startswith("/usr/sbin/slopos-"):
        continue
    if not os.access(helper_path, os.X_OK):
        raise SystemExit(f"live helper is not executable: {helper_path}")

for link_spec in compatibility_symlinks:
    link_path, expected_target = link_spec.split("->", 1)
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
for prefix in expected_empty_managed_prefixes:
    if not os.path.lexists(prefix):
        continue
    for dirpath, dirnames, filenames in os.walk(prefix):
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
        "unexpected managed /usr/local content in combined candidate boot: "
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
    raise SystemExit("unexpected live BusyBox symlinks in combined candidate boot: " + ", ".join(sorted(bad)))

print("guest combined artifact boot validation passed")
PY
EOF

GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
  KNOWN_HOSTS_FILE="$known_hosts_file" \
  "$ROOT_DIR/scripts/ssh-guest.sh" "$remote_check"

shutdown_vm "$known_hosts_file"
echo "Validated combined run-phase2 boot from $KERNEL_CANDIDATE_IMAGE and $ROOTFS_CANDIDATE_IMAGE"
