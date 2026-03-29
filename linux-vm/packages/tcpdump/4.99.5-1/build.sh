#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/local/include"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/local/lib"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PCAP_CONFIG="$PREFIX/bin/pcap-config"
export ac_cv_linux_vers=2
export td_cv_buggygetaddrinfo=no

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --without-crypto \
  --disable-local-libpcap \
  --disable-smb

make -j"$BUILD_JOBS"
make DESTDIR="$PKG_DESTDIR" install
rm -f "$PKG_DESTDIR/$PREFIX/bin/tcpdump.$PKG_VERSION"
