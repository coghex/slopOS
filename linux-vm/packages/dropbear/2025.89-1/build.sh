#!/bin/bash
set -euo pipefail
programs="dropbear dbclient dropbearkey dropbearconvert scp"
cd "$PKG_BUILD_DIR"
export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/local/include"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/local/lib"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
cat >"$PKG_BUILD_DIR/localoptions.h" <<'EOF_LOCALOPTIONS'
#if !HAVE_CRYPT
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#endif
EOF_LOCALOPTIONS
"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --disable-harden \
  --disable-lastlog \
  --disable-utmp \
  --disable-utmpx \
  --disable-wtmp \
  --disable-wtmpx \
  --enable-bundled-libtom
make -j"$BUILD_JOBS" MULTI=1 SCPPROGRESS=1 PROGRAMS="$programs"
make DESTDIR="$PKG_DESTDIR" MULTI=1 SCPPROGRESS=1 PROGRAMS="$programs" install
