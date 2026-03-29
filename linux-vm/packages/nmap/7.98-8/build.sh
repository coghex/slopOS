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
    patched.append(line)

libtool_path.write_text("\n".join(patched) + "\n")
PY

python3 - <<'PY'
import re
import shlex
import subprocess
from pathlib import Path

makefile_dir = Path("libdnet-stripped/src")
database = subprocess.check_output(["make", "-pn"], cwd=makefile_dir, text=True)
variables = {}
for line in database.splitlines():
    match = re.match(r"^(am(?:__objects_\d+|_libdnet_la_OBJECTS)|libdnet_la_OBJECTS) = (.*)$", line)
    if match:
        variables[match.group(1)] = match.group(2)

def expand(text: str) -> str:
    pattern = re.compile(r"\$\((am__objects_\d+|am_libdnet_la_OBJECTS)\)")
    while True:
        new_text = pattern.sub(lambda m: expand(variables.get(m.group(1), "")), text)
        if new_text == text:
            return " ".join(new_text.split())
        text = new_text

targets = expand(variables["libdnet_la_OBJECTS"]).split()
Path("libdnet-stripped/.libdnet-targets").write_text(
    "LIBDNET_TARGETS=" + shlex.quote(" ".join(targets)) + "\n"
)
PY

cat > libdnet-stripped/build-static-libdnet.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.libdnet-targets
cd src
make $LIBDNET_TARGETS

objects=()
for target in $LIBDNET_TARGETS; do
  base="${target%.lo}"
  objects+=(".libs/${base}.o")
done

mkdir -p .libs
rm -f .libs/libdnet.a
ar cr .libs/libdnet.a "${objects[@]}"
ranlib .libs/libdnet.a
EOF
chmod +x libdnet-stripped/build-static-libdnet.sh

python3 - <<'PY'
from pathlib import Path

makefile_path = Path("Makefile")
content = makefile_path.read_text()
old = '\t@echo Compiling libdnet; cd $(LIBDNETDIR) && $(MAKE)\n'
new = '\t@echo Compiling libdnet; cd $(LIBDNETDIR) && ./build-static-libdnet.sh\n'
if old not in content:
    raise SystemExit("expected build-dnet recipe not found")
makefile_path.write_text(content.replace(old, new, 1))
PY

make -j"$BUILD_JOBS" nmap
make DESTDIR="$PKG_DESTDIR" install-nmap
