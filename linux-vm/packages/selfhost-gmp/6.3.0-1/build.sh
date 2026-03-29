#!/bin/bash
set -euo pipefail
: "${SELFHOST_STAGE1_ROOT:?}"
: "${SELFHOST_SDK_ROOT:?}"
stage1_root="$SELFHOST_STAGE1_ROOT"
build_dir="$PKG_BUILD_DIR/gmp"
rm -rf "$build_dir"
mkdir -p "$build_dir"
cd "$build_dir"
export PATH="$SELFHOST_SDK_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
"$PKG_SOURCE_DIR/configure" --prefix="$stage1_root" --enable-cxx
make -j"$BUILD_JOBS"
make install DESTDIR="$PKG_DESTDIR"
