#!/usr/bin/env bash
set -euo pipefail

python3 configure.py --bootstrap
install -Dm0755 ninja "$PKG_DESTDIR/usr/local/bin/ninja"
install -Dm0644 COPYING "$PKG_DESTDIR/usr/local/share/licenses/ninja/COPYING"
