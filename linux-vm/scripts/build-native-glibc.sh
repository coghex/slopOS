#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_GLIBC_ARCHIVE_PATH="${LOCAL_GLIBC_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/glibc/glibc-2.43-10-gc3ceb93dc4f67253037644dc8f194831e27f3160-git4.tar.gz}"
LOCAL_LINUX_ARCHIVE_PATH="${LOCAL_LINUX_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/linux/linux-6.18.7.tar.xz}"
GLIBC_ARCHIVE="${GLIBC_ARCHIVE:-$(basename "$LOCAL_GLIBC_ARCHIVE_PATH")}"
LINUX_ARCHIVE="${LINUX_ARCHIVE:-$(basename "$LOCAL_LINUX_ARCHIVE_PATH")}"
SDK_ROOT="${SDK_ROOT:-/Volumes/slopos-data/toolchain/current}"
NATIVE_BINUTILS_ROOT="${NATIVE_BINUTILS_ROOT:-/Volumes/slopos-data/toolchain/native}"
SOURCE_ROOT="${SOURCE_ROOT:-/Volumes/slopos-data/toolchain/sources}"
BUILD_ROOT="${BUILD_ROOT:-/Volumes/slopos-data/toolchain/build}"
GLIBC_STAGE_ROOT="${GLIBC_STAGE_ROOT:-/Volumes/slopos-data/toolchain/glibc-stage}"
KERNEL_HEADERS_ROOT="${KERNEL_HEADERS_ROOT:-/Volumes/slopos-data/toolchain/kernel-headers}"
GLIBC_ENABLE_KERNEL="${GLIBC_ENABLE_KERNEL:-6.18.0}"

if [[ ! -f "$LOCAL_GLIBC_ARCHIVE_PATH" ]]; then
  echo "Missing cached glibc archive: $LOCAL_GLIBC_ARCHIVE_PATH" >&2
  exit 1
fi

if [[ ! -f "$LOCAL_LINUX_ARCHIVE_PATH" ]]; then
  echo "Missing cached linux archive: $LOCAL_LINUX_ARCHIVE_PATH" >&2
  exit 1
fi

guest_script="$(mktemp)"
trap 'rm -f "$guest_script"' EXIT

cat >"$guest_script" <<EOF
#!/bin/bash
set -euo pipefail

glibc_archive=$(printf '%q' "$GLIBC_ARCHIVE")
linux_archive=$(printf '%q' "$LINUX_ARCHIVE")
sdk_root=$(printf '%q' "$SDK_ROOT")
native_binutils_root=$(printf '%q' "$NATIVE_BINUTILS_ROOT")
source_root=$(printf '%q' "$SOURCE_ROOT")
build_root=$(printf '%q' "$BUILD_ROOT")
glibc_stage_root=$(printf '%q' "$GLIBC_STAGE_ROOT")
kernel_headers_root=$(printf '%q' "$KERNEL_HEADERS_ROOT")
glibc_enable_kernel=$(printf '%q' "$GLIBC_ENABLE_KERNEL")
glibc_archive_path="\$source_root/\$glibc_archive"
linux_archive_path="\$source_root/\$linux_archive"
kernel_source_dir=
glibc_source_dir=
glibc_build_dir="\$build_root/glibc-build"
smoke_dir="\$build_root/glibc-smoke"
sdk_compiler="\$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc"
native_as="\$native_binutils_root/bin/aarch64-linux-gnu-as"
native_ld="\$native_binutils_root/bin/aarch64-linux-gnu-ld"
native_ar="\$native_binutils_root/bin/aarch64-linux-gnu-ar"
native_ranlib="\$native_binutils_root/bin/aarch64-linux-gnu-ranlib"

mkdir -p "\$source_root" "\$build_root"

if [[ ! -x "\$sdk_compiler" ]]; then
  echo "Missing SDK compiler: \$sdk_compiler" >&2
  exit 1
fi

for tool in "\$native_as" "\$native_ld" "\$native_ar" "\$native_ranlib"; do
  if [[ ! -x "\$tool" ]]; then
    echo "Missing native binutils component: \$tool" >&2
    exit 1
  fi
done

set +o pipefail
kernel_source_dir="\$source_root/\$(tar -tf "\$linux_archive_path" | head -n 1 | cut -d/ -f1)"
glibc_source_dir="\$source_root/\$(tar -tf "\$glibc_archive_path" | head -n 1 | cut -d/ -f1)"
set -o pipefail

if [[ ! -d "\$kernel_source_dir" ]]; then
  tar -xf "\$linux_archive_path" -C "\$source_root"
fi

if [[ ! -d "\$glibc_source_dir" ]]; then
  tar -xf "\$glibc_archive_path" -C "\$source_root"
fi

rm -rf "\$kernel_headers_root"
mkdir -p "\$kernel_headers_root"

if ! make -C "\$kernel_source_dir" \
  ARCH=arm64 \
  HOSTCC="\$sdk_compiler -B\$native_binutils_root/bin" \
  headers_install \
  INSTALL_HDR_PATH="\$kernel_headers_root"; then
  if [[ ! -d "\$kernel_source_dir/usr/include" ]]; then
    echo "Kernel headers_install failed before generating usr/include" >&2
    exit 1
  fi
  mkdir -p "\$kernel_headers_root/include"
  cp -a "\$kernel_source_dir/usr/include/." "\$kernel_headers_root/include/"
fi

rm -rf "\$glibc_build_dir" "\$glibc_stage_root" "\$smoke_dir"
mkdir -p "\$glibc_build_dir" "\$glibc_stage_root" "\$smoke_dir"
cd "\$glibc_build_dir"

export PATH="\$sdk_root/bin:/usr/bin:/bin"
export CONFIG_SHELL=/bin/bash
export BUILD_CC="\$sdk_compiler -B\$native_binutils_root/bin"
export CC="\$sdk_compiler -B\$native_binutils_root/bin"
export AR="\$native_ar"
export AS="\$native_as"
export LD="\$native_ld"
export RANLIB="\$native_ranlib"

libc_cv_slibdir=/lib \
"\$glibc_source_dir/configure" \
  --prefix=/usr \
  --host=aarch64-linux-gnu \
  --build=aarch64-linux-gnu \
  --with-binutils="\$native_binutils_root/bin" \
  --with-headers="\$kernel_headers_root/include" \
  --enable-kernel="\$glibc_enable_kernel" \
  --disable-werror

make -j"\$(nproc 2>/dev/null || echo 2)"
make install install_root="\$glibc_stage_root"

cat >"\$smoke_dir/hello.c" <<'SRC'
#include <stdio.h>

int main(void) {
  puts("glibc-stage-ok");
  return 0;
}
SRC

"\$sdk_compiler" -B"\$native_binutils_root/bin" --sysroot="\$glibc_stage_root" "\$smoke_dir/hello.c" -o "\$smoke_dir/hello"
"$GLIBC_STAGE_ROOT/lib/ld-linux-aarch64.so.1" --library-path "$GLIBC_STAGE_ROOT/lib:$GLIBC_STAGE_ROOT/usr/lib" "\$smoke_dir/hello"
/usr/bin/file "\$glibc_stage_root/lib/libc.so.6"
EOF

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$SOURCE_ROOT'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_GLIBC_ARCHIVE_PATH" "$SOURCE_ROOT/$GLIBC_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_LINUX_ARCHIVE_PATH" "$SOURCE_ROOT/$LINUX_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$guest_script" /tmp/build-native-glibc.sh
"$ROOT_DIR/scripts/ssh-guest.sh" "bash /tmp/build-native-glibc.sh"
