#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

./configure --prefix="$PREFIX" --libbpf_force off
echo 'TC_CONFIG_XT:=n' >> config.mk

make -j"$BUILD_JOBS" V=1 LIBDB_LIBS=-lpthread SHARED_LIBS=y

make \
  DESTDIR="$PKG_DESTDIR" \
  PREFIX="$PREFIX" \
  SBINDIR="$PREFIX/bin" \
  LIBDIR="$PREFIX/lib" \
  CONFDIR="$PREFIX/etc" \
  install
