#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"

make -j"$BUILD_JOBS" CFLAGS="${CFLAGS:+$CFLAGS }-fPIC" lib

install -Dm0644 linear.h "$PKG_DESTDIR/$PREFIX/include/linear.h"
install -Dm0644 liblinear.so.6 "$PKG_DESTDIR/$PREFIX/lib/liblinear.so.6"
ln -sf liblinear.so.6 "$PKG_DESTDIR/$PREFIX/lib/liblinear.so"
