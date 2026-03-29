#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/local/include"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/local/lib"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --without-cmocka \
  --without-lmdb \
  --disable-doh \
  --disable-static \
  --with-openssl="$PREFIX" \
  --with-zlib \
  --without-jemalloc \
  --without-json-c \
  --disable-linux-caps \
  --without-libidn2 \
  --with-gssapi=no \
  --disable-geoip \
  --with-libxml2=no \
  --with-readline=no

make -j"$BUILD_JOBS"
make DESTDIR="$PKG_DESTDIR" install

rm -rf "$PKG_DESTDIR/$PREFIX/sbin" "$PKG_DESTDIR/$PREFIX/etc"
rm -rf "$PKG_DESTDIR/$PREFIX/share/man/man8"
