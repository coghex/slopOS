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
  --disable-shared \
  --enable-static \
  --disable-jit

python3 - <<'PY'
import re
import shlex
import subprocess
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

database = subprocess.check_output(["make", "-pn"], text=True)
variables = {}
for line in database.splitlines():
    match = re.match(r"^(am(?:__objects_\d+|_libpcre2_8_la_OBJECTS|_libpcre2_posix_la_OBJECTS)|nodist_libpcre2_8_la_OBJECTS) = (.*)$", line)
    if match:
        variables[match.group(1)] = match.group(2)

def expand(text: str) -> str:
    pattern = re.compile(r"\$\((am__objects_\d+|nodist_libpcre2_8_la_OBJECTS)\)")
    while True:
        new_text = pattern.sub(lambda m: expand(variables.get(m.group(1), "")), text)
        if new_text == text:
            return " ".join(new_text.split())
        text = new_text

libpcre2_8_targets = expand(variables["am_libpcre2_8_la_OBJECTS"])
libpcre2_8_targets = expand(f"{libpcre2_8_targets} {variables.get('nodist_libpcre2_8_la_OBJECTS', '')}").split()
libpcre2_posix_targets = expand(variables["am_libpcre2_posix_la_OBJECTS"]).split()

Path(".pcre2-targets").write_text(
    "\n".join([
        "LIBPCRE2_8_TARGETS=" + shlex.quote(" ".join(libpcre2_8_targets)),
        "LIBPCRE2_POSIX_TARGETS=" + shlex.quote(" ".join(libpcre2_posix_targets)),
    ]) + "\n"
)
PY

source ./.pcre2-targets
make -j"$BUILD_JOBS" $LIBPCRE2_8_TARGETS $LIBPCRE2_POSIX_TARGETS

libpcre2_8_objects=()
for target in $LIBPCRE2_8_TARGETS; do
  libpcre2_8_objects+=("${target%.lo}.o")
done

libpcre2_posix_objects=()
for target in $LIBPCRE2_POSIX_TARGETS; do
  libpcre2_posix_objects+=("${target%.lo}.o")
done

mkdir -p "$PKG_DESTDIR/$PREFIX/lib/pkgconfig" "$PKG_DESTDIR/$PREFIX/include"
ar cr "$PKG_BUILD_DIR/libpcre2-8.a" "${libpcre2_8_objects[@]}"
ranlib "$PKG_BUILD_DIR/libpcre2-8.a"
ar cr "$PKG_BUILD_DIR/libpcre2-posix.a" "${libpcre2_posix_objects[@]}"
ranlib "$PKG_BUILD_DIR/libpcre2-posix.a"

install -Dm0644 "$PKG_BUILD_DIR/libpcre2-8.a" "$PKG_DESTDIR/$PREFIX/lib/libpcre2-8.a"
install -Dm0644 "$PKG_BUILD_DIR/libpcre2-posix.a" "$PKG_DESTDIR/$PREFIX/lib/libpcre2-posix.a"
install -Dm0644 "$PKG_BUILD_DIR/libpcre2-8.pc" "$PKG_DESTDIR/$PREFIX/lib/pkgconfig/libpcre2-8.pc"
install -Dm0644 "$PKG_BUILD_DIR/libpcre2-posix.pc" "$PKG_DESTDIR/$PREFIX/lib/pkgconfig/libpcre2-posix.pc"
install -Dm0755 "$PKG_BUILD_DIR/pcre2-config" "$PKG_DESTDIR/$PREFIX/bin/pcre2-config"
install -Dm0644 "$PKG_BUILD_DIR/src/pcre2.h" "$PKG_DESTDIR/$PREFIX/include/pcre2.h"
install -Dm0644 "$PKG_SOURCE_DIR/src/pcre2posix.h" "$PKG_DESTDIR/$PREFIX/include/pcre2posix.h"
