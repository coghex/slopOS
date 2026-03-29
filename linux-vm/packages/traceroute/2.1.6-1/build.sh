#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
sed -i 's/^LIBDEPS = $(filter-out -L%,$(LIBS))$/LIBDEPS = $(filter-out -L% -l%,$(LIBS))/' Make.rules
make -j"$BUILD_JOBS" SKIPDIRS='tmp% support' CFLAGS="${CFLAGS:+$CFLAGS }-D_GNU_SOURCE"
make DESTDIR="$PKG_DESTDIR" prefix="$PREFIX" INSTALL="install -C" SKIPDIRS='tmp% support' install
