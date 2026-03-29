#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/local/include"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/local/lib"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

(cd "$PKG_SOURCE_DIR" && autoreconf -fi)

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

python3 - <<'PY'
from pathlib import Path

libtool_path = Path("libtool")
lines = libtool_path.read_text().splitlines()
patched = []
skip = False
for line in lines:
    if line.startswith('archive_expsym_cmds="echo "{ global:"'):
        patched.append('archive_expsym_cmds=""')
        skip = True
        continue
    if skip:
        if line.endswith('-o $lib"'):
            skip = False
        continue
    patched.append(line)

libtool_path.write_text("\n".join(patched) + "\n")
PY

make -j"$BUILD_JOBS"
make DESTDIR="$PKG_DESTDIR" install

rm -rf "$PKG_DESTDIR/$PREFIX/sbin" "$PKG_DESTDIR/$PREFIX/etc"
rm -rf "$PKG_DESTDIR/$PREFIX/share/man/man8"
