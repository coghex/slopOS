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
import os
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
    if 'func_show_eval' in line and '$output_objdir' in line and '$LN_S "$realname" "$linkname"' in line:
        patched.append('\t    $opt_dry_run || (cd "$output_objdir" && $RM "$linkname" && $LN_S "$realname" "$linkname") || exit $?')
        continue
    if 'func_show_eval' in line and '$output_objdir' in line and '$LN_S "../$outputname" "$outputname"' in line:
        patched.append('\t  $opt_dry_run || ( cd "$output_objdir" && $RM "$outputname" && $LN_S "../$outputname" "$outputname" ) || exit $?')
        continue
    patched.append(line)

libtool_path.write_text("\n".join(patched) + "\n")

for generated_path in Path(".").rglob("Makefile"):
    content = generated_path.read_text()
    content = content.replace(
        '-DNAMED_PLUGINDIR=\\"$(pkglibdir)\\"',
        '-DNAMED_PLUGINDIR=\\\\\\"$(pkglibdir)\\\\\\"',
    )
    generated_path.write_text(content)

hooks_path = Path(os.environ["PKG_SOURCE_DIR"]) / "lib/ns/hooks.c"
hooks_content = hooks_path.read_text()
needle = "#include <string.h>\n"
replacement = '#include <string.h>\n#undef NAMED_PLUGINDIR\n#define NAMED_PLUGINDIR "/usr/local/lib/bind"\n'
if replacement not in hooks_content:
    if needle not in hooks_content:
        raise SystemExit("expected hooks.c include block not found")
    hooks_content = hooks_content.replace(needle, replacement, 1)
    hooks_path.write_text(hooks_content)
PY

make -j"$BUILD_JOBS" -C lib all
make -j"$BUILD_JOBS" -C bin/dig all
make -j"$BUILD_JOBS" -C bin/nsupdate all

mkdir -p "$PKG_DESTDIR/$PREFIX/bin" "$PKG_DESTDIR/$PREFIX/lib"

while IFS= read -r -d '' lib_path; do
    install_dir="$PKG_DESTDIR/$PREFIX/lib"
    if [ -L "$lib_path" ]; then
        cp -a "$lib_path" "$install_dir/"
    else
        install -Dm0755 "$lib_path" "$install_dir/$(basename "$lib_path")"
    fi
done < <(find "$PKG_BUILD_DIR/lib" -path '*/.libs/lib*.so*' \( -type f -o -type l \) -print0)

install -Dm0755 "$PKG_BUILD_DIR/bin/dig/.libs/dig" "$PKG_DESTDIR/$PREFIX/bin/dig"
install -Dm0755 "$PKG_BUILD_DIR/bin/dig/.libs/host" "$PKG_DESTDIR/$PREFIX/bin/host"
install -Dm0755 "$PKG_BUILD_DIR/bin/dig/.libs/nslookup" "$PKG_DESTDIR/$PREFIX/bin/nslookup"
install -Dm0755 "$PKG_BUILD_DIR/bin/nsupdate/.libs/nsupdate" "$PKG_DESTDIR/$PREFIX/bin/nsupdate"

rm -rf "$PKG_DESTDIR/$PREFIX/sbin" "$PKG_DESTDIR/$PREFIX/etc"
rm -rf "$PKG_DESTDIR/$PREFIX/share/man/man8"
