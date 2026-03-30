#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_HOST=""
LOCAL_IMAGE=""
LOCAL_MANIFEST=""
HOST_CANDIDATE_ROOT="${HOST_GUEST_ROOTFS_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-rootfs-candidate}"

cleanup() {
  if [[ -n "$TMPDIR_HOST" && -d "$TMPDIR_HOST" ]]; then
    rm -rf "$TMPDIR_HOST"
  fi
}

trap cleanup EXIT
mkdir -p "$ROOT_DIR/qemu"
TMPDIR_HOST="$(mktemp -d "$ROOT_DIR/qemu/validate-guest-rootfs.XXXXXX")"
LOCAL_IMAGE="$TMPDIR_HOST/rootfs.ext4"
LOCAL_MANIFEST="$TMPDIR_HOST/manifest.toml"

artifact_root="$("$ROOT_DIR/scripts/ssh-guest.sh" 'readlink -f /Volumes/slopos-data/rootfs/artifacts/current')"
if [[ -z "$artifact_root" ]]; then
  echo "No current guest rootfs artifact found under /Volumes/slopos-data/rootfs/artifacts/current" >&2
  exit 1
fi

artifact_name="$(basename "$artifact_root")"
"$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/rootfs.ext4" "$LOCAL_IMAGE"
"$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/manifest.toml" "$LOCAL_MANIFEST"
NORMAL_ROOTFS_IMAGE="$LOCAL_IMAGE" "$ROOT_DIR/scripts/validate-busyboxless.sh"

host_artifact_dir="$HOST_CANDIDATE_ROOT/$artifact_name"
mkdir -p "$host_artifact_dir"
cp "$LOCAL_IMAGE" "$host_artifact_dir/rootfs.ext4.tmp"
mv "$host_artifact_dir/rootfs.ext4.tmp" "$host_artifact_dir/rootfs.ext4"
cp "$LOCAL_MANIFEST" "$host_artifact_dir/manifest.toml.tmp"
mv "$host_artifact_dir/manifest.toml.tmp" "$host_artifact_dir/manifest.toml"
cat >"$host_artifact_dir/host-handoff.toml" <<EOF
source_guest_artifact = "$artifact_root"
validated_at = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
validated_by = "scripts/validate-guest-rootfs-artifacts.sh"
image_name = "rootfs.ext4"
EOF
ln -sfn "$artifact_name" "$HOST_CANDIDATE_ROOT/current"
echo "Promoted validated guest rootfs candidate to $HOST_CANDIDATE_ROOT/current/rootfs.ext4"
