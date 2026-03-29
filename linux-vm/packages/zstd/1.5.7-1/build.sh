#!/bin/bash
set -euo pipefail

cd "$PKG_SOURCE_DIR"

export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/local/include"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/local/lib"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

opts=(
  "PREFIX=$PREFIX"
  "ZSTD_LEGACY_SUPPORT=0"
  "HAVE_ZLIB=1"
  "HAVE_LZMA=1"
  "HAVE_LZ4=0"
  "HAVE_THREAD=1"
)

make -j"$BUILD_JOBS" "${opts[@]}" -C lib lib-release-mt
make -j"$BUILD_JOBS" "${opts[@]}" -C programs zstd-dll
make "${opts[@]}" DESTDIR="$PKG_DESTDIR" -C lib install-pc install-includes install-shared
make "${opts[@]}" DESTDIR="$PKG_DESTDIR" -C programs install
