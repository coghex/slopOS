#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_HOST=""
LOCAL_IMAGE=""
LOCAL_MANIFEST=""
LOCAL_SYSTEM_MAP=""
LOCAL_KERNEL_CONFIG=""
LOCAL_MODULE_SYMVERS=""
HOST_CANDIDATE_ROOT="${HOST_GUEST_KERNEL_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-kernel-candidate}"

cleanup() {
  if [[ -n "$TMPDIR_HOST" && -d "$TMPDIR_HOST" ]]; then
    rm -rf "$TMPDIR_HOST"
  fi
}

trap cleanup EXIT
mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/promote-guest-kernel.XXXXXX")"
LOCAL_IMAGE="$TMPDIR_HOST/Image"
LOCAL_MANIFEST="$TMPDIR_HOST/manifest.toml"
LOCAL_SYSTEM_MAP="$TMPDIR_HOST/System.map"
LOCAL_KERNEL_CONFIG="$TMPDIR_HOST/linux.config"
LOCAL_MODULE_SYMVERS="$TMPDIR_HOST/Module.symvers"

artifact_root="$("$ROOT_DIR/scripts/ssh-guest.sh" 'readlink -f /Volumes/slopos-data/kernel/artifacts/current')"
if [[ -z "$artifact_root" ]]; then
  echo "No current guest kernel artifact found under /Volumes/slopos-data/kernel/artifacts/current" >&2
  exit 1
fi

artifact_name="$(basename "$artifact_root")"
"$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/Image" "$LOCAL_IMAGE"
"$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/manifest.toml" "$LOCAL_MANIFEST"
"$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/System.map" "$LOCAL_SYSTEM_MAP"
"$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/linux.config" "$LOCAL_KERNEL_CONFIG"
if "$ROOT_DIR/scripts/ssh-guest.sh" "test -f '$artifact_root/Module.symvers'"; then
  "$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/Module.symvers" "$LOCAL_MODULE_SYMVERS"
fi

if [[ ! -s "$LOCAL_IMAGE" ]]; then
  echo "Guest kernel artifact image is missing or empty: $artifact_root/Image" >&2
  exit 1
fi

host_artifact_dir="$HOST_CANDIDATE_ROOT/$artifact_name"
mkdir -p "$host_artifact_dir"
cp "$LOCAL_IMAGE" "$host_artifact_dir/Image.tmp"
mv "$host_artifact_dir/Image.tmp" "$host_artifact_dir/Image"
cp "$LOCAL_MANIFEST" "$host_artifact_dir/manifest.toml.tmp"
mv "$host_artifact_dir/manifest.toml.tmp" "$host_artifact_dir/manifest.toml"
cp "$LOCAL_SYSTEM_MAP" "$host_artifact_dir/System.map.tmp"
mv "$host_artifact_dir/System.map.tmp" "$host_artifact_dir/System.map"
cp "$LOCAL_KERNEL_CONFIG" "$host_artifact_dir/linux.config.tmp"
mv "$host_artifact_dir/linux.config.tmp" "$host_artifact_dir/linux.config"
if [[ -f "$LOCAL_MODULE_SYMVERS" ]]; then
  cp "$LOCAL_MODULE_SYMVERS" "$host_artifact_dir/Module.symvers.tmp"
  mv "$host_artifact_dir/Module.symvers.tmp" "$host_artifact_dir/Module.symvers"
fi
cat >"$host_artifact_dir/host-handoff.toml" <<EOF
source_guest_artifact = "$artifact_root"
validated_at = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
validated_by = "scripts/promote-guest-kernel-candidate.sh"
image_name = "Image"
EOF
ln -sfn "$artifact_name" "$HOST_CANDIDATE_ROOT/current"
echo "Promoted guest kernel candidate to $HOST_CANDIDATE_ROOT/current/Image"
