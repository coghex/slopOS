#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

(cd "$PKG_SOURCE_DIR" && autoreconf -fi)

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --enable-pcre2-8 \
  --disable-pcre2-16 \
  --disable-pcre2-32 \
  --disable-jit

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
