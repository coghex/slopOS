#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_SOURCE_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/local/include"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/local/lib"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --without-liblua \
  --without-zenmap \
  --with-libdnet=included \
  --without-libssh2 \
  --with-openssl="$PREFIX" \
  --with-libz="$PREFIX" \
  --with-libpcre="$PREFIX" \
  --without-ncat \
  --without-nping

python3 - <<'PY'
from pathlib import Path

libtool_path = Path("libdnet-stripped/libtool")
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
    if line == '\teval library_names=\\"$library_names_spec\\"':
        patched.append(line)
        patched.append('\tcase $library_names in')
        patched.append('\t  *[![:space:]]*) ;;')
        patched.append('\t  *)')
        patched.append('\t    library_names="$libname$release$shared_ext $libname$shared_ext"')
        patched.append('\t    ;;')
        patched.append('\tesac')
        continue
    if line == '\trealname=$1':
        patched.append(line)
        patched.append('\tcase $realname in')
        patched.append('\t  *[![:space:]]*) ;;')
        patched.append('\t  *) realname="${output%.la}${release}${shared_ext}" ;;')
        patched.append('\tesac')
        continue
    if line == '\tlib=$output_objdir/$realname':
        patched.append('\tcase $output_objdir in')
        patched.append('\t  *[![:space:]]*) ;;')
        patched.append('\t  *) output_objdir=.libs ;;')
        patched.append('\tesac')
        patched.append(line)
        continue
    patched.append(line)

libtool_path.write_text("\n".join(patched) + "\n")
PY

make -j"$BUILD_JOBS" nmap
make DESTDIR="$PKG_DESTDIR" install-nmap
