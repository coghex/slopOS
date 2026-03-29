#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

meson setup build "$PKG_SOURCE_DIR" \
  --prefix="$PREFIX" \
  --buildtype=release \
  -DBUILD_PING=true \
  -DBUILD_ARPING=false \
  -DBUILD_TRACEPATH=false \
  -DBUILD_CLOCKDIFF=false \
  -DUSE_CAP=false \
  -DUSE_IDN=false \
  -DUSE_GETTEXT=false \
  -DBUILD_MANS=false \
  -DBUILD_HTML_MANS=false

ninja -C build -j"$BUILD_JOBS"
DESTDIR="$PKG_DESTDIR" /usr/local/bin/meson install -C build --no-rebuild
ln -sf ping "$PKG_DESTDIR/$PREFIX/bin/ping6"
