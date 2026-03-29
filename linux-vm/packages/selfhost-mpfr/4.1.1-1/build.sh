#!/bin/bash
set -euo pipefail
: "${SELFHOST_STAGE1_ROOT:?}"
: "${SELFHOST_SDK_ROOT:?}"
stage1_root="$SELFHOST_STAGE1_ROOT"
build_dir="$PKG_BUILD_DIR/mpfr"
rm -rf "$build_dir"
mkdir -p "$build_dir"
cd "$build_dir"
export PATH="$SELFHOST_SDK_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LD_LIBRARY_PATH="$stage1_root/lib:$stage1_root/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$PKG_SOURCE_DIR/configure" --prefix="$stage1_root" --with-gmp="$stage1_root"
make -j"$BUILD_JOBS"
make install DESTDIR="$PKG_DESTDIR"
