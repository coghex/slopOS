#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_BUILD_DIR"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
mkdir -p "$PKG_BUILD_DIR/.tmp"
export TMPDIR="$PKG_BUILD_DIR/.tmp"
export SHELL="/usr/local/bin/bash"
export CONFIG_SHELL="/usr/local/bin/bash"

"$PKG_SOURCE_DIR/configure" \
  --prefix="$PREFIX" \
  --disable-asciidoc \
  --disable-makeinstall-chown \
  --disable-poman \
  --disable-rpath \
  --disable-year2038 \
  --disable-nls \
  --without-systemd \
  --with-systemdsystemunitdir=no \
  --without-udev \
  --without-ncurses \
  --without-ncursesw \
  --without-selinux \
  --without-audit \
  --without-readline \
  --without-libmagic \
  --without-python \
  --disable-pylibmount \
  --disable-liblastlog2 \
  --enable-agetty \
  --disable-chfn-chsh \
  --disable-chmem \
  --disable-ipcmk \
  --disable-kill \
  --disable-login \
  --disable-lsfd \
  --disable-lslogins \
  --disable-mesg \
  --disable-more \
  --disable-newgrp \
  --disable-nologin \
  --disable-nsenter \
  --disable-pg \
  --disable-rfkill \
  --disable-runuser \
  --disable-schedutils \
  --disable-setpriv \
  --disable-setterm \
  --disable-su \
  --disable-sulogin \
  --disable-tunelp \
  --disable-ul \
  --disable-unshare \
  --disable-uuidd \
  --disable-vipw \
  --disable-wall \
  --disable-wdctl \
  --disable-write \
  --disable-zramctl \
  --enable-libblkid \
  --enable-libmount \
  --enable-libuuid \
  --enable-blkid \
  --enable-mount \
  --enable-mountpoint

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
text = text.replace("/bin/sh", "/usr/local/bin/bash")
reexec_guard = 'if test -z "${BASH_VERSION-}"; then\n  exec /usr/local/bin/bash "$0" "$@"\nfi\n'
if reexec_guard not in text:
    shebang, rest = text.split("\n", 1)
    text = shebang + "\n" + reexec_guard + rest
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
    """    func_show_eval "$RM $output_objdir/$linkname && $LN_S $realname $output_objdir/$linkname" 'exit $?'\n""",
)
text = text.replace(
    """  func_show_eval '( cd "$output_objdir" && $RM "$outputname" && $LN_S "../$outputname" "$outputname" )' 'exit $?'\n""",
    """  func_show_eval "$RM $output_objdir/$outputname && $LN_S ../$outputname $output_objdir/$outputname" 'exit $?'\n""",
)
text = text.replace(
    """\t\t&& func_show_eval "(cd $destdir && { $LN_S -f $realname $linkname || { $RM $linkname && $LN_S $realname $linkname; }; })"\n""",
    """\t\t&& func_show_eval "$RM $destdir/$linkname && $LN_S $realname $destdir/$linkname"\n""",
)
text = text.replace(
    """\t# Create links to the real library.\n\tfor linkname in $linknames; do\n\t  if test "$realname" != "$linkname"; then\n\t    func_show_eval "$RM $output_objdir/$linkname && $LN_S $realname $output_objdir/$linkname" 'exit $?'\n\t  fi\n\tdone\n""",
    """\t# Create links to the real library.\n\trealname=${realname#\\"}\n\trealname=${realname%\\"}\n\tfor linkname in $linknames; do\n\t  linkname=${linkname#\\"}\n\t  linkname=${linkname%\\"}\n\t  if test "$realname" != "$linkname"; then\n\t    func_show_eval "$RM $output_objdir/$linkname && $LN_S $realname $output_objdir/$linkname" 'exit $?'\n\t  fi\n\tdone\n""",
)
text = text.replace(
    """      # Do a symbolic link so that the libtool archive can be found in\n      # LD_LIBRARY_PATH before the program is installed.\n      func_show_eval "$RM $output_objdir/$outputname && $LN_S ../$outputname $output_objdir/$outputname" 'exit $?'\n""",
    """      # Do a symbolic link so that the libtool archive can be found in\n      # LD_LIBRARY_PATH before the program is installed.\n      outputname=${outputname#\\"}\n      outputname=${outputname%\\"}\n      func_show_eval "$RM $output_objdir/$outputname && $LN_S ../$outputname $output_objdir/$outputname" 'exit $?'\n""",
)
text = text.replace(
    """\t  if test "$#" -gt 0; then\n\t    # Delete the old symlinks, and create new ones.\n\t    # Try 'ln -sf' first, because the 'ln' binary might depend on\n\t    # the symlink we replace!  Solaris /bin/ln does not understand -f,\n\t    # so we also need to try rm && ln -s.\n\t    for linkname\n\t    do\n\t      test "$linkname" != "$realname" \\\n\t\t&& func_show_eval "$RM $destdir/$linkname && $LN_S $realname $destdir/$linkname"\n\t    done\n\t  fi\n""",
    """\t  if test "$#" -gt 0; then\n\t    # Delete the old symlinks, and create new ones.\n\t    # Try 'ln -sf' first, because the 'ln' binary might depend on\n\t    # the symlink we replace!  Solaris /bin/ln does not understand -f,\n\t    # so we also need to try rm && ln -s.\n\t    realname=${realname#\\"}\n\t    realname=${realname%\\"}\n\t    for linkname\n\t    do\n\t      linkname=${linkname#\\"}\n\t      linkname=${linkname%\\"}\n\t      test "$linkname" != "$realname" \\\n\t\t&& func_show_eval "$RM $destdir/$linkname && $LN_S $realname $destdir/$linkname"\n\t    done\n\t  fi\n""",
)
text = re.sub(
    r'(^[ \t]*)realname=\$1$',
    r'\1realname=$1\n\1realname=${realname#\\"}\n\1realname=${realname%\\"}',
    text,
    flags=re.MULTILINE,
)
text = re.sub(
    r'(^[ \t]*)for linkname in \$linknames; do$',
    r'\1for linkname in $linknames; do\n\1  linkname=${linkname#\\"}\n\1  linkname=${linkname%\\"}',
    text,
    flags=re.MULTILINE,
)
text = re.sub(
    r'(^[ \t]*)outputname=(\$func_[A-Za-z0-9_]+_result)$',
    r'\1outputname=\2\n\1outputname=${outputname#\\"}\n\1outputname=${outputname%\\"}',
    text,
    flags=re.MULTILINE,
)
text = re.sub(
    r'(^[ \t]*)old_library=\$libname\.\$libext$',
    r'\1test "$libname" != "lib" || libname="lib$name"\n\1old_library=$libname.$libext',
    text,
    flags=re.MULTILINE,
)
libtool_path.write_text(text)
PY

python3 - <<'PY'
import os
from pathlib import Path

source_root = Path(os.environ["PKG_SOURCE_DIR"])

pathnames = source_root / "include" / "pathnames.h"
text = pathnames.read_text()
anchor = '#define\t_PATH_VAR_NOLOGIN\t"/var/run/nologin"\n'
insertion = '''#define\t_PATH_VAR_NOLOGIN\t"/var/run/nologin"\n\n#ifndef _PATH_RUNSTATEDIR\n#define _PATH_RUNSTATEDIR "/usr/local/var/run"\n#endif\n#ifndef _PATH_LOCALSTATEDIR\n#define _PATH_LOCALSTATEDIR "/usr/local/var"\n#endif\n#ifndef _PATH_SYSCONFSTATICDIR\n#define _PATH_SYSCONFSTATICDIR "/usr/local/lib"\n#endif\n'''
if '#ifndef _PATH_RUNSTATEDIR\n#define _PATH_RUNSTATEDIR "/usr/local/var/run"\n#endif' not in text:
    if anchor not in text:
        raise SystemExit(f"expected anchor not found in {pathnames}")
    text = text.replace(anchor, insertion, 1)
    pathnames.write_text(text)

nls = source_root / "include" / "nls.h"
text = nls.read_text()
old = '#define LOCALEDIR "/usr/share/locale"'
new = '#define LOCALEDIR "/usr/local/share/locale"'
if old in text:
    nls.write_text(text.replace(old, new, 1))

config_h = Path("config.h")
text = config_h.read_text()
anchor = '#define CONFIG_ADJTIME_PATH "/etc/adjtime"\n'
insertion = '''#define CONFIG_ADJTIME_PATH "/etc/adjtime"\n\n#ifndef _PATH_RUNSTATEDIR\n#define _PATH_RUNSTATEDIR "/usr/local/var/run"\n#endif\n#ifndef _PATH_LOCALSTATEDIR\n#define _PATH_LOCALSTATEDIR "/usr/local/var"\n#endif\n#ifndef _PATH_SYSCONFSTATICDIR\n#define _PATH_SYSCONFSTATICDIR "/usr/local/lib"\n#endif\n'''
if '#ifndef _PATH_LOCALSTATEDIR\n#define _PATH_LOCALSTATEDIR "/usr/local/var"\n#endif' not in text:
    if anchor not in text:
        raise SystemExit(f"expected anchor not found in {config_h}")
    text = text.replace(anchor, insertion, 1)
    config_h.write_text(text)

for makefile in Path(".").rglob("Makefile"):
    lines = makefile.read_text().splitlines()
    filtered = [
        line for line in lines
        if '-DLOCALEDIR=' not in line
        and '-D_PATH_RUNSTATEDIR=' not in line
        and '-D_PATH_LOCALSTATEDIR=' not in line
        and '-D_PATH_SYSCONFSTATICDIR=' not in line
    ]
    rewritten = "\n".join(filtered)
    rewritten = rewritten.replace("/bin/sh", "/usr/local/bin/bash")
    rewritten = rewritten.replace("SHELL = /bin/sh", "SHELL = /usr/local/bin/bash")
    rewritten = rewritten.replace("/bin/sh ./libtool", "/usr/local/bin/bash ./libtool")
    makefile.write_text(rewritten + "\n")
PY

make -j"$BUILD_JOBS"
make DESTDIR="$PKG_DESTDIR" install
