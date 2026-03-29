#!/bin/bash
set -euo pipefail
: "${SELFHOST_STAGE1_ROOT:?}"
: "${SELFHOST_STAGE2_ROOT:?}"
: "${SELFHOST_SDK_ROOT:?}"
: "${SELFHOST_GLIBC_STAGE_ROOT:?}"
: "${SELFHOST_DISTFILES_ROOT:?}"
stage1_root="$SELFHOST_STAGE1_ROOT"
stage2_root="$SELFHOST_STAGE2_ROOT"
sdk_root="$SELFHOST_SDK_ROOT"
glibc_stage_root="$SELFHOST_GLIBC_STAGE_ROOT"
glibc_stage_dest="$PKG_DESTDIR$glibc_stage_root"
stage1_bin="$stage1_root/bin"
stage2_gcc="$stage2_root/bin/selfhost-gcc"
stage2_driver="$stage2_root/bin/aarch64-linux-gnu-gcc"
sdk_cc="$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc -B$stage1_bin"
build_dir="$PKG_BUILD_DIR/glibc"
kernel_headers_root="$PKG_BUILD_DIR/kernel-headers"
linux_source_dir="$PKG_BUILD_DIR/linux-6.18.7"
linux_archive="$SELFHOST_DISTFILES_ROOT/linux-6.18.7.tar.xz"
rm -rf "$build_dir" "$kernel_headers_root" "$linux_source_dir"
mkdir -p "$build_dir" "$kernel_headers_root" "$glibc_stage_dest"
if [[ ! -f "$linux_archive" ]]; then
  echo "Missing cached Linux archive: $linux_archive" >&2
  exit 1
fi
tar -xf "$linux_archive" -C "$PKG_BUILD_DIR"
make -C "$linux_source_dir" ARCH=arm64 HOSTCC="$sdk_cc" headers_install INSTALL_HDR_PATH="$kernel_headers_root"
cd "$build_dir"
export PATH="$sdk_root/bin:$stage2_root/bin:$stage1_bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CONFIG_SHELL=/bin/bash
export BUILD_CC="$sdk_cc"
export CC="$stage2_gcc"
export AR="$stage1_bin/aarch64-linux-gnu-ar"
export AS="$stage1_bin/aarch64-linux-gnu-as"
export LD="$stage1_bin/aarch64-linux-gnu-ld"
export RANLIB="$stage1_bin/aarch64-linux-gnu-ranlib"
export LD_LIBRARY_PATH="$stage2_root/lib64:$stage2_root/lib:$stage1_root/lib64:$stage1_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
libc_cv_slibdir=/lib "$PKG_SOURCE_DIR/configure" --prefix=/usr --host=aarch64-linux-gnu --build=aarch64-linux-gnu --with-binutils="$stage1_bin" --with-headers="$kernel_headers_root/include" --enable-kernel=6.18.0 --disable-werror
make -j"$BUILD_JOBS"
make install install_root="$glibc_stage_dest"
cp -a "$kernel_headers_root/include/." "$glibc_stage_dest/usr/include/"
cat >"$PKG_BUILD_DIR/hello.c" <<'SRC'
#include <stdio.h>
int main(void) { puts("selfhost-glibc-package"); return 0; }
SRC
LD_LIBRARY_PATH="$stage2_root/lib64:$stage2_root/lib:$stage1_root/lib64:$stage1_root/lib" "$stage2_driver" -B"$stage1_bin" --sysroot="$glibc_stage_dest" "$PKG_BUILD_DIR/hello.c" -o "$PKG_BUILD_DIR/hello"
"$glibc_stage_dest/lib/ld-linux-aarch64.so.1" --library-path "$glibc_stage_dest/lib:$glibc_stage_dest/usr/lib:$stage2_root/lib64:$stage2_root/lib:$stage1_root/lib64:$stage1_root/lib" "$PKG_BUILD_DIR/hello" >/dev/null
