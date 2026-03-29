#!/usr/bin/env bash
set -euo pipefail

python3 - "$PKG_SOURCE_DIR/Makefile.in" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old_all = "all-am: Makefile $(INFO_DEPS) $(SCRIPTS) $(MANS) $(DATA)"
new_all = "all-am: Makefile $(INFO_DEPS) $(SCRIPTS) $(DATA)"
old_install = "install-info-am install-man install-nodist_perllibDATA"
new_install = "install-info-am install-nodist_perllibDATA"

if old_all not in text or old_install not in text:
    raise SystemExit("expected automake Makefile.in patterns not found")

text = text.replace(old_all, new_all)
text = text.replace(old_install, new_install)
path.write_text(text)
PY

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --sysconfdir="$SYSCONFDIR" \
  --localstatedir="$LOCALSTATEDIR"

make -j"$BUILD_JOBS"
make DESTDIR="$PKG_DESTDIR" install

install -Dm0644 "$PKG_SOURCE_DIR/support/gtk-doc.m4" \
  "$PKG_DESTDIR/usr/local/share/aclocal/gtk-doc.m4"
