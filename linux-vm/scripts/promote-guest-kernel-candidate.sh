#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_HOST=""
LOCAL_IMAGE=""
LOCAL_MANIFEST=""
LOCAL_SYSTEM_MAP=""
LOCAL_KERNEL_CONFIG=""
LOCAL_MODULES_ARCHIVE=""
LOCAL_MODULE_SYMVERS=""
HOST_CANDIDATE_ROOT="${HOST_GUEST_KERNEL_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-kernel-candidate}"

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

toml_has_key() {
  python3 - "$1" "$2" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
for line in path.read_text(encoding="utf-8").splitlines():
    stripped = line.strip()
    if stripped.startswith(f"{key} = "):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

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
LOCAL_MODULES_ARCHIVE="$TMPDIR_HOST/modules.tar.xz"
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
"$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/modules.tar.xz" "$LOCAL_MODULES_ARCHIVE"
if "$ROOT_DIR/scripts/ssh-guest.sh" "test -f '$artifact_root/Module.symvers'"; then
  "$ROOT_DIR/scripts/scp-from-guest.sh" "$artifact_root/Module.symvers" "$LOCAL_MODULE_SYMVERS"
fi

if [[ ! -s "$LOCAL_IMAGE" ]]; then
  echo "Guest kernel artifact image is missing or empty: $artifact_root/Image" >&2
  exit 1
fi

LOCAL_IMAGE_SHA="$(sha256_file "$LOCAL_IMAGE")"
LOCAL_MANIFEST_SHA="$(sha256_file "$LOCAL_MANIFEST")"
LOCAL_MANIFEST_SCHEMA="$(toml_value "$LOCAL_MANIFEST" schema_version)"
LOCAL_KERNEL_RELEASE="$(toml_value "$LOCAL_MANIFEST" kernel_release)"
LOCAL_IMAGE_NAME="$(toml_value "$LOCAL_MANIFEST" image_name)"
LOCAL_MODULES_ARCHIVE_NAME="$(toml_value "$LOCAL_MANIFEST" modules_archive_name)"
LOCAL_SYSTEM_MAP_NAME="$(toml_value "$LOCAL_MANIFEST" system_map_name)"
LOCAL_RESOLVED_CONFIG_NAME="$(toml_value "$LOCAL_MANIFEST" resolved_config_name)"
LOCAL_MANIFEST_IMAGE_SHA="$(toml_value "$LOCAL_MANIFEST" image_sha256)"
LOCAL_MANIFEST_MODULES_ARCHIVE_SHA="$(toml_value "$LOCAL_MANIFEST" modules_archive_sha256)"
LOCAL_MANIFEST_SYSTEM_MAP_SHA="$(toml_value "$LOCAL_MANIFEST" system_map_sha256)"
LOCAL_MANIFEST_RESOLVED_CONFIG_SHA="$(toml_value "$LOCAL_MANIFEST" resolved_config_sha256)"
LOCAL_MODULES_ARCHIVE_SHA="$(sha256_file "$LOCAL_MODULES_ARCHIVE")"
LOCAL_SYSTEM_MAP_SHA="$(sha256_file "$LOCAL_SYSTEM_MAP")"
LOCAL_RESOLVED_CONFIG_SHA="$(sha256_file "$LOCAL_KERNEL_CONFIG")"

if [[ "$LOCAL_MANIFEST_SCHEMA" != "3" ]]; then
  echo "Guest kernel manifest schema_version is not 3: $LOCAL_MANIFEST" >&2
  exit 1
fi

for required_line in \
  'staged_input_metadata = ' \
  'staged_input_root_manifest = ' \
  'staged_patch_manifest = ' \
  'modules_archive_name = ' \
  'modules_archive_sha256 = ' \
  'input_root = '; do
  if ! grep -Fq "$required_line" "$LOCAL_MANIFEST"; then
    echo "Guest kernel manifest is missing expected provenance entry: $required_line" >&2
    exit 1
  fi
done

if [[ "$LOCAL_IMAGE_NAME" != "Image" ]]; then
  echo "Unexpected guest kernel manifest image_name: $LOCAL_IMAGE_NAME" >&2
  exit 1
fi

if [[ "$LOCAL_MODULES_ARCHIVE_NAME" != "modules.tar.xz" ]]; then
  echo "Unexpected guest kernel manifest modules_archive_name: $LOCAL_MODULES_ARCHIVE_NAME" >&2
  exit 1
fi

if [[ "$LOCAL_SYSTEM_MAP_NAME" != "System.map" ]]; then
  echo "Unexpected guest kernel manifest system_map_name: $LOCAL_SYSTEM_MAP_NAME" >&2
  exit 1
fi

if [[ "$LOCAL_RESOLVED_CONFIG_NAME" != "linux.config" ]]; then
  echo "Unexpected guest kernel manifest resolved_config_name: $LOCAL_RESOLVED_CONFIG_NAME" >&2
  exit 1
fi

if [[ "$LOCAL_MANIFEST_IMAGE_SHA" != "$LOCAL_IMAGE_SHA" ]]; then
  echo "Guest kernel manifest image_sha256 does not match copied Image" >&2
  exit 1
fi

if [[ "$LOCAL_MANIFEST_MODULES_ARCHIVE_SHA" != "$LOCAL_MODULES_ARCHIVE_SHA" ]]; then
  echo "Guest kernel manifest modules_archive_sha256 does not match copied modules.tar.xz" >&2
  exit 1
fi

if [[ "$LOCAL_MANIFEST_SYSTEM_MAP_SHA" != "$LOCAL_SYSTEM_MAP_SHA" ]]; then
  echo "Guest kernel manifest system_map_sha256 does not match copied System.map" >&2
  exit 1
fi

if [[ "$LOCAL_MANIFEST_RESOLVED_CONFIG_SHA" != "$LOCAL_RESOLVED_CONFIG_SHA" ]]; then
  echo "Guest kernel manifest resolved_config_sha256 does not match copied linux.config" >&2
  exit 1
fi

LOCAL_MODULE_SYMVERS_SHA=""
LOCAL_MANIFEST_MODULE_SYMVERS_SHA=""
if [[ -f "$LOCAL_MODULE_SYMVERS" ]]; then
  LOCAL_MODULE_SYMVERS_SHA="$(sha256_file "$LOCAL_MODULE_SYMVERS")"
  if toml_has_key "$LOCAL_MANIFEST" module_symvers_sha256; then
    LOCAL_MANIFEST_MODULE_SYMVERS_SHA="$(toml_value "$LOCAL_MANIFEST" module_symvers_sha256)"
  fi
  if [[ -z "$LOCAL_MANIFEST_MODULE_SYMVERS_SHA" || "$LOCAL_MANIFEST_MODULE_SYMVERS_SHA" != "$LOCAL_MODULE_SYMVERS_SHA" ]]; then
    echo "Guest kernel manifest module_symvers_sha256 does not match copied Module.symvers" >&2
    exit 1
  fi
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
cp "$LOCAL_MODULES_ARCHIVE" "$host_artifact_dir/modules.tar.xz.tmp"
mv "$host_artifact_dir/modules.tar.xz.tmp" "$host_artifact_dir/modules.tar.xz"
if [[ -f "$LOCAL_MODULE_SYMVERS" ]]; then
  cp "$LOCAL_MODULE_SYMVERS" "$host_artifact_dir/Module.symvers.tmp"
  mv "$host_artifact_dir/Module.symvers.tmp" "$host_artifact_dir/Module.symvers"
fi
MODULE_SYMVERS_HANDOFF_FIELDS=""
if [[ -n "$LOCAL_MODULE_SYMVERS_SHA" ]]; then
  MODULE_SYMVERS_HANDOFF_FIELDS="
module_symvers_name = \"Module.symvers\"
module_symvers_sha256 = \"$LOCAL_MODULE_SYMVERS_SHA\""
fi
cat >"$host_artifact_dir/host-handoff.toml" <<EOF
source_guest_artifact = "$artifact_root"
validated_at = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
validated_by = "scripts/promote-guest-kernel-candidate.sh"
image_name = "Image"
manifest_name = "manifest.toml"
system_map_name = "System.map"
resolved_config_name = "linux.config"
modules_archive_name = "modules.tar.xz"
image_sha256 = "$LOCAL_IMAGE_SHA"
manifest_sha256 = "$LOCAL_MANIFEST_SHA"
system_map_sha256 = "$LOCAL_SYSTEM_MAP_SHA"
resolved_config_sha256 = "$LOCAL_RESOLVED_CONFIG_SHA"
modules_archive_sha256 = "$LOCAL_MODULES_ARCHIVE_SHA"
manifest_schema_version = $LOCAL_MANIFEST_SCHEMA
kernel_release = "$LOCAL_KERNEL_RELEASE"$MODULE_SYMVERS_HANDOFF_FIELDS
EOF
ln -sfn "$artifact_name" "$HOST_CANDIDATE_ROOT/current"
echo "Promoted guest kernel candidate to $HOST_CANDIDATE_ROOT/current/Image"
