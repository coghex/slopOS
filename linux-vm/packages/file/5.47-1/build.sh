#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

(cd "$PKG_SOURCE_DIR" && autoreconf -fi)

python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["PKG_SOURCE_DIR"]) / "src/file.h"
text = path.read_text()
old = '#define MAGIC "/etc/magic"\n'
new = '#define MAGIC "/usr/local/share/misc/magic.mgc"\n'
if new not in text:
    if old not in text:
        raise SystemExit(f"expected MAGIC definition not found in {path}")
    path.write_text(text.replace(old, new, 1))
PY

python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["PKG_SOURCE_DIR"]) / "src/magic.c"
text = path.read_text()
old = '#include "magic.h"\n'
new = '#include "magic.h"\n\n#ifdef MAGIC\n#undef MAGIC\n#endif\n#define MAGIC "/usr/local/share/misc/magic.mgc"\n'
if new not in text:
    if old not in text:
        raise SystemExit(f"expected include anchor not found in {path}")
    path.write_text(text.replace(old, new, 1))
PY

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --sysconfdir="$SYSCONFDIR" \
  --localstatedir="$LOCALSTATEDIR" \
  --disable-shared \
  --enable-static \
  --disable-bzlib \
  --disable-libseccomp \
  --enable-zlib \
  --enable-xzlib

python3 - <<'PY'
from pathlib import Path

path = Path("src/Makefile")
text = path.read_text()
old = 'AM_CPPFLAGS = -DMAGIC=\'"$(MAGIC)"\''
new = 'AM_CPPFLAGS ='
if old not in text:
    raise SystemExit(f"expected AM_CPPFLAGS line not found in {path}")
path.write_text(text.replace(old, new, 1))
PY

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

python3 - <<'PY'
import re
import shlex
import subprocess
from pathlib import Path

database = subprocess.check_output(["make", "-C", "src", "-pn"], text=True)
variables: dict[str, str] = {}
for line in database.splitlines():
    match = re.match(
        r"^((?:am(?:__objects_\d+|_[A-Za-z0-9_]+_OBJECTS)|file_OBJECTS|LTLIBOBJS|LIBS)) = (.*)$",
        line,
    )
    if match:
        variables[match.group(1)] = match.group(2)

def expand(text: str) -> str:
    pattern = re.compile(r"\$\((am(?:__objects_\d+|_[A-Za-z0-9_]+_OBJECTS))\)")
    while True:
        new_text = pattern.sub(lambda m: expand(variables.get(m.group(1), "")), text)
        if new_text == text:
            return " ".join(new_text.split())
        text = new_text

def normalize(text: str) -> str:
    return (
        text.replace("$(OBJEXT)", "o")
        .replace("${OBJEXT}", "o")
        .replace("$(EXEEXT)", "")
        .replace("${EXEEXT}", "")
        .replace("$(LIBOBJDIR)", "")
        .replace("${LIBOBJDIR}", "")
        .replace("$U", "")
    )

libmagic_targets = normalize(expand(variables["am_libmagic_la_OBJECTS"])).split()
file_targets = normalize(expand(variables["file_OBJECTS"])).split()
ltlib_targets = normalize(variables.get("LTLIBOBJS", "")).split()
libs = variables.get("LIBS", "").strip()

Path(".file-targets").write_text(
    "\n".join(
        [
            "LIBMAGIC_TARGETS=" + shlex.quote(" ".join(libmagic_targets)),
            "FILE_TARGETS=" + shlex.quote(" ".join(file_targets)),
            "LTLIB_TARGETS=" + shlex.quote(" ".join(ltlib_targets)),
            "LIBS_FOR_FILE=" + shlex.quote(libs),
        ]
    )
    + "\n"
)
PY

source ./.file-targets

make -C src -j"$BUILD_JOBS" magic.h $LIBMAGIC_TARGETS $FILE_TARGETS $LTLIB_TARGETS

libmagic_objects=()
for target in $LIBMAGIC_TARGETS $LTLIB_TARGETS; do
  case "$target" in
    *.lo) libmagic_objects+=("src/${target%.lo}.o") ;;
    *) libmagic_objects+=("src/$target") ;;
  esac
done

file_objects=()
for target in $FILE_TARGETS; do
  case "$target" in
    *.lo) file_objects+=("src/${target%.lo}.o") ;;
    *) file_objects+=("src/$target") ;;
  esac
done

rm -f "$PKG_BUILD_DIR/libmagic.a"
ar cr "$PKG_BUILD_DIR/libmagic.a" "${libmagic_objects[@]}"
ranlib "$PKG_BUILD_DIR/libmagic.a"

gcc ${LDFLAGS:-} -o "$PKG_BUILD_DIR/src/file" "${file_objects[@]}" "$PKG_BUILD_DIR/libmagic.a" -lm $LIBS_FOR_FILE

make -j"$BUILD_JOBS" -C magic magic.mgc

mkdir -p \
  "$PKG_DESTDIR/$PREFIX/bin" \
  "$PKG_DESTDIR/$PREFIX/include" \
  "$PKG_DESTDIR/$PREFIX/lib/pkgconfig" \
  "$PKG_DESTDIR/$PREFIX/share/misc"

install -Dm0755 "$PKG_BUILD_DIR/src/file" "$PKG_DESTDIR/$PREFIX/bin/file"
install -Dm0644 "$PKG_BUILD_DIR/libmagic.a" "$PKG_DESTDIR/$PREFIX/lib/libmagic.a"
install -Dm0644 "$PKG_BUILD_DIR/src/magic.h" "$PKG_DESTDIR/$PREFIX/include/magic.h"
install -Dm0644 "$PKG_BUILD_DIR/libmagic.pc" "$PKG_DESTDIR/$PREFIX/lib/pkgconfig/libmagic.pc"
install -Dm0644 "$PKG_BUILD_DIR/magic/magic.mgc" "$PKG_DESTDIR/$PREFIX/share/misc/magic.mgc"
ln -snf magic.mgc "$PKG_DESTDIR/$PREFIX/share/misc/magic"
