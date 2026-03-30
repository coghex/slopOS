#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
DEFCONFIG_PATH="${DEFCONFIG_PATH:-$ROOT_DIR/configs/slopos_aarch64_virt_defconfig}"
KERNEL_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-build-kernel-artifacts"
OVERRIDE_GUEST_SSH_FORWARD_PORT="${GUEST_SSH_FORWARD_PORT:-}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

if [[ ! -f "$DEFCONFIG_PATH" ]]; then
  echo "Missing defconfig: $DEFCONFIG_PATH" >&2
  exit 1
fi

kernel_version="$(
  sed -n 's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\(.*\)"/\1/p' "$DEFCONFIG_PATH"
)"
kernel_config_rel="$(
  sed -n 's/^BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="\(.*\)"/\1/p' "$DEFCONFIG_PATH"
)"
patch_dir_rel="$(
  sed -n 's/^BR2_GLOBAL_PATCH_DIR="\(.*\)"/\1/p' "$DEFCONFIG_PATH"
)"

if [[ -z "$kernel_version" || -z "$kernel_config_rel" || -z "$patch_dir_rel" ]]; then
  echo "Unable to resolve kernel inputs from $DEFCONFIG_PATH" >&2
  exit 1
fi

kernel_config_source="$ROOT_DIR/buildroot-src/$kernel_config_rel"
kernel_patch_source_dir="$ROOT_DIR/buildroot-src/$patch_dir_rel/linux"
kernel_archive_source="${KERNEL_SOURCE_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/linux/linux-$kernel_version.tar.xz}"

for path in "$kernel_config_source" "$kernel_archive_source"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing kernel input: $path" >&2
    exit 1
  fi
done

if [[ ! -d "$kernel_patch_source_dir" ]]; then
  echo "Missing kernel patch directory: $kernel_patch_source_dir" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ -n "$OVERRIDE_GUEST_SSH_FORWARD_PORT" ]]; then
  GUEST_SSH_FORWARD_PORT="$OVERRIDE_GUEST_SSH_FORWARD_PORT"
fi

KERNEL_STATE_ROOT="${KERNEL_STATE_ROOT:-$PERSISTENT_MOUNTPOINT/kernel}"
KERNEL_INPUT_ROOT="${KERNEL_INPUT_ROOT:-$KERNEL_STATE_ROOT/input/current}"
GUEST_KERNEL_HELPER_DEST="${GUEST_KERNEL_HELPER_DEST:-/tmp/slopos-build-kernel-artifacts}"
GUEST_KERNEL_ARCHIVE_PATH="${GUEST_KERNEL_ARCHIVE_PATH:-$KERNEL_INPUT_ROOT/$(basename "$kernel_archive_source")}"
GUEST_KERNEL_DEFCONFIG_PATH="${GUEST_KERNEL_DEFCONFIG_PATH:-$KERNEL_INPUT_ROOT/$(basename "$DEFCONFIG_PATH")}"
GUEST_KERNEL_CONFIG_PATH="${GUEST_KERNEL_CONFIG_PATH:-$KERNEL_INPUT_ROOT/$(basename "$kernel_config_source")}"
GUEST_KERNEL_PATCH_DIR="${GUEST_KERNEL_PATCH_DIR:-$KERNEL_INPUT_ROOT/patches/linux}"
BUILD_JOBS="${BUILD_JOBS:-}"

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$KERNEL_INPUT_ROOT' '$(dirname "$GUEST_KERNEL_PATCH_DIR")'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$KERNEL_HELPER_SOURCE" "$GUEST_KERNEL_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$DEFCONFIG_PATH" "$GUEST_KERNEL_DEFCONFIG_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$kernel_config_source" "$GUEST_KERNEL_CONFIG_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$kernel_archive_source" "$GUEST_KERNEL_ARCHIVE_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$kernel_patch_source_dir" "$(dirname "$GUEST_KERNEL_PATCH_DIR")/"

set -- "$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- \
  "$GUEST_KERNEL_HELPER_DEST" \
  "$KERNEL_STATE_ROOT" \
  "$KERNEL_INPUT_ROOT" \
  "$GUEST_KERNEL_ARCHIVE_PATH" \
  "$GUEST_KERNEL_DEFCONFIG_PATH" \
  "$GUEST_KERNEL_CONFIG_PATH" \
  "$GUEST_KERNEL_PATCH_DIR"

if [[ -n "$BUILD_JOBS" ]]; then
  set -- "$@" "$BUILD_JOBS"
fi

"$@" <<'EOF'
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

kernel_helper="$1"
shift
kernel_state_root="$1"
shift
kernel_input_root="$1"
shift
kernel_archive_path="$1"
shift
kernel_defconfig_path="$1"
shift
kernel_config_path="$1"
shift
kernel_patch_dir="$1"
shift
build_jobs="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi

chmod 0755 "$kernel_helper"

set -- \
  env \
  KERNEL_STATE_ROOT="$kernel_state_root" \
  KERNEL_INPUT_ROOT="$kernel_input_root" \
  KERNEL_SOURCE_ARCHIVE="$kernel_archive_path" \
  KERNEL_DEFCONFIG_PATH="$kernel_defconfig_path" \
  KERNEL_CONFIG_PATH="$kernel_config_path" \
  KERNEL_PATCH_DIR="$kernel_patch_dir" \
  "$kernel_helper"

if [ -n "$build_jobs" ]; then
  set -- "$@" --build-jobs "$build_jobs"
fi

"$@"
EOF
