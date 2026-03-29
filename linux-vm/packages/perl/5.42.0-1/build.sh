#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_SOURCE_DIR"

version="${PKG_VERSION%-*}"
archname="$(uname -m)-linux"
privlib="$PREFIX/lib/perl5/$version"
archlib="$privlib/$archname"
sitelib="$PREFIX/lib/perl5/site_perl/$version"
sitearch="$sitelib/$archname"
vendorlib="$PREFIX/lib/perl5/vendor_perl/$version"
vendorarch="$vendorlib/$archname"

./Configure -des \
  -Dprefix="$PREFIX" \
  -Dsiteprefix="$PREFIX" \
  -Dvendorprefix="$PREFIX" \
  -Dprivlib="$privlib" \
  -Darchlib="$archlib" \
  -Dsitelib="$sitelib" \
  -Dsitearch="$sitearch" \
  -Dvendorlib="$vendorlib" \
  -Dvendorarch="$vendorarch" \
  -Dman1dir="$PREFIX/share/man/man1" \
  -Dman3dir="$PREFIX/share/man/man3" \
  -Dscriptdir="$PREFIX/bin" \
  -Dcc="gcc" \
  -Dld="gcc" \
  -Dccflags="-I/usr/local/include" \
  -Dldflags="-L/usr/local/lib" \
  -Dlibpth="/lib /usr/lib /usr/local/lib" \
  -Dglibpth="/lib /usr/lib /usr/local/lib" \
  -Dlibs="-lm -lpthread -ldl -lutil -lc"

make -j"$BUILD_JOBS"
make DESTDIR="$PKG_DESTDIR" install
