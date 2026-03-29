#!/usr/bin/env bash
set -euo pipefail

echo "warning: build-selfhost-gcc-final.sh is a legacy/manual helper." >&2
echo "warning: preferred workflow: /usr/local/bin/sloppkg --state-root /Volumes/slopos-data/pkg install selfhost-toolchain --root /" >&2

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_GCC_ARCHIVE_PATH="${LOCAL_GCC_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/gcc/gcc-14.3.0.tar.xz}"
GCC_ARCHIVE="${GCC_ARCHIVE:-$(basename "$LOCAL_GCC_ARCHIVE_PATH")}"
SDK_ROOT="${SDK_ROOT:-/Volumes/slopos-data/toolchain/current}"
STAGE1_ROOT="${STAGE1_ROOT:-/Volumes/slopos-data/toolchain/selfhost-stage1}"
INTERMEDIATE_ROOT="${INTERMEDIATE_ROOT:-/Volumes/slopos-data/toolchain/selfhost-stage2}"
SELFHOST_GLIBC_STAGE_ROOT="${SELFHOST_GLIBC_STAGE_ROOT:-/Volumes/slopos-data/toolchain/selfhost-glibc-stage}"
SOURCE_ROOT="${SOURCE_ROOT:-/Volumes/slopos-data/toolchain/sources}"
BUILD_ROOT="${BUILD_ROOT:-/Volumes/slopos-data/toolchain/build}"
FINAL_ROOT="${FINAL_ROOT:-/Volumes/slopos-data/toolchain/selfhost-final}"
BUILD_JOBS="${BUILD_JOBS:-2}"

if [[ ! -f "$LOCAL_GCC_ARCHIVE_PATH" ]]; then
  echo "Missing cached GCC archive: $LOCAL_GCC_ARCHIVE_PATH" >&2
  exit 1
fi

guest_script="$(mktemp)"
trap 'rm -f "$guest_script"' EXIT

cat >"$guest_script" <<EOF
#!/bin/bash
set -euo pipefail

gcc_archive=$(printf '%q' "$GCC_ARCHIVE")
sdk_root=$(printf '%q' "$SDK_ROOT")
stage1_root=$(printf '%q' "$STAGE1_ROOT")
intermediate_root=$(printf '%q' "$INTERMEDIATE_ROOT")
selfhost_glibc_stage_root=$(printf '%q' "$SELFHOST_GLIBC_STAGE_ROOT")
source_root=$(printf '%q' "$SOURCE_ROOT")
build_root=$(printf '%q' "$BUILD_ROOT")
final_root=$(printf '%q' "$FINAL_ROOT")
build_jobs=$(printf '%q' "$BUILD_JOBS")

stage1_bin="\$stage1_root/bin"
intermediate_gcc="\$intermediate_root/bin/selfhost-gcc"
intermediate_gxx="\$intermediate_root/bin/selfhost-g++"
gcc_archive_path="\$source_root/\$gcc_archive"
gcc_build_dir="\$build_root/selfhost-final-gcc-build"
smoke_dir="\$build_root/selfhost-final-smoke"

for tool in \
  "\$intermediate_gcc" \
  "\$intermediate_gxx" \
  "\$stage1_bin/aarch64-linux-gnu-as" \
  "\$stage1_bin/aarch64-linux-gnu-ld" \
  "\$stage1_bin/aarch64-linux-gnu-ar" \
  "\$stage1_bin/aarch64-linux-gnu-ranlib"; do
  if [[ ! -x "\$tool" ]]; then
    echo "Missing required tool: \$tool" >&2
    exit 1
  fi
done

for path in \
  "\$stage1_root/include/gmp.h" \
  "\$stage1_root/include/mpfr.h" \
  "\$stage1_root/include/mpc.h" \
  "\$selfhost_glibc_stage_root/usr/include/stdio.h"; do
  if [[ ! -e "\$path" ]]; then
    echo "Missing required path: \$path" >&2
    exit 1
  fi
done

mkdir -p "\$source_root" "\$build_root"
rm -rf "\$final_root" "\$gcc_build_dir" "\$smoke_dir"
mkdir -p "\$final_root" "\$gcc_build_dir" "\$smoke_dir"

set +o pipefail
gcc_source_dir="\$source_root/\$(tar -tf "\$gcc_archive_path" | head -n 1 | cut -d/ -f1)"
set -o pipefail

if [[ ! -d "\$gcc_source_dir" ]]; then
  tar -xf "\$gcc_archive_path" -C "\$source_root"
fi

cd "\$gcc_build_dir"

export PATH="\$sdk_root/bin:\$intermediate_root/bin:\$stage1_bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CONFIG_SHELL=/bin/bash
export MAKEINFO=true
export CC="\$intermediate_gcc"
export CXX="\$intermediate_gxx"
export AR="\$stage1_bin/aarch64-linux-gnu-ar"
export AS="\$stage1_bin/aarch64-linux-gnu-as"
export LD="\$stage1_bin/aarch64-linux-gnu-ld"
export RANLIB="\$stage1_bin/aarch64-linux-gnu-ranlib"
export CC_FOR_BUILD="\$intermediate_gcc"
export CXX_FOR_BUILD="\$intermediate_gxx"
export CFLAGS="-g -O2 -fno-PIE"
export CXXFLAGS="-g -O2 -fno-PIE"
export CFLAGS_FOR_BUILD="-g -O2 -fno-PIE"
export CXXFLAGS_FOR_BUILD="-g -O2 -fno-PIE"
export CPPFLAGS="-I\$stage1_root/include"
export LDFLAGS="-L\$stage1_root/lib -L\$stage1_root/lib64 -no-pie"
export LDFLAGS_FOR_BUILD="-L\$stage1_root/lib -L\$stage1_root/lib64 -no-pie"
export LIBRARY_PATH="\$stage1_root/lib:\$stage1_root/lib64"
export LD_LIBRARY_PATH="\$intermediate_root/lib64:\$intermediate_root/lib:\$stage1_root/lib64:\$stage1_root/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

"\$gcc_source_dir/configure" \
  --prefix="\$final_root" \
  --build=aarch64-linux-gnu \
  --host=aarch64-linux-gnu \
  --target=aarch64-linux-gnu \
  --with-sysroot="\$selfhost_glibc_stage_root" \
  --with-build-sysroot="\$selfhost_glibc_stage_root" \
  --with-native-system-header-dir=/usr/include \
  --with-as="\$stage1_bin/aarch64-linux-gnu-as" \
  --with-ld="\$stage1_bin/aarch64-linux-gnu-ld" \
  --with-gmp="\$stage1_root" \
  --with-mpfr="\$stage1_root" \
  --with-mpc="\$stage1_root" \
  --enable-languages=c,c++ \
  --disable-bootstrap \
  --disable-multilib \
  --disable-nls \
  --disable-libsanitizer \
  --disable-libquadmath \
  --disable-libgomp \
  --disable-libitm \
  --disable-libvtv \
  --disable-libssp \
  --disable-werror \
  --without-isl

make -j"\$build_jobs" all-gcc all-target-libgcc all-target-libstdc++-v3
make install-gcc install-target-libgcc install-target-libstdc++-v3

cat >"\$final_root/bin/selfhost-gcc" <<WRAP
#!/bin/sh
stage1_root="\$stage1_root"
intermediate_root="\$intermediate_root"
final_root="\$final_root"
selfhost_glibc_stage_root="\$selfhost_glibc_stage_root"
stage1_bin="\$stage1_root/bin"
export PATH="\$stage1_bin:\\\$PATH"
export LD_LIBRARY_PATH="\$final_root/lib64:\$final_root/lib:\$intermediate_root/lib64:\$intermediate_root/lib:\$stage1_root/lib64:\$stage1_root/lib\\\${LD_LIBRARY_PATH:+:\\\$LD_LIBRARY_PATH}"
exec "\$final_root/bin/aarch64-linux-gnu-gcc" -B"\$stage1_bin" --sysroot="\$selfhost_glibc_stage_root" "\\\$@"
WRAP
chmod 0755 "\$final_root/bin/selfhost-gcc"

cat >"\$final_root/bin/selfhost-g++" <<WRAP
#!/bin/sh
stage1_root="\$stage1_root"
intermediate_root="\$intermediate_root"
final_root="\$final_root"
selfhost_glibc_stage_root="\$selfhost_glibc_stage_root"
stage1_bin="\$stage1_root/bin"
export PATH="\$stage1_bin:\\\$PATH"
export LD_LIBRARY_PATH="\$final_root/lib64:\$final_root/lib:\$intermediate_root/lib64:\$intermediate_root/lib:\$stage1_root/lib64:\$stage1_root/lib\\\${LD_LIBRARY_PATH:+:\\\$LD_LIBRARY_PATH}"
exec "\$final_root/bin/aarch64-linux-gnu-g++" -B"\$stage1_bin" --sysroot="\$selfhost_glibc_stage_root" "\\\$@"
WRAP
chmod 0755 "\$final_root/bin/selfhost-g++"

cat >"\$smoke_dir/hello.cc" <<'SRC'
#include <iostream>

int main() {
  std::cout << "selfhost-final-ok" << std::endl;
  return 0;
}
SRC

"\$final_root/bin/selfhost-g++" "\$smoke_dir/hello.cc" -o "\$smoke_dir/hello"
LD_LIBRARY_PATH="\$final_root/lib64:\$final_root/lib:\$selfhost_glibc_stage_root/lib:\$selfhost_glibc_stage_root/usr/lib:\$intermediate_root/lib64:\$intermediate_root/lib:\$stage1_root/lib64:\$stage1_root/lib" "\$smoke_dir/hello"
"\$final_root/bin/selfhost-g++" --version | head -n 1
EOF

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$SOURCE_ROOT'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_GCC_ARCHIVE_PATH" "$SOURCE_ROOT/$GCC_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$guest_script" /tmp/build-selfhost-gcc-final.sh
"$ROOT_DIR/scripts/ssh-guest.sh" "bash /tmp/build-selfhost-gcc-final.sh"
