#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDROOT_DIR="$ROOT_DIR/buildroot-src"
BUILDROOT_EXTERNAL_DIR="$ROOT_DIR/buildroot-external"
OUTPUT_DIR="$ROOT_DIR/artifacts/buildroot-output"
DEFCONFIG_PATH="$ROOT_DIR/configs/slopos_aarch64_virt_defconfig"
PRECHECK_SCRIPT="$ROOT_DIR/scripts/host-preflight.sh"
JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

for gnubin_dir in \
  /opt/homebrew/bin \
  /opt/homebrew/opt/util-linux/bin \
  /opt/homebrew/opt/gpatch/libexec/gnubin \
  /opt/homebrew/opt/gnu-sed/libexec/gnubin \
  /opt/homebrew/opt/findutils/libexec/gnubin \
  /opt/homebrew/opt/coreutils/libexec/gnubin \
  /opt/homebrew/opt/grep/libexec/gnubin \
  /opt/homebrew/opt/gawk/libexec/gnubin \
  /opt/homebrew/opt/gnu-tar/libexec/gnubin
do
  if [[ -d "$gnubin_dir" ]]; then
    PATH="$gnubin_dir:$PATH"
  fi
done

export PATH

shopt -s nullglob
gcc_candidates=(/opt/homebrew/bin/gcc-[0-9]*)
default_host_gcc=""
if [[ "${#gcc_candidates[@]}" -gt 0 ]]; then
  default_host_gcc="$(printf '%s\n' "${gcc_candidates[@]}" | sort -V | tail -n 1)"
fi
HOST_GCC="${HOST_GCC:-$default_host_gcc}"
HOST_GXX="${HOST_GXX:-}"

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

if [[ -z "$HOST_GCC" || ! -x "$HOST_GCC" ]]; then
  echo "Missing GNU gcc. Install Homebrew gcc or set HOST_GCC explicitly." >&2
  exit 1
fi

if [[ -z "$HOST_GXX" ]]; then
  HOST_GXX="${HOST_GCC/gcc-/g++-}"
fi

if [[ ! -x "$HOST_GXX" ]]; then
  echo "Missing GNU g++. Install Homebrew gcc or set HOST_GXX explicitly." >&2
  exit 1
fi

"$PRECHECK_SCRIPT"

mkdir -p "$OUTPUT_DIR"

make -C "$BUILDROOT_DIR" \
  O="$OUTPUT_DIR" \
  BR2_EXTERNAL="$BUILDROOT_EXTERNAL_DIR" \
  BR2_DEFCONFIG="$DEFCONFIG_PATH" \
  HOSTCC="$HOST_GCC" \
  HOSTCXX="$HOST_GXX" \
  defconfig

make -C "$BUILDROOT_DIR" \
  O="$OUTPUT_DIR" \
  BR2_EXTERNAL="$BUILDROOT_EXTERNAL_DIR" \
  HOSTCC="$HOST_GCC" \
  HOSTCXX="$HOST_GXX" \
  -j"$JOBS"

initramfs_image="$OUTPUT_DIR/images/rootfs.cpio"
if [[ -f "$OUTPUT_DIR/images/rootfs.cpio.gz" ]]; then
  initramfs_image="$OUTPUT_DIR/images/rootfs.cpio.gz"
fi

rootfs_image="$OUTPUT_DIR/images/rootfs.ext4"
if [[ ! -f "$rootfs_image" && -f "$OUTPUT_DIR/images/rootfs.ext2" ]]; then
  rootfs_image="$OUTPUT_DIR/images/rootfs.ext2"
fi

echo
echo "Build complete."
echo "Kernel image : $OUTPUT_DIR/images/Image"
echo "Rootfs image : $rootfs_image"
echo "Initramfs    : $initramfs_image"
