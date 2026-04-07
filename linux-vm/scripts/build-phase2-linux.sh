#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDROOT_DIR="$ROOT_DIR/buildroot-src"
BUILDROOT_EXTERNAL_DIR="$ROOT_DIR/buildroot-external"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/artifacts/buildroot-output}"
DEFCONFIG_PATH="$ROOT_DIR/configs/slopos_aarch64_virt_defconfig"
JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 8)}"
DEFCONFIG_HASH_FILE="$OUTPUT_DIR/.slopos-defconfig.sha256"

defconfig_sha256() {
  python3 - "$DEFCONFIG_PATH" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script is intended to run inside a Linux builder environment." >&2
  exit 1
fi

if [[ ! -d "$BUILDROOT_DIR/.git" ]]; then
  echo "Buildroot checkout not found at $BUILDROOT_DIR" >&2
  exit 1
fi

if [[ ! -f "$DEFCONFIG_PATH" ]]; then
  echo "Missing defconfig: $DEFCONFIG_PATH" >&2
  exit 1
fi

if [[ ! -f "$BUILDROOT_EXTERNAL_DIR/external.desc" ]]; then
  echo "Missing Buildroot external tree: $BUILDROOT_EXTERNAL_DIR" >&2
  exit 1
fi

buildroot_conf="$OUTPUT_DIR/build/buildroot-config/conf"
if [[ -f "$buildroot_conf" ]]; then
  if file "$buildroot_conf" | grep -qv 'ELF'; then
    echo "Cleaning mixed-host Buildroot output at $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
  fi
fi

current_defconfig_hash="$(defconfig_sha256)"
if [[ -d "$OUTPUT_DIR" ]]; then
  previous_defconfig_hash=""
  if [[ -f "$DEFCONFIG_HASH_FILE" ]]; then
    previous_defconfig_hash="$(<"$DEFCONFIG_HASH_FILE")"
  fi
  if [[ -z "$previous_defconfig_hash" || "$previous_defconfig_hash" != "$current_defconfig_hash" ]]; then
    echo "Cleaning Buildroot output at $OUTPUT_DIR because the checked-in defconfig changed."
    rm -rf "$OUTPUT_DIR"
  fi
fi

mkdir -p "$OUTPUT_DIR"

make -C "$BUILDROOT_DIR" O="$OUTPUT_DIR" BR2_EXTERNAL="$BUILDROOT_EXTERNAL_DIR" BR2_DEFCONFIG="$DEFCONFIG_PATH" defconfig
make -C "$BUILDROOT_DIR" O="$OUTPUT_DIR" BR2_EXTERNAL="$BUILDROOT_EXTERNAL_DIR" -j"$JOBS"

printf '%s\n' "$current_defconfig_hash" >"$DEFCONFIG_HASH_FILE"

initramfs_image="$OUTPUT_DIR/images/rootfs.cpio"
if [[ -f "$OUTPUT_DIR/images/rootfs.cpio.gz" ]]; then
  initramfs_image="$OUTPUT_DIR/images/rootfs.cpio.gz"
fi

rootfs_image="$OUTPUT_DIR/images/rootfs.ext4"
if [[ ! -f "$rootfs_image" && -f "$OUTPUT_DIR/images/rootfs.ext2" ]]; then
  rootfs_image="$OUTPUT_DIR/images/rootfs.ext2"
fi

echo
echo "Linux builder complete."
echo "Kernel image : $OUTPUT_DIR/images/Image"
echo "Rootfs image : $rootfs_image"
echo "Initramfs    : $initramfs_image"
