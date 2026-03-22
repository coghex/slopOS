#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINUTILS_VERSION="${BINUTILS_VERSION:-2.45.1}"
BINUTILS_ARCHIVE="binutils-${BINUTILS_VERSION}.tar.xz"
BINUTILS_URL="${BINUTILS_URL:-http://ftp.gnu.org/gnu/binutils/${BINUTILS_ARCHIVE}}"
SDK_ROOT="${SDK_ROOT:-/Volumes/slopos-data/toolchain/current}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-/Volumes/slopos-data/toolchain/native}"
SOURCE_ROOT="${SOURCE_ROOT:-/Volumes/slopos-data/toolchain/sources}"
BUILD_ROOT="${BUILD_ROOT:-/Volumes/slopos-data/toolchain/build}"
LOCAL_ARCHIVE_PATH="${LOCAL_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/binutils/${BINUTILS_ARCHIVE}}"

guest_script="$(mktemp)"
trap 'rm -f "$guest_script"' EXIT

cat >"$guest_script" <<EOF
#!/bin/bash
set -euo pipefail

binutils_version=$(printf '%q' "$BINUTILS_VERSION")
binutils_archive=$(printf '%q' "$BINUTILS_ARCHIVE")
binutils_url=$(printf '%q' "$BINUTILS_URL")
sdk_root=$(printf '%q' "$SDK_ROOT")
toolchain_root=$(printf '%q' "$TOOLCHAIN_ROOT")
source_root=$(printf '%q' "$SOURCE_ROOT")
build_root=$(printf '%q' "$BUILD_ROOT")
source_dir="\$source_root/binutils-\$binutils_version"
build_dir="\$build_root/binutils-\$binutils_version"

mkdir -p "\$source_root" "\$build_root" "\$toolchain_root"

if [[ ! -x "\$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc" ]]; then
  echo "Missing SDK compiler at \$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc" >&2
  exit 1
fi

if [[ ! -f "\$source_root/\$binutils_archive" ]]; then
  wget -O "\$source_root/\$binutils_archive" "\$binutils_url"
fi

if [[ ! -d "\$source_dir" ]]; then
  tar -xf "\$source_root/\$binutils_archive" -C "\$source_root"
fi

rm -rf "\$build_dir"
mkdir -p "\$build_dir"
cd "\$build_dir"

export CC="\$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc"
export AR="\$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc-ar"
export RANLIB="\$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc-ranlib"
export STRIP="\$sdk_root/bin/aarch64-buildroot-linux-gnu-strip"

"\$source_dir/configure" \
  --prefix="\$toolchain_root" \
  --target=aarch64-linux-gnu \
  --disable-gprofng \
  --disable-nls \
  --disable-werror \
  --with-sysroot=/

make -j"\$(nproc 2>/dev/null || echo 2)"
make install

"\$toolchain_root/bin/aarch64-linux-gnu-as" --version | head -n 1
"\$toolchain_root/bin/aarch64-linux-gnu-ld" --version | head -n 1
EOF

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$SOURCE_ROOT'"
if [[ -f "$LOCAL_ARCHIVE_PATH" ]]; then
  "$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_ARCHIVE_PATH" "$SOURCE_ROOT/$BINUTILS_ARCHIVE"
fi

"$ROOT_DIR/scripts/scp-to-guest.sh" "$guest_script" /tmp/build-native-binutils.sh
"$ROOT_DIR/scripts/ssh-guest.sh" "bash /tmp/build-native-binutils.sh"
