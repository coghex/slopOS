#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
DEFCONFIG_PATH="${DEFCONFIG_PATH:-$ROOT_DIR/configs/slopos_aarch64_virt_defconfig}"
KERNEL_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-build-kernel-artifacts"
OVERRIDE_GUEST_SSH_FORWARD_PORT="${GUEST_SSH_FORWARD_PORT:-}"
TMPDIR_HOST=""

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

# Guest-native kernel builds are long and can go quiet enough to trip the
# fail-fast SSH wrapper on the default 2-vCPU VM, so prefer a safer profile
# unless the caller intentionally overrides it.
: "${GUEST_SSH_CONNECT_TIMEOUT_SECONDS:=60}"
: "${GUEST_SSH_SERVER_ALIVE_INTERVAL_SECONDS:=30}"
: "${GUEST_SSH_SERVER_ALIVE_COUNT_MAX:=40}"

mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/build-guest-kernel-inputs.XXXXXX")"

KERNEL_STATE_ROOT="${KERNEL_STATE_ROOT:-$PERSISTENT_MOUNTPOINT/kernel}"
KERNEL_INPUT_BASE="${KERNEL_INPUT_BASE:-$KERNEL_STATE_ROOT/input}"
KERNEL_INPUT_BUNDLE_ID="${KERNEL_INPUT_BUNDLE_ID:-kernel-inputs-$kernel_version-$(date -u '+%Y%m%dT%H%M%SZ')}"
KERNEL_INPUT_ROOT="${KERNEL_INPUT_ROOT:-$KERNEL_INPUT_BASE/$KERNEL_INPUT_BUNDLE_ID}"
KERNEL_INPUT_CURRENT_LINK="${KERNEL_INPUT_CURRENT_LINK:-$KERNEL_INPUT_BASE/current}"
GUEST_KERNEL_HELPER_DEST="${GUEST_KERNEL_HELPER_DEST:-/tmp/slopos-build-kernel-artifacts}"
GUEST_KERNEL_ARCHIVE_PATH="${GUEST_KERNEL_ARCHIVE_PATH:-$KERNEL_INPUT_ROOT/$(basename "$kernel_archive_source")}"
GUEST_KERNEL_DEFCONFIG_PATH="${GUEST_KERNEL_DEFCONFIG_PATH:-$KERNEL_INPUT_ROOT/$(basename "$DEFCONFIG_PATH")}"
GUEST_KERNEL_CONFIG_PATH="${GUEST_KERNEL_CONFIG_PATH:-$KERNEL_INPUT_ROOT/$(basename "$kernel_config_source")}"
GUEST_KERNEL_PATCH_DIR="${GUEST_KERNEL_PATCH_DIR:-$KERNEL_INPUT_ROOT/patches/linux}"
GUEST_KERNEL_INPUT_METADATA_PATH="${GUEST_KERNEL_INPUT_METADATA_PATH:-$KERNEL_INPUT_ROOT/kernel-inputs.toml}"
BUILD_JOBS="${BUILD_JOBS:-1}"

defconfig_source_desc="$(describe_source_path "$DEFCONFIG_PATH")"
kernel_config_source_desc="$(describe_source_path "$kernel_config_source")"
kernel_patch_source_desc="$(describe_source_path "$kernel_patch_source_dir")"
kernel_archive_source_desc="$(describe_source_path "$kernel_archive_source")"
local_kernel_input_metadata="$TMPDIR_HOST/kernel-inputs.toml"

cat >"$local_kernel_input_metadata" <<EOF
schema_version = 1
input_bundle_id = "$KERNEL_INPUT_BUNDLE_ID"
input_root = "$KERNEL_INPUT_ROOT"
staged_at = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
staged_by = "scripts/build-guest-kernel-artifacts.sh"
kernel_version = "$kernel_version"
source_defconfig_path = "$defconfig_source_desc"
source_kernel_config_path = "$kernel_config_source_desc"
source_patch_dir_path = "$kernel_patch_source_desc"
source_archive_path = "$kernel_archive_source_desc"
staged_defconfig = "$(basename "$GUEST_KERNEL_DEFCONFIG_PATH")"
staged_kernel_config = "$(basename "$GUEST_KERNEL_CONFIG_PATH")"
staged_patch_dir = "$(basename "$GUEST_KERNEL_PATCH_DIR")"
staged_source_archive = "$(basename "$GUEST_KERNEL_ARCHIVE_PATH")"
EOF

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$KERNEL_INPUT_ROOT' '$(dirname "$GUEST_KERNEL_PATCH_DIR")'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$KERNEL_HELPER_SOURCE" "$GUEST_KERNEL_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$DEFCONFIG_PATH" "$GUEST_KERNEL_DEFCONFIG_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$kernel_config_source" "$GUEST_KERNEL_CONFIG_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$kernel_archive_source" "$GUEST_KERNEL_ARCHIVE_PATH"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$kernel_patch_source_dir" "$(dirname "$GUEST_KERNEL_PATCH_DIR")/"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$local_kernel_input_metadata" "$GUEST_KERNEL_INPUT_METADATA_PATH"
"$ROOT_DIR/scripts/ssh-guest.sh" "rm -rf '$KERNEL_INPUT_CURRENT_LINK' && ln -s '$KERNEL_INPUT_ROOT' '$KERNEL_INPUT_CURRENT_LINK'"

set -- "$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- \
  "$GUEST_KERNEL_HELPER_DEST" \
  "$KERNEL_STATE_ROOT" \
  "$KERNEL_INPUT_ROOT" \
  "$GUEST_KERNEL_ARCHIVE_PATH" \
  "$GUEST_KERNEL_DEFCONFIG_PATH" \
  "$GUEST_KERNEL_CONFIG_PATH" \
  "$GUEST_KERNEL_PATCH_DIR" \
  "$GUEST_KERNEL_INPUT_METADATA_PATH"

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
kernel_input_metadata_path="$1"
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
  KERNEL_INPUT_METADATA_PATH="$kernel_input_metadata_path" \
  "$kernel_helper"

if [ -n "$build_jobs" ]; then
  set -- "$@" --build-jobs "$build_jobs"
fi

"$@"
EOF
