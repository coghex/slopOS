#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
AUDIT_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-audit-ext4-sealing-prereqs"
GUEST_AUDIT_HELPER_DEST="${GUEST_AUDIT_HELPER_DEST:-/tmp/slopos-audit-ext4-sealing-prereqs}"
HOST_AUDIT_ROOT="${HOST_GUEST_EXT4_AUDIT_ROOT:-$ROOT_DIR/artifacts/guest-ext4-sealing-audit}"
OVERRIDE_GUEST_SSH_FORWARD_PORT="${GUEST_SSH_FORWARD_PORT:-}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

if [[ ! -f "$AUDIT_HELPER_SOURCE" ]]; then
  echo "Missing audit helper: $AUDIT_HELPER_SOURCE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ -n "$OVERRIDE_GUEST_SSH_FORWARD_PORT" ]]; then
  GUEST_SSH_FORWARD_PORT="$OVERRIDE_GUEST_SSH_FORWARD_PORT"
fi
ROOTFS_STATE_ROOT="${ROOTFS_STATE_ROOT:-$PERSISTENT_MOUNTPOINT/rootfs}"

"$ROOT_DIR/scripts/scp-to-guest.sh" "$AUDIT_HELPER_SOURCE" "$GUEST_AUDIT_HELPER_DEST"

audit_output="$("$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- \
  "$GUEST_AUDIT_HELPER_DEST" \
  "$ROOTFS_STATE_ROOT" <<'EOF'
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

audit_helper="$1"
shift
rootfs_state_root="$1"
shift

chmod 0755 "$audit_helper"
env ROOTFS_STATE_ROOT="$rootfs_state_root" "$audit_helper"
EOF
)"

printf '%s\n' "$audit_output"

report_path="$(printf '%s\n' "$audit_output" | awk -F': ' '/^report_path:/ {print $2; exit}')"
if [[ -z "$report_path" ]]; then
  echo "Unable to resolve guest audit report path from helper output." >&2
  exit 1
fi

artifact_name="$(basename "$(dirname "$report_path")")"
host_artifact_dir="$HOST_AUDIT_ROOT/$artifact_name"
mkdir -p "$host_artifact_dir"
"$ROOT_DIR/scripts/scp-from-guest.sh" "$report_path" "$host_artifact_dir/report.txt"

kernel_loop_setting="absent"
if grep -q '^CONFIG_BLK_DEV_LOOP=' "$ROOT_DIR/buildroot-src/board/qemu/aarch64-virt/linux.config"; then
  kernel_loop_setting="$(sed -n 's/^CONFIG_BLK_DEV_LOOP=//p' "$ROOT_DIR/buildroot-src/board/qemu/aarch64-virt/linux.config")"
elif grep -q '^# CONFIG_BLK_DEV_LOOP is not set' "$ROOT_DIR/buildroot-src/board/qemu/aarch64-virt/linux.config"; then
  kernel_loop_setting="n"
fi

kernel_ext4_setting="absent"
if grep -q '^CONFIG_EXT4_FS=' "$ROOT_DIR/buildroot-src/board/qemu/aarch64-virt/linux.config"; then
  kernel_ext4_setting="$(sed -n 's/^CONFIG_EXT4_FS=//p' "$ROOT_DIR/buildroot-src/board/qemu/aarch64-virt/linux.config")"
elif grep -q '^# CONFIG_EXT4_FS is not set' "$ROOT_DIR/buildroot-src/board/qemu/aarch64-virt/linux.config"; then
  kernel_ext4_setting="n"
fi

defconfig_e2fsprogs="absent"
if grep -q '^BR2_PACKAGE_E2FSPROGS=y' "$ROOT_DIR/configs/slopos_aarch64_virt_defconfig"; then
  defconfig_e2fsprogs="y"
fi

cat >"$host_artifact_dir/host-context.txt" <<EOF
checked_in_kernel_config_blk_dev_loop: $kernel_loop_setting
checked_in_kernel_config_ext4_fs: $kernel_ext4_setting
checked_in_defconfig_package_e2fsprogs: $defconfig_e2fsprogs
guest_report_path: $report_path
EOF

ln -sfn "$artifact_name" "$HOST_AUDIT_ROOT/current"
echo "Host audit copy: $HOST_AUDIT_ROOT/current/report.txt"
echo "Host audit context: $HOST_AUDIT_ROOT/current/host-context.txt"
