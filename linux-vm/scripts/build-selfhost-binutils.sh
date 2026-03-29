#!/usr/bin/env bash
set -euo pipefail

echo "warning: build-selfhost-binutils.sh is a legacy/manual helper." >&2
echo "warning: preferred workflow: /usr/local/bin/sloppkg --state-root /Volumes/slopos-data/pkg install selfhost-toolchain --root /" >&2

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINUTILS_VERSION="${BINUTILS_VERSION:-2.45.1}"
BINUTILS_ARCHIVE="binutils-${BINUTILS_VERSION}.tar.xz"
LOCAL_ARCHIVE_PATH="${LOCAL_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/binutils/${BINUTILS_ARCHIVE}}"
SOURCE_ROOT="${SOURCE_ROOT:-/Volumes/slopos-data/toolchain/sources}"
BUILD_ROOT="${BUILD_ROOT:-/Volumes/slopos-data/toolchain/build}"
SELFHOST_ROOT="${SELFHOST_ROOT:-/Volumes/slopos-data/toolchain/selfhost-stage1}"
SDK_ROOT="${SDK_ROOT:-/Volumes/slopos-data/toolchain/current}"
BUILD_JOBS="${BUILD_JOBS:-2}"

if [[ ! -f "$LOCAL_ARCHIVE_PATH" ]]; then
  echo "Missing cached binutils archive: $LOCAL_ARCHIVE_PATH" >&2
  exit 1
fi

guest_script="$(mktemp)"
trap 'rm -f "$guest_script"' EXIT

cat >"$guest_script" <<EOF
#!/bin/bash
set -euo pipefail

binutils_version=$(printf '%q' "$BINUTILS_VERSION")
binutils_archive=$(printf '%q' "$BINUTILS_ARCHIVE")
source_root=$(printf '%q' "$SOURCE_ROOT")
build_root=$(printf '%q' "$BUILD_ROOT")
selfhost_root=$(printf '%q' "$SELFHOST_ROOT")
sdk_root=$(printf '%q' "$SDK_ROOT")
build_jobs=$(printf '%q' "$BUILD_JOBS")

compiler=/usr/bin/gcc
cxx_compiler="\$sdk_root/bin/aarch64-buildroot-linux-gnu-g++"
source_dir="\$source_root/binutils-\$binutils_version"
build_dir="\$build_root/binutils-selfhost-\$binutils_version"

for tool in "\$compiler" "\$cxx_compiler"; do
  if [[ ! -x "\$tool" ]]; then
    echo "Missing required compiler: \$tool" >&2
    exit 1
  fi
done

mkdir -p "\$source_root" "\$build_root" "\$selfhost_root"

if [[ ! -d "\$source_dir" ]]; then
  tar -xf "\$source_root/\$binutils_archive" -C "\$source_root"
fi

rm -rf "\$build_dir"
mkdir -p "\$build_dir"
cd "\$build_dir"

export PATH="\$sdk_root/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC="\$compiler"
export CXX="\$cxx_compiler"
export CPPFLAGS="-I\$selfhost_root/include"
export LDFLAGS="-L\$selfhost_root/lib -L\$selfhost_root/lib64"
export LD_LIBRARY_PATH="\$selfhost_root/lib:\$selfhost_root/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

"\$source_dir/configure" \
  --prefix="\$selfhost_root" \
  --target=aarch64-linux-gnu \
  --disable-gprofng \
  --disable-nls \
  --disable-werror \
  --with-sysroot=/

make -j"\$build_jobs"
make install

"\$selfhost_root/bin/aarch64-linux-gnu-as" --version | head -n 1
"\$selfhost_root/bin/aarch64-linux-gnu-ld" --version | head -n 1
EOF

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$SOURCE_ROOT'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_ARCHIVE_PATH" "$SOURCE_ROOT/$BINUTILS_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$guest_script" /tmp/build-selfhost-binutils.sh
"$ROOT_DIR/scripts/ssh-guest.sh" "bash /tmp/build-selfhost-binutils.sh"
