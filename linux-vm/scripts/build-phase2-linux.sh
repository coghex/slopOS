#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDROOT_DIR="$ROOT_DIR/buildroot-src"
BUILDROOT_EXTERNAL_DIR="$ROOT_DIR/buildroot-external"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/artifacts/buildroot-output}"
DEFCONFIG_PATH="$ROOT_DIR/configs/slopos_aarch64_virt_defconfig"
JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 8)}"

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

mkdir -p "$OUTPUT_DIR"

make -C "$BUILDROOT_DIR" O="$OUTPUT_DIR" BR2_EXTERNAL="$BUILDROOT_EXTERNAL_DIR" BR2_DEFCONFIG="$DEFCONFIG_PATH" defconfig
make -C "$BUILDROOT_DIR" O="$OUTPUT_DIR" BR2_EXTERNAL="$BUILDROOT_EXTERNAL_DIR" -j"$JOBS"

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
