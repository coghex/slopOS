#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
NORMAL_OUTPUT_DIR="$ROOT_DIR/artifacts/buildroot-output"
ROOTFS_IMAGE="$NORMAL_OUTPUT_DIR/images/rootfs.ext4"
ROOTFS_EXT2_IMAGE="$NORMAL_OUTPUT_DIR/images/rootfs.ext2"
DEFCONFIG_PATH="${DEFCONFIG_PATH:-$ROOT_DIR/configs/slopos_aarch64_virt_defconfig}"
BOOTSTRAP_MANIFEST_PATH="${BOOTSTRAP_MANIFEST_PATH:-$ROOT_DIR/rootfs/bootstrap-manifest.toml}"
ROOTFS_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-build-rootfs-artifacts"
ROOTFS_POST_FAKEROOT_SOURCE="$ROOT_DIR/board/normal-post-fakeroot.sh"
NORMAL_SEED_TREE_SOURCE="$ROOT_DIR/board/normal-rootfs-tree"
ROOTFS_OVERLAY_SOURCE="$ROOT_DIR/board/rootfs-overlay"
PREPARE_GUEST_SSH_SCRIPT="$ROOT_DIR/scripts/prepare-guest-ssh.sh"
INSTANCE="${LIMA_INSTANCE:-slopos-builder}"
TMPDIR_HOST=""
ROOTFS_LABEL=""
ROOTFS_SIZE=""
OVERRIDE_GUEST_SSH_FORWARD_PORT="${GUEST_SSH_FORWARD_PORT:-}"
ALLOW_HOST_ROOTFS_SEAL_FALLBACK="${ALLOW_HOST_ROOTFS_SEAL_FALLBACK:-1}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

if [[ ! -f "$ROOTFS_IMAGE" && -f "$ROOTFS_EXT2_IMAGE" ]]; then
  ROOTFS_IMAGE="$ROOTFS_EXT2_IMAGE"
fi

for path in \
  "$ROOTFS_IMAGE" \
  "$DEFCONFIG_PATH" \
  "$BOOTSTRAP_MANIFEST_PATH" \
  "$ROOTFS_HELPER_SOURCE" \
  "$ROOTFS_POST_FAKEROOT_SOURCE" \
  "$PREPARE_GUEST_SSH_SCRIPT"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing required rootfs assembly input: $path" >&2
    exit 1
  fi
done

if [[ ! -d "$NORMAL_SEED_TREE_SOURCE" || ! -d "$ROOTFS_OVERLAY_SOURCE" ]]; then
  echo "Missing rootfs seed input tree" >&2
  exit 1
fi

ROOTFS_LABEL="$(sed -n 's/^BR2_TARGET_ROOTFS_EXT2_LABEL="\(.*\)"/\1/p' "$DEFCONFIG_PATH")"
ROOTFS_SIZE="$(sed -n 's/^BR2_TARGET_ROOTFS_EXT2_SIZE="\(.*\)"/\1/p' "$DEFCONFIG_PATH")"

if [[ -z "$ROOTFS_LABEL" || -z "$ROOTFS_SIZE" ]]; then
  echo "Unable to resolve rootfs label/size from $DEFCONFIG_PATH" >&2
  exit 1
fi

extract_rootfs_tree() {
  local image_path="$1"
  local output_dir="$2"
  local shell_cmd

  read -r -d '' shell_cmd <<EOF || true
set -euo pipefail
image=$(printf '%q' "$image_path")
output=$(printf '%q' "$output_dir")
rm -rf "\$output"
mkdir -p "\$output"
debugfs -R "rdump / \$output" "\$image" >/dev/null 2>&1
EOF

  if command -v debugfs >/dev/null 2>&1; then
    bash -lc "$shell_cmd"
    return 0
  fi

  if ! command -v limactl >/dev/null 2>&1; then
    echo "debugfs is unavailable locally and limactl is not installed." >&2
    exit 1
  fi

  if ! limactl list -q | grep -qx "$INSTANCE"; then
    echo "Lima instance $INSTANCE is required for rootfs extraction." >&2
    echo "Run ./scripts/build-phase2-lima.sh first." >&2
    exit 1
  fi

  limactl shell --start "$INSTANCE" bash -lc "$shell_cmd"
}

seal_rootfs_image() {
  local source_archive="$1"
  local image_path="$2"
  local shell_cmd

  read -r -d '' shell_cmd <<EOF || true
set -euo pipefail
source_archive=$(printf '%q' "$source_archive")
image=$(printf '%q' "$image_path")
stage_root="\$(mktemp -d /tmp/slopos-rootfs-seal.XXXXXX)"
tmp_image="\$(mktemp /tmp/slopos-rootfs-image.XXXXXX)"
cleanup() {
  sudo rm -rf "\$stage_root" "\$tmp_image"
}
trap cleanup EXIT
  sudo tar --same-owner -xf "\$source_archive" -C "\$stage_root"
sudo mke2fs -t ext4 -d "\$stage_root" -N 0 -m 5 -L $(printf '%q' "$ROOTFS_LABEL") -I 256 -O '^64bit' "\$tmp_image" $(printf '%q' "$ROOTFS_SIZE")
sudo chown "\$(id -u):\$(id -g)" "\$tmp_image"
mv "\$tmp_image" "\$image"
EOF

  if ! command -v limactl >/dev/null 2>&1; then
    echo "limactl is required for rootfs sealing." >&2
    exit 1
  fi

  if ! limactl list -q | grep -qx "$INSTANCE"; then
    echo "Lima instance $INSTANCE is required for rootfs sealing." >&2
    echo "Run ./scripts/build-phase2-lima.sh first." >&2
    exit 1
  fi

  limactl shell --start "$INSTANCE" bash -lc "$shell_cmd"
}

update_guest_manifest_for_host_seal() {
  local artifact_root="$1"
  local image_name="$2"
  local sealed_at="$3"

  "$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- "$artifact_root/manifest.toml" "$artifact_root/rootfs.ext4" "$image_name" "$sealed_at" <<'EOF'
set -euo pipefail
python3 - "$1" "$2" "$3" "$4" <<'PY'
import pathlib
import subprocess
import sys

manifest_path = pathlib.Path(sys.argv[1])
image_path = pathlib.Path(sys.argv[2])
image_name = sys.argv[3]
sealed_at = sys.argv[4]
image_file_output = subprocess.check_output(["file", str(image_path)], text=True).strip().replace('"', '\\"')

text = manifest_path.read_text(encoding="utf-8")
lines = text.splitlines()
updated = []
replaced = set()

replacements = {
    "seal_method": f'seal_method = "host-mke2fs-d"',
    "seal_required": "seal_required = false",
    "image_name": f'image_name = "{image_name}"',
    "image_file": f'image_file = "{image_file_output}"',
}

for line in lines:
    stripped = line.strip()
    key = stripped.split("=", 1)[0].strip() if "=" in stripped else None
    if key in replacements:
        updated.append(replacements[key])
        replaced.add(key)
        continue
    updated.append(line)

for key in ("seal_method", "seal_required", "image_name", "image_file"):
    if key not in replaced:
        updated.append(replacements[key])

if not any(line.startswith("host_seal_fallback = ") for line in updated):
    updated.append("host_seal_fallback = true")
if not any(line.startswith("host_seal_fallback_method = ") for line in updated):
    updated.append('host_seal_fallback_method = "host-mke2fs-d"')
if not any(line.startswith("host_seal_fallback_by = ") for line in updated):
    updated.append('host_seal_fallback_by = "scripts/build-guest-rootfs-artifacts.sh"')
if not any(line.startswith("host_seal_fallback_at = ") for line in updated):
    updated.append(f'host_seal_fallback_at = "{sealed_at}"')

manifest_path.write_text("\n".join(updated) + "\n", encoding="utf-8")
PY
EOF
}

cleanup() {
  if [[ -n "$TMPDIR_HOST" && -d "$TMPDIR_HOST" ]]; then
    rm -rf "$TMPDIR_HOST"
  fi
}

trap cleanup EXIT

describe_source_path() {
  local path="$1"

  if [[ "$path" == "$ROOT_DIR/"* ]]; then
    printf '%s\n' "${path#$ROOT_DIR/}"
    return 0
  fi

  printf '%s\n' "$path"
}

stage_mutable_overlay() {
  local source_dir="$1"
  local manifest_path="$2"
  local dest_dir="$3"

  python3 - "$source_dir" "$manifest_path" "$dest_dir" <<'PY'
import os
import pathlib
import shutil
import sys
import tomllib

source_dir = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
dest_dir = pathlib.Path(sys.argv[3])

with manifest_path.open("rb") as fh:
    manifest = tomllib.load(fh)

mutable_paths = manifest["normal_seed_tree"]["mutable_overlay_paths"]
expected = {path.lstrip("/") for path in mutable_paths}
dest_dir.mkdir(parents=True, exist_ok=True)

actual = set()
for path in sorted(source_dir.rglob("*")):
    if path.is_dir():
        continue
    actual.add(path.relative_to(source_dir).as_posix())

unexpected = sorted(actual - expected)
if unexpected:
    raise SystemExit(
        "unexpected files under mutable rootfs overlay: "
        + ", ".join(unexpected)
    )

for rel in sorted(expected):
    source_path = source_dir / rel
    if not source_path.exists() and not source_path.is_symlink():
        continue
    dest_path = dest_dir / rel
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    if source_path.is_symlink():
        if dest_path.exists() or dest_path.is_symlink():
            dest_path.unlink()
        os.symlink(os.readlink(source_path), dest_path)
    else:
        shutil.copy2(source_path, dest_path)
PY
}
mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/guest-rootfs-build.XXXXXX")"
EXTRACTED_ROOTFS_DIR="$TMPDIR_HOST/base-rootfs"
BASE_ROOTFS_ARCHIVE="$TMPDIR_HOST/base-rootfs.tar"
ASSEMBLED_ROOTFS_ARCHIVE="$TMPDIR_HOST/rootfs-tree.tar"
SEALED_ROOTFS_IMAGE="$TMPDIR_HOST/rootfs.ext4"
STAGED_ROOTFS_OVERLAY_SOURCE="$TMPDIR_HOST/rootfs-overlay"

"$PREPARE_GUEST_SSH_SCRIPT"

extract_rootfs_tree "$ROOTFS_IMAGE" "$EXTRACTED_ROOTFS_DIR"
tar -C "$EXTRACTED_ROOTFS_DIR" -cf "$BASE_ROOTFS_ARCHIVE" .
stage_mutable_overlay "$ROOTFS_OVERLAY_SOURCE" "$BOOTSTRAP_MANIFEST_PATH" "$STAGED_ROOTFS_OVERLAY_SOURCE"

# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ -n "$OVERRIDE_GUEST_SSH_FORWARD_PORT" ]]; then
  GUEST_SSH_FORWARD_PORT="$OVERRIDE_GUEST_SSH_FORWARD_PORT"
fi

ROOTFS_STATE_ROOT="${ROOTFS_STATE_ROOT:-$PERSISTENT_MOUNTPOINT/rootfs}"
ROOTFS_INPUT_BASE="${ROOTFS_INPUT_BASE:-$ROOTFS_STATE_ROOT/input}"
ROOTFS_INPUT_BUNDLE_ID="${ROOTFS_INPUT_BUNDLE_ID:-rootfs-inputs-$(date -u '+%Y%m%dT%H%M%SZ')}"
ROOTFS_INPUT_ROOT="${ROOTFS_INPUT_ROOT:-$ROOTFS_INPUT_BASE/$ROOTFS_INPUT_BUNDLE_ID}"
ROOTFS_INPUT_CURRENT_LINK="${ROOTFS_INPUT_CURRENT_LINK:-$ROOTFS_INPUT_BASE/current}"
GUEST_ROOTFS_HELPER_DEST="${GUEST_ROOTFS_HELPER_DEST:-/tmp/slopos-build-rootfs-artifacts}"
GUEST_BASE_ARCHIVE_PATH="${GUEST_BASE_ARCHIVE_PATH:-$ROOTFS_INPUT_ROOT/$(basename "$BASE_ROOTFS_ARCHIVE")}"
GUEST_DEFCONFIG_PATH="${GUEST_DEFCONFIG_PATH:-$ROOTFS_INPUT_ROOT/$(basename "$DEFCONFIG_PATH")}"
GUEST_BOOTSTRAP_MANIFEST_PATH="${GUEST_BOOTSTRAP_MANIFEST_PATH:-$ROOTFS_INPUT_ROOT/$(basename "$BOOTSTRAP_MANIFEST_PATH")}"
GUEST_POST_FAKEROOT_PATH="${GUEST_POST_FAKEROOT_PATH:-$ROOTFS_INPUT_ROOT/normal-post-fakeroot.sh}"
GUEST_NORMAL_SEED_TREE="${GUEST_NORMAL_SEED_TREE:-$ROOTFS_INPUT_ROOT/normal-rootfs-tree}"
GUEST_ROOTFS_OVERLAY="${GUEST_ROOTFS_OVERLAY:-$ROOTFS_INPUT_ROOT/rootfs-overlay}"
GUEST_ROOTFS_INPUT_METADATA_PATH="${GUEST_ROOTFS_INPUT_METADATA_PATH:-$ROOTFS_INPUT_ROOT/rootfs-inputs.toml}"

base_rootfs_source_desc="$(describe_source_path "$ROOTFS_IMAGE")"
defconfig_source_desc="$(describe_source_path "$DEFCONFIG_PATH")"
bootstrap_manifest_source_desc="$(describe_source_path "$BOOTSTRAP_MANIFEST_PATH")"
post_fakeroot_source_desc="$(describe_source_path "$ROOTFS_POST_FAKEROOT_SOURCE")"
normal_seed_tree_source_desc="$(describe_source_path "$NORMAL_SEED_TREE_SOURCE")"
rootfs_overlay_source_desc="$(describe_source_path "$ROOTFS_OVERLAY_SOURCE")"
local_rootfs_input_metadata="$TMPDIR_HOST/rootfs-inputs.toml"

cat >"$local_rootfs_input_metadata" <<EOF
schema_version = 1
input_bundle_id = "$ROOTFS_INPUT_BUNDLE_ID"
input_root = "$ROOTFS_INPUT_ROOT"
staged_at = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
staged_by = "scripts/build-guest-rootfs-artifacts.sh"
source_base_rootfs_image = "$base_rootfs_source_desc"
source_defconfig_path = "$defconfig_source_desc"
source_bootstrap_manifest_path = "$bootstrap_manifest_source_desc"
source_post_fakeroot_path = "$post_fakeroot_source_desc"
source_normal_seed_tree_path = "$normal_seed_tree_source_desc"
source_rootfs_overlay_path = "$rootfs_overlay_source_desc"
staged_base_archive = "$(basename "$GUEST_BASE_ARCHIVE_PATH")"
staged_defconfig = "$(basename "$GUEST_DEFCONFIG_PATH")"
staged_bootstrap_manifest = "$(basename "$GUEST_BOOTSTRAP_MANIFEST_PATH")"
staged_post_fakeroot = "$(basename "$GUEST_POST_FAKEROOT_PATH")"
staged_normal_seed_tree = "$(basename "$GUEST_NORMAL_SEED_TREE")"
staged_rootfs_overlay = "$(basename "$GUEST_ROOTFS_OVERLAY")"
EOF

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$ROOTFS_INPUT_ROOT'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$ROOTFS_HELPER_SOURCE" "$GUEST_ROOTFS_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$BASE_ROOTFS_ARCHIVE" "$GUEST_BASE_ARCHIVE_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$DEFCONFIG_PATH" "$GUEST_DEFCONFIG_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$BOOTSTRAP_MANIFEST_PATH" "$GUEST_BOOTSTRAP_MANIFEST_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$ROOTFS_POST_FAKEROOT_SOURCE" "$GUEST_POST_FAKEROOT_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$local_rootfs_input_metadata" "$GUEST_ROOTFS_INPUT_METADATA_PATH"
"$ROOT_DIR/scripts/ssh-guest.sh" "rm -rf '$GUEST_NORMAL_SEED_TREE' '$GUEST_ROOTFS_OVERLAY'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$NORMAL_SEED_TREE_SOURCE" "$ROOTFS_INPUT_ROOT/"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$STAGED_ROOTFS_OVERLAY_SOURCE" "$ROOTFS_INPUT_ROOT/"
"$ROOT_DIR/scripts/ssh-guest.sh" "rm -rf '$ROOTFS_INPUT_CURRENT_LINK' && ln -s '$ROOTFS_INPUT_ROOT' '$ROOTFS_INPUT_CURRENT_LINK'"

"$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- \
  "$GUEST_ROOTFS_HELPER_DEST" \
  "$ROOTFS_STATE_ROOT" \
  "$ROOTFS_INPUT_ROOT" \
  "$GUEST_BASE_ARCHIVE_PATH" \
  "$GUEST_POST_FAKEROOT_PATH" \
  "$GUEST_DEFCONFIG_PATH" \
  "$GUEST_BOOTSTRAP_MANIFEST_PATH" \
  "$GUEST_ROOTFS_INPUT_METADATA_PATH" <<'EOF'
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

rootfs_helper="$1"
shift
rootfs_state_root="$1"
shift
rootfs_input_root="$1"
shift
base_archive_path="$1"
shift
post_fakeroot_path="$1"
shift
defconfig_path="$1"
shift
bootstrap_manifest_path="$1"
shift
rootfs_input_metadata_path="$1"
shift

chmod 0755 "$rootfs_helper" "$post_fakeroot_path"

env \
  ROOTFS_STATE_ROOT="$rootfs_state_root" \
  ROOTFS_INPUT_ROOT="$rootfs_input_root" \
  BASE_ROOTFS_ARCHIVE="$base_archive_path" \
  ROOTFS_POST_FAKEROOT_SCRIPT="$post_fakeroot_path" \
  DEFCONFIG_PATH="$defconfig_path" \
  BOOTSTRAP_MANIFEST_PATH="$bootstrap_manifest_path" \
  ROOTFS_INPUT_METADATA_PATH="$rootfs_input_metadata_path" \
  "$rootfs_helper"
EOF

artifact_root="$("$ROOT_DIR/scripts/ssh-guest.sh" "readlink -f '$ROOTFS_STATE_ROOT/artifacts/current'")"
if [[ -z "$artifact_root" ]]; then
  echo "Unable to resolve current guest rootfs artifact under $ROOTFS_STATE_ROOT/artifacts/current" >&2
  exit 1
fi

if ! "$ROOT_DIR/scripts/ssh-guest.sh" "test -s '$artifact_root/rootfs.ext4'"; then
  if [[ "$ALLOW_HOST_ROOTFS_SEAL_FALLBACK" != "1" ]]; then
    echo "Guest rootfs artifact did not include rootfs.ext4 and host fallback is disabled." >&2
    echo "Re-run with ALLOW_HOST_ROOTFS_SEAL_FALLBACK=1 only if you intentionally want the compatibility fallback." >&2
    exit 1
  fi

  "$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/rootfs-tree.tar" "$ASSEMBLED_ROOTFS_ARCHIVE"
  seal_rootfs_image "$ASSEMBLED_ROOTFS_ARCHIVE" "$SEALED_ROOTFS_IMAGE"
  "$ROOT_DIR/scripts/scp-to-guest.sh" "$SEALED_ROOTFS_IMAGE" "$artifact_root/rootfs.ext4"
  update_guest_manifest_for_host_seal \
    "$artifact_root" \
    "rootfs.ext4" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Used host mke2fs -d compatibility fallback to seal guest rootfs artifact."
fi
