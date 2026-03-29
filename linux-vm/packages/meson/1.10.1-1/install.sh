#!/usr/bin/env bash
set -euo pipefail

install -d \
  "$PKG_DESTDIR/usr/local/bin" \
  "$PKG_DESTDIR/usr/local/lib/meson" \
  "$PKG_DESTDIR/usr/local/share/licenses/meson"
cp -a "$PKG_SOURCE_DIR/meson.py" "$PKG_DESTDIR/usr/local/lib/meson/"
cp -a "$PKG_SOURCE_DIR/mesonbuild" "$PKG_DESTDIR/usr/local/lib/meson/"
install -m 0644 "$PKG_SOURCE_DIR/COPYING" \
  "$PKG_DESTDIR/usr/local/share/licenses/meson/COPYING"
cat >"$PKG_DESTDIR/usr/local/bin/meson" <<'EOF'
#!/bin/sh
pythonpath_orig="${PYTHONPATH:-}"
for sdk_python in /Volumes/slopos-data/toolchain/slopos-aarch64-bootstrap-sdk/lib/python*; do
  if [ -d "$sdk_python" ]; then
    sdk_path="$sdk_python"
    if [ -d "$sdk_python/lib-dynload" ]; then
      sdk_path="$sdk_python/lib-dynload:$sdk_path"
    fi
    export PYTHONPATH="$sdk_path${pythonpath_orig:+:$pythonpath_orig}"
    break
  fi
done
exec python3 /usr/local/lib/meson/meson.py "$@"
EOF
chmod 0755 "$PKG_DESTDIR/usr/local/bin/meson"
