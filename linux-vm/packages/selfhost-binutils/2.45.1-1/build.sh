#!/bin/bash
set -euo pipefail
: "${SELFHOST_STAGE1_ROOT:?}"
: "${SELFHOST_SDK_ROOT:?}"
stage1_root="$SELFHOST_STAGE1_ROOT"
sdk_root="$SELFHOST_SDK_ROOT"
sdk_cc="$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc"
build_dir="$PKG_BUILD_DIR/binutils"
rm -rf "$build_dir"
mkdir -p "$build_dir"
cd "$build_dir"
export PATH="$sdk_root/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC="$sdk_cc"
export CXX="$sdk_root/bin/aarch64-buildroot-linux-gnu-g++"
export CPPFLAGS="-I$stage1_root/include"
export LDFLAGS="-L$stage1_root/lib -L$stage1_root/lib64"
export LD_LIBRARY_PATH="$stage1_root/lib:$stage1_root/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$PKG_SOURCE_DIR/configure" --prefix="$stage1_root" --target=aarch64-linux-gnu --disable-gprofng --disable-nls --disable-werror --with-sysroot=/
make -j"$BUILD_JOBS"
make install DESTDIR="$PKG_DESTDIR"
for dir in "$PKG_DESTDIR/usr/bin" "$PKG_DESTDIR/usr/local/bin"; do
  mkdir -p "$dir"
  for tool in ar as ld ranlib nm objcopy objdump readelf strip; do
    ln -sf "$stage1_root/bin/aarch64-linux-gnu-$tool" "$dir/aarch64-linux-gnu-$tool"
  done
done
