#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
HOST_CANDIDATE_ROOT="${HOST_GUEST_ROOTFS_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-rootfs-candidate}"
CANDIDATE_IMAGE="${HOST_GUEST_ROOTFS_CANDIDATE_IMAGE:-$HOST_CANDIDATE_ROOT/current/rootfs.ext4}"
CANDIDATE_MANIFEST="${HOST_GUEST_ROOTFS_CANDIDATE_MANIFEST:-$HOST_CANDIDATE_ROOT/current/manifest.toml}"
CANDIDATE_HANDOFF="${HOST_GUEST_ROOTFS_CANDIDATE_HANDOFF:-$HOST_CANDIDATE_ROOT/current/host-handoff.toml}"
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

for var_name in CANDIDATE_IMAGE CANDIDATE_MANIFEST CANDIDATE_HANDOFF; do
  var_value="${!var_name}"
  if [[ "$var_value" != /* ]]; then
    printf -v "$var_name" '%s/%s' "$ROOT_DIR" "$var_value"
  fi
done

for required in "$CANDIDATE_IMAGE" "$CANDIDATE_MANIFEST" "$CANDIDATE_HANDOFF"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing host-side guest rootfs candidate input: $required" >&2
    echo "Run ./scripts/validate-guest-rootfs-artifacts.sh first." >&2
    exit 1
  fi
done

python3 - "$CANDIDATE_IMAGE" "$CANDIDATE_MANIFEST" "$CANDIDATE_HANDOFF" <<'PY'
import hashlib
import pathlib
import sys

image_path = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
handoff_path = pathlib.Path(sys.argv[3])

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

manifest = parse_toml(manifest_path)
handoff = parse_toml(handoff_path)

required_manifest = {
    "schema_version": "3",
    "source_post_fakeroot": "normal-post-fakeroot.sh",
    "staged_input_metadata": "rootfs-inputs.toml",
    "staged_input_root_manifest": "input-root.manifest",
    "normal_seed_tree_manifest": "normal-rootfs-tree.manifest",
    "mutable_overlay_manifest": "rootfs-overlay.manifest",
    "image_name": "rootfs.ext4",
}
for key, expected in required_manifest.items():
    if manifest.get(key) != expected:
        raise SystemExit(f"unexpected rootfs candidate manifest {key}: {manifest.get(key)!r} (expected {expected!r})")
if "staged_seal_method" not in manifest:
    raise SystemExit("rootfs candidate manifest is missing staged_seal_method")

image_sha = hashlib.sha256(image_path.read_bytes()).hexdigest()
manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
if handoff.get("image_name") != "rootfs.ext4":
    raise SystemExit(f"unexpected handoff image_name: {handoff.get('image_name')!r}")
if handoff.get("manifest_name") != "manifest.toml":
    raise SystemExit(f"unexpected handoff manifest_name: {handoff.get('manifest_name')!r}")
if handoff.get("image_sha256") != image_sha:
    raise SystemExit("rootfs candidate handoff image_sha256 does not match candidate image")
if handoff.get("manifest_sha256") != manifest_sha:
    raise SystemExit("rootfs candidate handoff manifest_sha256 does not match candidate manifest")
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
mutable_overlay_paths = $mutable_overlay_paths_literal
compatibility_symlinks = $compatibility_symlinks_literal
expected_empty_managed_prefixes = $expected_empty_managed_prefixes_literal
disallowed_seed_paths = $disallowed_seed_paths_literal
etc_repo_owned_prefixes = $etc_repo_owned_prefixes_literal
etc_buildroot_provided_paths = $etc_buildroot_provided_paths_literal

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
