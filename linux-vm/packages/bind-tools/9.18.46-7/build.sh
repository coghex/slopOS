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
    if line == 'library_names_spec="$libname$release$shared_ext$versuffix $libname$release$shared_ext$major $libname$shared_ext"':
        patched.append('library_names_spec="\\$libname\\$release\\$shared_ext\\$versuffix \\$libname\\$release\\$shared_ext\\$major \\$libname\\$shared_ext"')
        continue
    if line == 'soname_spec="$libname$release$shared_ext$major"':
        patched.append('soname_spec="\\$libname\\$release\\$shared_ext\\$major"')
        continue
    if line == 'archive_cmds="$CC -shared $pic_flag $libobjs $deplibs $compiler_flags $wl-soname $wl$soname -o $lib"':
        patched.append('archive_cmds="\\$CC -shared \\$pic_flag \\$libobjs \\$deplibs \\$compiler_flags \\$wl-soname \\$wl\\$soname -o \\$lib"')
        continue
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
        patched.append('\texpected_libname=${output%.la}')
        patched.append('\tcase $library_names in')
        patched.append('\t  "$expected_libname$release$shared_ext"*|"${expected_libname}$shared_ext"*) ;;')
        patched.append('\t  *)')
        patched.append('\t    library_names="$expected_libname$release$shared_ext $expected_libname$shared_ext"')
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
    if line == '\t  eval soname=\\"$soname_spec\\"':
        patched.append(line)
        patched.append('\t  case $soname in')
        patched.append('\t    *[![:space:]]*) ;;')
        patched.append('\t    *) soname=$realname ;;')
        patched.append('\t  esac')
        continue
    if line == '\tlib=$output_objdir/$realname':
        patched.append('\tcase $output_objdir in')
        patched.append('\t  *[![:space:]]*) ;;')
        patched.append('\t  *) output_objdir=.libs ;;')
        patched.append('\tesac')
        patched.append(line)
        patched.append('\tcase $lib in')
        patched.append('\t  *[![:space:]]*) ;;')
        patched.append('\t  *) lib=$output_objdir/$realname ;;')
        patched.append('\tesac')
        continue
    if line == '\t    func_show_eval \'(cd "$output_objdir" && $RM "$linkname" && $LN_S "$realname" "$linkname")\' \'exit $?\'': 
        patched.append('\t    $opt_dry_run || (cd "$output_objdir" && $RM "$linkname" && $LN_S "$realname" "$linkname") || exit $?')
        continue
    patched.append(line)

libtool_path.write_text("\n".join(patched) + "\n")
PY

make -j"$BUILD_JOBS"
make DESTDIR="$PKG_DESTDIR" install

rm -rf "$PKG_DESTDIR/$PREFIX/sbin" "$PKG_DESTDIR/$PREFIX/etc"
rm -rf "$PKG_DESTDIR/$PREFIX/share/man/man8"
