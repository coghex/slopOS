#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --disable-shared \
  --enable-static
./config.status

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

for generated_path in (Path("Makefile"),):
    content = generated_path.read_text()
    content = content.replace("libuv\\ 1.52.1", "libuv-1.52.1")
    content = content.replace("libuv 1.52.1", "libuv-1.52.1")
    generated_path.write_text(content)
PY

object_targets="$(python3 - <<'PY'
import re
import subprocess

database = subprocess.check_output(["make", "-pn"], text=True)
variables = {}
for line in database.splitlines():
    match = re.match(r"^(am(?:__objects_\d+|_libuv_la_OBJECTS)) = (.*)$", line)
    if match:
        variables[match.group(1)] = match.group(2)

def expand(text: str) -> str:
    pattern = re.compile(r"\$\((am__objects_\d+)\)")
    while True:
        new_text = pattern.sub(lambda m: expand(variables.get(m.group(1), "")), text)
        if new_text == text:
            return " ".join(new_text.split())
        text = new_text

targets = expand(variables["am_libuv_la_OBJECTS"]).split()
print(" ".join(targets))
PY
)"

make -j"$BUILD_JOBS" $object_targets

object_files="$(python3 - <<'PY'
import re
import subprocess
from pathlib import Path

database = subprocess.check_output(["make", "-pn"], text=True)
variables = {}
for line in database.splitlines():
    match = re.match(r"^(am(?:__objects_\d+|_libuv_la_OBJECTS)) = (.*)$", line)
    if match:
        variables[match.group(1)] = match.group(2)

def expand(text: str) -> str:
    pattern = re.compile(r"\$\((am__objects_\d+)\)")
    while True:
        new_text = pattern.sub(lambda m: expand(variables.get(m.group(1), "")), text)
        if new_text == text:
            return " ".join(new_text.split())
        text = new_text

targets = expand(variables["am_libuv_la_OBJECTS"]).split()
for target in targets:
    path = Path(target)
    print(path.with_suffix(".o"))
PY
)"

mkdir -p "$PKG_BUILD_DIR/.libs" "$PKG_DESTDIR/$PREFIX/lib/pkgconfig" "$PKG_DESTDIR/$PREFIX/include/uv"
rm -f "$PKG_BUILD_DIR/.libs/libuv.a"
ar cr "$PKG_BUILD_DIR/.libs/libuv.a" $object_files
ranlib "$PKG_BUILD_DIR/.libs/libuv.a"

install -Dm0644 "$PKG_BUILD_DIR/.libs/libuv.a" "$PKG_DESTDIR/$PREFIX/lib/libuv.a"
install -Dm0644 "$PKG_BUILD_DIR/libuv.pc" "$PKG_DESTDIR/$PREFIX/lib/pkgconfig/libuv.pc"
install -Dm0644 "$PKG_SOURCE_DIR/include/uv.h" "$PKG_DESTDIR/$PREFIX/include/uv.h"
cp -R "$PKG_SOURCE_DIR/include/uv/." "$PKG_DESTDIR/$PREFIX/include/uv/"
