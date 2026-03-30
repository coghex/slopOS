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

cleanup() {
  if [[ -n "$TMPDIR_HOST" && -d "$TMPDIR_HOST" ]]; then
    rm -rf "$TMPDIR_HOST"
  fi
}

trap cleanup EXIT
mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/guest-rootfs-build.XXXXXX")"
EXTRACTED_ROOTFS_DIR="$TMPDIR_HOST/base-rootfs"
BASE_ROOTFS_ARCHIVE="$TMPDIR_HOST/base-rootfs.tar"
ASSEMBLED_ROOTFS_ARCHIVE="$TMPDIR_HOST/rootfs-tree.tar"
SEALED_ROOTFS_IMAGE="$TMPDIR_HOST/rootfs.ext4"

"$PREPARE_GUEST_SSH_SCRIPT"

extract_rootfs_tree "$ROOTFS_IMAGE" "$EXTRACTED_ROOTFS_DIR"
tar -C "$EXTRACTED_ROOTFS_DIR" -cf "$BASE_ROOTFS_ARCHIVE" .

# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ -n "$OVERRIDE_GUEST_SSH_FORWARD_PORT" ]]; then
  GUEST_SSH_FORWARD_PORT="$OVERRIDE_GUEST_SSH_FORWARD_PORT"
fi

ROOTFS_STATE_ROOT="${ROOTFS_STATE_ROOT:-$PERSISTENT_MOUNTPOINT/rootfs}"
ROOTFS_INPUT_ROOT="${ROOTFS_INPUT_ROOT:-$ROOTFS_STATE_ROOT/input/current}"
GUEST_ROOTFS_HELPER_DEST="${GUEST_ROOTFS_HELPER_DEST:-/tmp/slopos-build-rootfs-artifacts}"
GUEST_BASE_ARCHIVE_PATH="${GUEST_BASE_ARCHIVE_PATH:-$ROOTFS_INPUT_ROOT/$(basename "$BASE_ROOTFS_ARCHIVE")}"
GUEST_DEFCONFIG_PATH="${GUEST_DEFCONFIG_PATH:-$ROOTFS_INPUT_ROOT/$(basename "$DEFCONFIG_PATH")}"
GUEST_BOOTSTRAP_MANIFEST_PATH="${GUEST_BOOTSTRAP_MANIFEST_PATH:-$ROOTFS_INPUT_ROOT/$(basename "$BOOTSTRAP_MANIFEST_PATH")}"
GUEST_POST_FAKEROOT_PATH="${GUEST_POST_FAKEROOT_PATH:-$ROOTFS_INPUT_ROOT/normal-post-fakeroot.sh}"
GUEST_NORMAL_SEED_TREE="${GUEST_NORMAL_SEED_TREE:-$ROOTFS_INPUT_ROOT/normal-rootfs-tree}"
GUEST_ROOTFS_OVERLAY="${GUEST_ROOTFS_OVERLAY:-$ROOTFS_INPUT_ROOT/rootfs-overlay}"

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$ROOTFS_INPUT_ROOT'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$ROOTFS_HELPER_SOURCE" "$GUEST_ROOTFS_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$BASE_ROOTFS_ARCHIVE" "$GUEST_BASE_ARCHIVE_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$DEFCONFIG_PATH" "$GUEST_DEFCONFIG_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$BOOTSTRAP_MANIFEST_PATH" "$GUEST_BOOTSTRAP_MANIFEST_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$ROOTFS_POST_FAKEROOT_SOURCE" "$GUEST_POST_FAKEROOT_PATH"
"$ROOT_DIR/scripts/ssh-guest.sh" "rm -rf '$GUEST_NORMAL_SEED_TREE' '$GUEST_ROOTFS_OVERLAY'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$NORMAL_SEED_TREE_SOURCE" "$ROOTFS_INPUT_ROOT/"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$ROOTFS_OVERLAY_SOURCE" "$ROOTFS_INPUT_ROOT/"

"$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- \
  "$GUEST_ROOTFS_HELPER_DEST" \
  "$ROOTFS_STATE_ROOT" \
  "$ROOTFS_INPUT_ROOT" \
  "$GUEST_BASE_ARCHIVE_PATH" \
  "$GUEST_POST_FAKEROOT_PATH" \
  "$GUEST_DEFCONFIG_PATH" \
  "$GUEST_BOOTSTRAP_MANIFEST_PATH" <<'EOF'
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

chmod 0755 "$rootfs_helper" "$post_fakeroot_path"

env \
  ROOTFS_STATE_ROOT="$rootfs_state_root" \
  ROOTFS_INPUT_ROOT="$rootfs_input_root" \
  BASE_ROOTFS_ARCHIVE="$base_archive_path" \
  ROOTFS_POST_FAKEROOT_SCRIPT="$post_fakeroot_path" \
  DEFCONFIG_PATH="$defconfig_path" \
  BOOTSTRAP_MANIFEST_PATH="$bootstrap_manifest_path" \
  "$rootfs_helper"
EOF

artifact_root="$("$ROOT_DIR/scripts/ssh-guest.sh" "readlink -f '$ROOTFS_STATE_ROOT/artifacts/current'")"
if [[ -z "$artifact_root" ]]; then
  echo "Unable to resolve current guest rootfs artifact under $ROOTFS_STATE_ROOT/artifacts/current" >&2
  exit 1
fi

if ! "$ROOT_DIR/scripts/ssh-guest.sh" "test -s '$artifact_root/rootfs.ext4'"; then
  "$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/rootfs-tree.tar" "$ASSEMBLED_ROOTFS_ARCHIVE"
  seal_rootfs_image "$ASSEMBLED_ROOTFS_ARCHIVE" "$SEALED_ROOTFS_IMAGE"
  "$ROOT_DIR/scripts/scp-to-guest.sh" "$SEALED_ROOTFS_IMAGE" "$artifact_root/rootfs.ext4"
fi

"$ROOT_DIR/scripts/ssh-guest.sh" "if ! grep -q '^seal_method = ' '$artifact_root/manifest.toml'; then image_file_output=\$(file '$artifact_root/rootfs.ext4' | sed 's/\"/\\\\\"/g'); { printf 'seal_method = \"host-mke2fs-d\"\\n'; printf 'image_file = \"%s\"\\n' \"\$image_file_output\"; printf 'image_name = \"rootfs.ext4\"\\n'; printf 'seal_required = false\\n'; } >> '$artifact_root/manifest.toml'; fi"
