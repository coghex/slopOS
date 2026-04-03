#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --disable-shared \
  --enable-static

python3 - <<'PY'
from pathlib import Path

libtool_path = Path("libtool")
lines = libtool_path.read_text().splitlines()
patched = []
skip = False
for line in lines:
    if line == 'old_archive_cmds="$AR $AR_FLAGS $oldlib$oldobjs~$RANLIB $tool_oldlib"':
        patched.append('old_archive_cmds="\\$AR \\$AR_FLAGS \\$oldlib\\$oldobjs~\\$RANLIB \\$tool_oldlib"')
        continue
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

make -C src -j"$BUILD_JOBS" libmain.lo libyywrap.lo stage1flex flex

mkdir -p "$PKG_BUILD_DIR/src/.libs"
rm -f "$PKG_BUILD_DIR/src/.libs/libfl.a"
ar cr "$PKG_BUILD_DIR/src/.libs/libfl.a" \
  "$PKG_BUILD_DIR/src/libmain.o" \
  "$PKG_BUILD_DIR/src/libyywrap.o"
ranlib "$PKG_BUILD_DIR/src/.libs/libfl.a"

install -Dm0755 "$PKG_BUILD_DIR/src/flex" "$PKG_DESTDIR/$PREFIX/bin/flex"
ln -sf flex "$PKG_DESTDIR/$PREFIX/bin/flex++"
install -Dm0644 "$PKG_BUILD_DIR/src/.libs/libfl.a" "$PKG_DESTDIR/$PREFIX/lib/libfl.a"
install -Dm0644 "$PKG_SOURCE_DIR/src/FlexLexer.h" "$PKG_DESTDIR/$PREFIX/include/FlexLexer.h"
install -Dm0644 "$PKG_SOURCE_DIR/doc/flex.1" "$PKG_DESTDIR/$PREFIX/share/man/man1/flex.1"
