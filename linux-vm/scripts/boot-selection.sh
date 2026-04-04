#!/usr/bin/env bash

resolve_absolute_path() {
  python3 - "$1" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve())
PY
}

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

boot_selection_metadata_path_for_root_disk() {
  local root_disk_image="$1"
  printf '%s.boot-selection.toml\n' "$root_disk_image"
}

resolve_buildroot_boot_paths() {
  : "${ROOT_DIR:?ROOT_DIR must be set before sourcing boot-selection.sh}"

  BUILDROOT_ROOTFS_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext4"
  BUILDROOT_ROOTFS_EXT2_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/rootfs.ext2"
  BUILDROOT_KERNEL_IMAGE="$ROOT_DIR/artifacts/buildroot-output/images/Image"

  if [[ ! -f "$BUILDROOT_ROOTFS_IMAGE" && -f "$BUILDROOT_ROOTFS_EXT2_IMAGE" ]]; then
    BUILDROOT_ROOTFS_IMAGE="$BUILDROOT_ROOTFS_EXT2_IMAGE"
  fi
}

resolve_promoted_boot_paths() {
  : "${ROOT_DIR:?ROOT_DIR must be set before sourcing boot-selection.sh}"

  PROMOTED_BOOT_ROOT="${HOST_GUEST_PROMOTED_BOOT_ROOT:-$ROOT_DIR/artifacts/guest-boot-promoted}"
  if [[ "$PROMOTED_BOOT_ROOT" != /* ]]; then
    PROMOTED_BOOT_ROOT="$ROOT_DIR/$PROMOTED_BOOT_ROOT"
  fi

  PROMOTED_BOOT_CURRENT="$PROMOTED_BOOT_ROOT/current"
  PROMOTED_ROOTFS_IMAGE="$PROMOTED_BOOT_CURRENT/rootfs.ext4"
  PROMOTED_KERNEL_IMAGE="$PROMOTED_BOOT_CURRENT/Image"
  PROMOTED_BOOT_METADATA="$PROMOTED_BOOT_CURRENT/promotion.toml"

  RESOLVED_PROMOTED_BOOT_ROOT=""
  RESOLVED_PROMOTED_ROOTFS_IMAGE=""
  RESOLVED_PROMOTED_KERNEL_IMAGE=""
  RESOLVED_PROMOTED_BOOT_METADATA=""

  if [[ -d "$PROMOTED_BOOT_CURRENT" || -L "$PROMOTED_BOOT_CURRENT" ]]; then
    RESOLVED_PROMOTED_BOOT_ROOT="$(resolve_absolute_path "$PROMOTED_BOOT_CURRENT")"
    RESOLVED_PROMOTED_ROOTFS_IMAGE="$RESOLVED_PROMOTED_BOOT_ROOT/rootfs.ext4"
    RESOLVED_PROMOTED_KERNEL_IMAGE="$RESOLVED_PROMOTED_BOOT_ROOT/Image"
    RESOLVED_PROMOTED_BOOT_METADATA="$RESOLVED_PROMOTED_BOOT_ROOT/promotion.toml"
  fi
}

resolve_default_boot_pair() {
  resolve_buildroot_boot_paths
  resolve_promoted_boot_paths

  DEFAULT_ROOTFS_SOURCE_IMAGE="$BUILDROOT_ROOTFS_IMAGE"
  DEFAULT_ROOTFS_SOURCE_KIND="buildroot"
  DEFAULT_KERNEL_IMAGE="$BUILDROOT_KERNEL_IMAGE"
  DEFAULT_KERNEL_SOURCE_KIND="buildroot"
  DEFAULT_PROMOTION_ROOT=""
  DEFAULT_PROMOTION_METADATA=""

  if [[ -d "$PROMOTED_BOOT_CURRENT" || -L "$PROMOTED_BOOT_CURRENT" ]]; then
    if [[ ! -f "$RESOLVED_PROMOTED_ROOTFS_IMAGE" ]]; then
      echo "Promoted default boot rootfs is incomplete: $RESOLVED_PROMOTED_ROOTFS_IMAGE" >&2
      return 1
    fi
    if [[ ! -f "$RESOLVED_PROMOTED_KERNEL_IMAGE" ]]; then
      echo "Promoted default boot kernel is incomplete: $RESOLVED_PROMOTED_KERNEL_IMAGE" >&2
      return 1
    fi

    DEFAULT_ROOTFS_SOURCE_IMAGE="$RESOLVED_PROMOTED_ROOTFS_IMAGE"
    DEFAULT_ROOTFS_SOURCE_KIND="promoted-default"
    DEFAULT_KERNEL_IMAGE="$RESOLVED_PROMOTED_KERNEL_IMAGE"
    DEFAULT_KERNEL_SOURCE_KIND="promoted-default"
    DEFAULT_PROMOTION_ROOT="$RESOLVED_PROMOTED_BOOT_ROOT"
    if [[ -f "$RESOLVED_PROMOTED_BOOT_METADATA" ]]; then
      DEFAULT_PROMOTION_METADATA="$RESOLVED_PROMOTED_BOOT_METADATA"
    fi
  fi
}

write_root_disk_boot_selection_metadata() {
  local metadata_path="$1"
  local metadata_tmp="${metadata_path}.tmp"
  local selection_scope="${ROOT_DISK_SELECTION_SCOPE:-default}"
  local rootfs_source_kind="${ROOT_DISK_ROOTFS_SOURCE_KIND:-unknown}"
  local kernel_source_kind="${ROOT_DISK_KERNEL_SOURCE_KIND:-unknown}"
  local rootfs_source_image="${ROOT_DISK_SELECTED_ROOTFS_IMAGE:-}"
  local kernel_image="${ROOT_DISK_SELECTED_KERNEL_IMAGE:-}"
  local promotion_root="${ROOT_DISK_SELECTED_PROMOTION_ROOT:-}"
  local promotion_metadata="${ROOT_DISK_SELECTED_PROMOTION_METADATA:-}"
  local rootfs_source_sha=""
  local kernel_image_sha=""
  local promotion_fields=""
  local promotion_id=""

  if [[ -z "$rootfs_source_image" || -z "$kernel_image" ]]; then
    echo "Refusing to write incomplete boot selection metadata to $metadata_path" >&2
    return 1
  fi

  if [[ ! -f "$rootfs_source_image" ]]; then
    echo "Cannot record missing rootfs source image in boot selection metadata: $rootfs_source_image" >&2
    return 1
  fi

  if [[ ! -f "$kernel_image" ]]; then
    echo "Cannot record missing kernel image in boot selection metadata: $kernel_image" >&2
    return 1
  fi

  rootfs_source_sha="$(sha256_file "$rootfs_source_image")"
  kernel_image_sha="$(sha256_file "$kernel_image")"

  if [[ -n "$promotion_root" ]]; then
    promotion_id="$(basename "$promotion_root")"
    promotion_fields="
promotion_root = \"$promotion_root\"
promotion_id = \"$promotion_id\""
    if [[ -n "$promotion_metadata" && -f "$promotion_metadata" ]]; then
      promotion_fields="$promotion_fields
promotion_metadata = \"$promotion_metadata\""
    fi
  fi

  cat >"$metadata_tmp" <<EOF
schema_version = 1
selected_at = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
selected_by = "scripts/ensure-root-disk.sh"
selection_scope = "$selection_scope"
rootfs_source_kind = "$rootfs_source_kind"
rootfs_source_image = "$rootfs_source_image"
rootfs_source_sha256 = "$rootfs_source_sha"
kernel_source_kind = "$kernel_source_kind"
kernel_image = "$kernel_image"
kernel_image_sha256 = "$kernel_image_sha"$promotion_fields
EOF

  mv "$metadata_tmp" "$metadata_path"
}
