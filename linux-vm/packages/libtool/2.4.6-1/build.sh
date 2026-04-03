#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MAKEINFO=true

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --enable-ltdl-install

python3 - <<'PY'
import re
from pathlib import Path

libtool_path = Path("libtool")
lines = libtool_path.read_text().splitlines()
patched = []
skip = False
for line in lines:
    if line == 'old_archive_cmds="$AR $AR_FLAGS $oldlib$oldobjs~$RANLIB $tool_oldlib"':
        patched.append('old_archive_cmds="\\$AR \\$AR_FLAGS \\$oldlib\\$oldobjs~\\$RANLIB \\$tool_oldlib"')
        continue
    if line == 'archive_cmds="$CC -shared $pic_flag $libobjs $deplibs $compiler_flags $wl-soname $wl$soname -o $lib"':
        patched.append('archive_cmds="\\$CC -shared \\$pic_flag \\$libobjs \\$deplibs \\$compiler_flags \\$wl-soname \\$wl\\$soname -o \\$lib"')
        continue
    if line == 'archive_cmds="$CC $pic_flag -shared -nostdlib $predep_objects $libobjs $deplibs $postdep_objects $compiler_flags $wl-soname $wl$soname -o $lib"':
        patched.append('archive_cmds="\\$CC \\$pic_flag -shared -nostdlib \\$predep_objects \\$libobjs \\$deplibs \\$postdep_objects \\$compiler_flags \\$wl-soname \\$wl\\$soname -o \\$lib"')
        continue
    if line == 'old_postinstall_cmds="chmod 644 $oldlib~$RANLIB $tool_oldlib"':
        patched.append('old_postinstall_cmds="chmod 644 \\$oldlib~\\$RANLIB \\$tool_oldlib"')
        continue
    if line == 'finish_cmds="PATH="\\$PATH:/sbin" ldconfig -n $libdir"':
        patched.append('finish_cmds="PATH=\\"\\$PATH:/sbin\\" ldconfig -n \\$libdir"')
        continue
    if line == 'shift' and patched[-1:] == ['realname=$1']:
        patched.append('test $# -gt 0 && shift')
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
text = libtool_path.read_text()
text = re.sub(r"(realname=\$1\n[ \t]*)shift\n", r"\1test $# -gt 0 && shift\n", text)
text = text.replace(
    'eval library_names=\\"$library_names_spec\\"\n\tset dummy $library_names\n',
    'eval library_names=\\"$library_names_spec\\"\n\t'
    'case "$library_names" in\n\t'
    '  ""|" ")\n\t'
    '    test "$libname" != "lib" || libname="lib$name"\n\t'
    '    library_names="$libname$release$shared_ext$versuffix $libname$release$shared_ext$major $libname$shared_ext"\n\t'
    '    ;;\n\t'
    'esac\n\t'
    'set dummy $library_names\n',
)
text = text.replace(
    """    func_show_eval '(cd "$output_objdir" && $RM "$linkname" && $LN_S "$realname" "$linkname")' 'exit $?'\n""",
    """    func_show_eval "$RM \\"$output_objdir/$linkname\\" && $LN_S \\"$realname\\" \\"$output_objdir/$linkname\\"" 'exit $?'\n""",
)
text = text.replace(
    """  func_show_eval '( cd "$output_objdir" && $RM "$outputname" && $LN_S "../$outputname" "$outputname" )' 'exit $?'\n""",
    """  func_show_eval "$RM \\"$output_objdir/$outputname\\" && $LN_S \\"../$outputname\\" \\"$output_objdir/$outputname\\"" 'exit $?'\n""",
)
text = text.replace(
    """\t\t&& func_show_eval "(cd $destdir && { $LN_S -f $realname $linkname || { $RM $linkname && $LN_S $realname $linkname; }; })"\n""",
    """\t\t&& func_show_eval "$RM \\"$destdir/$linkname\\" && $LN_S \\"$realname\\" \\"$destdir/$linkname\\""\n""",
)
libtool_path.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

for makefile in Path(".").rglob("Makefile"):
    text = makefile.read_text()
    old = "-DLT_CONFIG_H='<$(LT_CONFIG_H)>'"
    new = '-DLT_CONFIG_H=\\"$(LT_CONFIG_H)\\"'
    if old in text:
        text = text.replace(old, new)
    text = text.replace("LT_DLLOADERS =  libltdl/dlopen.la", "LT_DLLOADERS =")
    text = text.replace("LT_DLPREOPEN = -dlpreopen libltdl/dlopen.la ", "LT_DLPREOPEN =")
    makefile.write_text(text)
PY

python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["PKG_SOURCE_DIR"]) / "libltdl"
paths = [
    root / "lt__argz.c",
    root / "libltdl" / "lt__private.h",
    root / "libltdl" / "lt__dirent.h",
    root / "libltdl" / "lt__strl.h",
    root / "libltdl" / "lt__glibc.h",
]
for path in paths:
    text = path.read_text()
    old = '#if defined LT_CONFIG_H\n#  include LT_CONFIG_H\n#else\n#  include <config.h>\n#endif'
    new = '#include "config.h"'
    if old in text:
        path.write_text(text.replace(old, new))
PY

mkdir -p "$PKG_BUILD_DIR/libltdl/libltdl"
cp "$PKG_SOURCE_DIR/libltdl/libltdl/lt__argz_.h" \
  "$PKG_BUILD_DIR/libltdl/libltdl/lt__argz.h"

make -j"$BUILD_JOBS"
if [[ -f libltdl/.libs/lib.a && ! -f libltdl/.libs/libltdl.a ]]; then
  cp libltdl/.libs/lib.a libltdl/.libs/libltdl.a
fi
mkdir -p \
  "$PKG_DESTDIR$PREFIX/share/aclocal" \
  "$PKG_DESTDIR$PREFIX/share/libtool/build-aux" \
  "$PKG_DESTDIR$PREFIX/share/libtool/libltdl" \
  "$PKG_DESTDIR$PREFIX/share/info" \
  "$PKG_DESTDIR$PREFIX/share/man/man1" \
  "$PKG_DESTDIR$PREFIX/include/libltdl"
make SHELL=/bin/bash DESTDIR="$PKG_DESTDIR" install
