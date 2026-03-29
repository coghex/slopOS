#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_SOURCE_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/local/include"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/local/lib"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --without-liblua \
  --without-zenmap \
  --with-libdnet=included \
  --without-libssh2 \
  --with-openssl="$PREFIX" \
  --with-libz="$PREFIX" \
  --with-libpcre="$PREFIX" \
  --without-ncat \
  --without-nping

make -j"$BUILD_JOBS" nmap
make DESTDIR="$PKG_DESTDIR" install-nmap
