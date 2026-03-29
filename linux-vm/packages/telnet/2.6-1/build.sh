#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/local/include"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/local/lib"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --disable-servers

make -j"$BUILD_JOBS"

install -Dm0755 telnet/telnet "$PKG_DESTDIR/$PREFIX/bin/telnet"
if [ -f "$PKG_SOURCE_DIR/telnet/telnet.1" ]; then
  install -Dm0644 "$PKG_SOURCE_DIR/telnet/telnet.1" \
    "$PKG_DESTDIR/$PREFIX/share/man/man1/telnet.1"
fi
