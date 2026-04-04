#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_ROOTFS_CANDIDATE_ROOT="${HOST_GUEST_ROOTFS_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-rootfs-candidate}"
HOST_KERNEL_CANDIDATE_ROOT="${HOST_GUEST_KERNEL_CANDIDATE_ROOT:-$ROOT_DIR/artifacts/guest-kernel-candidate}"
HOST_PROMOTED_BOOT_ROOT="${HOST_GUEST_PROMOTED_BOOT_ROOT:-$ROOT_DIR/artifacts/guest-boot-promoted}"

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
print(hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

usage() {
  cat <<'EOF'
Usage: ./scripts/promote-guest-boot-default.sh [--clear]

Copies the current host-side guest rootfs and kernel candidates into a promoted
host-side default-boot path under artifacts/guest-boot-promoted/current without
overwriting the Buildroot outputs. Use --clear to remove the current promoted
default and fall back to the Buildroot boot artifacts on the next reset/boot.
EOF
}

clear_mode=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clear)
      clear_mode=1
      shift
      ;;
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

for var_name in HOST_ROOTFS_CANDIDATE_ROOT HOST_KERNEL_CANDIDATE_ROOT HOST_PROMOTED_BOOT_ROOT; do
  var_value="${!var_name}"
  if [[ "$var_value" != /* ]]; then
    printf -v "$var_name" '%s/%s' "$ROOT_DIR" "$var_value"
  fi
done

if [[ "$clear_mode" == "1" ]]; then
  if [[ -L "$HOST_PROMOTED_BOOT_ROOT/current" || -e "$HOST_PROMOTED_BOOT_ROOT/current" ]]; then
    rm -f "$HOST_PROMOTED_BOOT_ROOT/current"
    echo "Cleared promoted default boot selection under $HOST_PROMOTED_BOOT_ROOT/current"
  else
    echo "No promoted default boot selection was active."
  fi
  exit 0
fi

rootfs_candidate_image="$HOST_ROOTFS_CANDIDATE_ROOT/current/rootfs.ext4"
rootfs_candidate_manifest="$HOST_ROOTFS_CANDIDATE_ROOT/current/manifest.toml"
rootfs_candidate_handoff="$HOST_ROOTFS_CANDIDATE_ROOT/current/host-handoff.toml"
kernel_candidate_image="$HOST_KERNEL_CANDIDATE_ROOT/current/Image"
kernel_candidate_manifest="$HOST_KERNEL_CANDIDATE_ROOT/current/manifest.toml"
kernel_candidate_handoff="$HOST_KERNEL_CANDIDATE_ROOT/current/host-handoff.toml"
kernel_candidate_system_map="$HOST_KERNEL_CANDIDATE_ROOT/current/System.map"
kernel_candidate_config="$HOST_KERNEL_CANDIDATE_ROOT/current/linux.config"
kernel_candidate_modules_archive="$HOST_KERNEL_CANDIDATE_ROOT/current/modules.tar.xz"
kernel_candidate_module_symvers="$HOST_KERNEL_CANDIDATE_ROOT/current/Module.symvers"

for required in \
  "$rootfs_candidate_image" \
  "$rootfs_candidate_manifest" \
  "$rootfs_candidate_handoff" \
  "$kernel_candidate_image" \
  "$kernel_candidate_manifest" \
  "$kernel_candidate_handoff" \
  "$kernel_candidate_system_map" \
  "$kernel_candidate_config" \
  "$kernel_candidate_modules_archive"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing required candidate artifact: $required" >&2
    exit 1
  fi
done

promotion_id="promotion-$(date -u '+%Y%m%dT%H%M%SZ')"
promotion_dir="$HOST_PROMOTED_BOOT_ROOT/$promotion_id"
mkdir -p "$promotion_dir"

cp "$rootfs_candidate_image" "$promotion_dir/rootfs.ext4.tmp"
mv "$promotion_dir/rootfs.ext4.tmp" "$promotion_dir/rootfs.ext4"
cp "$rootfs_candidate_manifest" "$promotion_dir/rootfs.manifest.toml.tmp"
mv "$promotion_dir/rootfs.manifest.toml.tmp" "$promotion_dir/rootfs.manifest.toml"
if [[ -f "$rootfs_candidate_handoff" ]]; then
  cp "$rootfs_candidate_handoff" "$promotion_dir/rootfs.host-handoff.toml.tmp"
  mv "$promotion_dir/rootfs.host-handoff.toml.tmp" "$promotion_dir/rootfs.host-handoff.toml"
fi

cp "$kernel_candidate_image" "$promotion_dir/Image.tmp"
mv "$promotion_dir/Image.tmp" "$promotion_dir/Image"
cp "$kernel_candidate_manifest" "$promotion_dir/kernel.manifest.toml.tmp"
mv "$promotion_dir/kernel.manifest.toml.tmp" "$promotion_dir/kernel.manifest.toml"
if [[ -f "$kernel_candidate_handoff" ]]; then
  cp "$kernel_candidate_handoff" "$promotion_dir/kernel.host-handoff.toml.tmp"
  mv "$promotion_dir/kernel.host-handoff.toml.tmp" "$promotion_dir/kernel.host-handoff.toml"
fi
cp "$kernel_candidate_system_map" "$promotion_dir/System.map.tmp"
mv "$promotion_dir/System.map.tmp" "$promotion_dir/System.map"
cp "$kernel_candidate_config" "$promotion_dir/linux.config.tmp"
mv "$promotion_dir/linux.config.tmp" "$promotion_dir/linux.config"
cp "$kernel_candidate_modules_archive" "$promotion_dir/modules.tar.xz.tmp"
mv "$promotion_dir/modules.tar.xz.tmp" "$promotion_dir/modules.tar.xz"
if [[ -f "$kernel_candidate_module_symvers" ]]; then
  cp "$kernel_candidate_module_symvers" "$promotion_dir/Module.symvers.tmp"
  mv "$promotion_dir/Module.symvers.tmp" "$promotion_dir/Module.symvers"
fi

rootfs_image_sha="$(sha256_file "$promotion_dir/rootfs.ext4")"
rootfs_manifest_sha="$(sha256_file "$promotion_dir/rootfs.manifest.toml")"
kernel_image_sha="$(sha256_file "$promotion_dir/Image")"
kernel_manifest_sha="$(sha256_file "$promotion_dir/kernel.manifest.toml")"
kernel_system_map_sha="$(sha256_file "$promotion_dir/System.map")"
kernel_resolved_config_sha="$(sha256_file "$promotion_dir/linux.config")"
kernel_modules_archive_sha="$(sha256_file "$promotion_dir/modules.tar.xz")"
kernel_module_symvers_fields=""
if [[ -f "$promotion_dir/Module.symvers" ]]; then
  kernel_module_symvers_sha="$(sha256_file "$promotion_dir/Module.symvers")"
  kernel_module_symvers_fields="
kernel_module_symvers_sha256 = \"$kernel_module_symvers_sha\""
fi

cat >"$promotion_dir/promotion.toml" <<EOF
promoted_at = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
promoted_by = "scripts/promote-guest-boot-default.sh"
rootfs_candidate = "$rootfs_candidate_image"
rootfs_candidate_manifest = "$rootfs_candidate_manifest"
rootfs_candidate_handoff = "$rootfs_candidate_handoff"
rootfs_image_sha256 = "$rootfs_image_sha"
rootfs_manifest_sha256 = "$rootfs_manifest_sha"
kernel_candidate = "$kernel_candidate_image"
kernel_candidate_manifest = "$kernel_candidate_manifest"
kernel_candidate_handoff = "$kernel_candidate_handoff"
kernel_image_sha256 = "$kernel_image_sha"
kernel_manifest_sha256 = "$kernel_manifest_sha"
kernel_modules_archive_sha256 = "$kernel_modules_archive_sha"
kernel_system_map_sha256 = "$kernel_system_map_sha"
kernel_resolved_config_sha256 = "$kernel_resolved_config_sha"$kernel_module_symvers_fields
default_boot = true
EOF

ln -sfn "$promotion_id" "$HOST_PROMOTED_BOOT_ROOT/current"
echo "Promoted default normal boot source under $HOST_PROMOTED_BOOT_ROOT/current"
echo "  rootfs: $HOST_PROMOTED_BOOT_ROOT/current/rootfs.ext4"
echo "  kernel: $HOST_PROMOTED_BOOT_ROOT/current/Image"
