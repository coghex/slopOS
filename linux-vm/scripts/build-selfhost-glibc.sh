#!/usr/bin/env bash
set -euo pipefail

echo "warning: build-selfhost-glibc.sh is a legacy/manual helper." >&2
echo "warning: preferred workflow: /usr/local/bin/sloppkg --state-root /Volumes/slopos-data/pkg install selfhost-toolchain --root /" >&2

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_GLIBC_ARCHIVE_PATH="${LOCAL_GLIBC_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/glibc/glibc-2.43-10-gc3ceb93dc4f67253037644dc8f194831e27f3160-git4.tar.gz}"
LOCAL_LINUX_ARCHIVE_PATH="${LOCAL_LINUX_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/linux/linux-6.18.7.tar.xz}"
GLIBC_ARCHIVE="${GLIBC_ARCHIVE:-$(basename "$LOCAL_GLIBC_ARCHIVE_PATH")}"
LINUX_ARCHIVE="${LINUX_ARCHIVE:-$(basename "$LOCAL_LINUX_ARCHIVE_PATH")}"
STAGE1_ROOT="${STAGE1_ROOT:-/Volumes/slopos-data/toolchain/selfhost-stage1}"
INTERMEDIATE_ROOT="${INTERMEDIATE_ROOT:-/Volumes/slopos-data/toolchain/selfhost-stage2}"
SDK_ROOT="${SDK_ROOT:-/Volumes/slopos-data/toolchain/current}"
SOURCE_ROOT="${SOURCE_ROOT:-/Volumes/slopos-data/toolchain/sources}"
BUILD_ROOT="${BUILD_ROOT:-/Volumes/slopos-data/toolchain/build}"
SELFHOST_GLIBC_STAGE_ROOT="${SELFHOST_GLIBC_STAGE_ROOT:-/Volumes/slopos-data/toolchain/selfhost-glibc-stage}"
KERNEL_HEADERS_ROOT="${KERNEL_HEADERS_ROOT:-/Volumes/slopos-data/toolchain/selfhost-kernel-headers}"
GLIBC_ENABLE_KERNEL="${GLIBC_ENABLE_KERNEL:-6.18.0}"
BUILD_JOBS="${BUILD_JOBS:-2}"

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
stage1_root=$(printf '%q' "$STAGE1_ROOT")
intermediate_root=$(printf '%q' "$INTERMEDIATE_ROOT")
sdk_root=$(printf '%q' "$SDK_ROOT")
source_root=$(printf '%q' "$SOURCE_ROOT")
build_root=$(printf '%q' "$BUILD_ROOT")
selfhost_glibc_stage_root=$(printf '%q' "$SELFHOST_GLIBC_STAGE_ROOT")
kernel_headers_root=$(printf '%q' "$KERNEL_HEADERS_ROOT")
glibc_enable_kernel=$(printf '%q' "$GLIBC_ENABLE_KERNEL")
build_jobs=$(printf '%q' "$BUILD_JOBS")

stage1_bin="\$stage1_root/bin"
intermediate_gcc="\$intermediate_root/bin/selfhost-gcc"
intermediate_driver="\$intermediate_root/bin/aarch64-linux-gnu-gcc"
glibc_archive_path="\$source_root/\$glibc_archive"
linux_archive_path="\$source_root/\$linux_archive"
glibc_build_dir="\$build_root/selfhost-glibc-build"
smoke_dir="\$build_root/selfhost-glibc-smoke"

for tool in \
  "\$intermediate_gcc" \
  "\$intermediate_driver" \
  "\$stage1_bin/aarch64-linux-gnu-as" \
  "\$stage1_bin/aarch64-linux-gnu-ld" \
  "\$stage1_bin/aarch64-linux-gnu-ar" \
  "\$stage1_bin/aarch64-linux-gnu-ranlib" \
  /usr/bin/gcc; do
  if [[ ! -x "\$tool" ]]; then
    echo "Missing required tool: \$tool" >&2
    exit 1
  fi
done

mkdir -p "\$source_root" "\$build_root"

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
  HOSTCC="/usr/bin/gcc -B\$stage1_bin" \
  headers_install \
  INSTALL_HDR_PATH="\$kernel_headers_root"; then
  if [[ ! -d "\$kernel_source_dir/usr/include" ]]; then
    echo "Kernel headers_install failed before generating usr/include" >&2
    exit 1
  fi
  mkdir -p "\$kernel_headers_root/include"
  cp -a "\$kernel_source_dir/usr/include/." "\$kernel_headers_root/include/"
fi

rm -rf "\$glibc_build_dir" "\$selfhost_glibc_stage_root" "\$smoke_dir"
mkdir -p "\$glibc_build_dir" "\$selfhost_glibc_stage_root" "\$smoke_dir"
cd "\$glibc_build_dir"

export PATH="\$intermediate_root/bin:\$stage1_bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="\$sdk_root/bin:\$PATH"
export CONFIG_SHELL=/bin/bash
export BUILD_CC="/usr/bin/gcc -B\$stage1_bin"
export CC="\$intermediate_gcc"
export AR="\$stage1_bin/aarch64-linux-gnu-ar"
export AS="\$stage1_bin/aarch64-linux-gnu-as"
export LD="\$stage1_bin/aarch64-linux-gnu-ld"
export RANLIB="\$stage1_bin/aarch64-linux-gnu-ranlib"
export LD_LIBRARY_PATH="\$intermediate_root/lib64:\$intermediate_root/lib:\$stage1_root/lib64:\$stage1_root/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

libc_cv_slibdir=/lib \
"\$glibc_source_dir/configure" \
  --prefix=/usr \
  --host=aarch64-linux-gnu \
  --build=aarch64-linux-gnu \
  --with-binutils="\$stage1_bin" \
  --with-headers="\$kernel_headers_root/include" \
  --enable-kernel="\$glibc_enable_kernel" \
  --disable-werror

make -j"\$build_jobs"
make install install_root="\$selfhost_glibc_stage_root"
cp -a "\$kernel_headers_root/include/." "\$selfhost_glibc_stage_root/usr/include/"

cat >"\$smoke_dir/hello.c" <<'SRC'
#include <stdio.h>

int main(void) {
  puts("selfhost-glibc-ok");
  return 0;
}
SRC

LD_LIBRARY_PATH="\$intermediate_root/lib64:\$intermediate_root/lib:\$stage1_root/lib64:\$stage1_root/lib" \
  "\$intermediate_driver" -B"\$stage1_bin" --sysroot="\$selfhost_glibc_stage_root" "\$smoke_dir/hello.c" -o "\$smoke_dir/hello"
"\$selfhost_glibc_stage_root/lib/ld-linux-aarch64.so.1" \
  --library-path "\$selfhost_glibc_stage_root/lib:\$selfhost_glibc_stage_root/usr/lib:\$intermediate_root/lib64:\$intermediate_root/lib:\$stage1_root/lib64:\$stage1_root/lib" \
  "\$smoke_dir/hello"
/usr/bin/file "\$selfhost_glibc_stage_root/lib/libc.so.6"
EOF

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$SOURCE_ROOT'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_GLIBC_ARCHIVE_PATH" "$SOURCE_ROOT/$GLIBC_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_LINUX_ARCHIVE_PATH" "$SOURCE_ROOT/$LINUX_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$guest_script" /tmp/build-selfhost-glibc.sh
"$ROOT_DIR/scripts/ssh-guest.sh" "bash /tmp/build-selfhost-glibc.sh"
