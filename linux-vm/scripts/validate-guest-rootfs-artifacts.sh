#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_HOST=""
LOCAL_IMAGE=""
LOCAL_MANIFEST=""
HOST_CANDIDATE_ROOT="${HOST_GUEST_ROOTFS_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-rootfs-candidate}"

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
print(hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

toml_value() {
  python3 - "$1" "$2" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
for line in path.read_text(encoding="utf-8").splitlines():
    stripped = line.strip()
    if stripped.startswith(f"{key} = "):
        value = stripped.split("=", 1)[1].strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        print(value)
        break
else:
    raise SystemExit(f"{key} not found in {path}")
PY
}

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

LOCAL_IMAGE_SHA="$(sha256_file "$LOCAL_IMAGE")"
LOCAL_MANIFEST_SHA="$(sha256_file "$LOCAL_MANIFEST")"
LOCAL_MANIFEST_SCHEMA="$(toml_value "$LOCAL_MANIFEST" schema_version)"
LOCAL_SEAL_METHOD="$(toml_value "$LOCAL_MANIFEST" seal_method)"
LOCAL_STAGED_SEAL_METHOD="$(toml_value "$LOCAL_MANIFEST" staged_seal_method)"

for required_line in \
  'source_post_fakeroot = "normal-post-fakeroot.sh"' \
  'staged_seal_method = ' \
  'normal_seed_tree_manifest = "normal-rootfs-tree.manifest"'; do
  if ! grep -Fq "$required_line" "$LOCAL_MANIFEST"; then
    echo "Guest rootfs manifest is missing expected provenance entry: $required_line" >&2
    exit 1
  fi
done

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
manifest_name = "manifest.toml"
image_sha256 = "$LOCAL_IMAGE_SHA"
manifest_sha256 = "$LOCAL_MANIFEST_SHA"
manifest_schema_version = $LOCAL_MANIFEST_SCHEMA
seal_method = "$LOCAL_SEAL_METHOD"
staged_seal_method = "$LOCAL_STAGED_SEAL_METHOD"
EOF
ln -sfn "$artifact_name" "$HOST_CANDIDATE_ROOT/current"
echo "Promoted validated guest rootfs candidate to $HOST_CANDIDATE_ROOT/current/rootfs.ext4"
