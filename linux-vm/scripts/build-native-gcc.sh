#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_GCC_ARCHIVE_PATH="${LOCAL_GCC_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/gcc/gcc-14.3.0.tar.xz}"
LOCAL_GMP_ARCHIVE_PATH="${LOCAL_GMP_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/gmp/gmp-6.3.0.tar.xz}"
LOCAL_MPFR_ARCHIVE_PATH="${LOCAL_MPFR_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/mpfr/mpfr-4.1.1.tar.xz}"
LOCAL_MPC_ARCHIVE_PATH="${LOCAL_MPC_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/mpc/mpc-1.3.1.tar.gz}"
GCC_ARCHIVE="${GCC_ARCHIVE:-$(basename "$LOCAL_GCC_ARCHIVE_PATH")}"
GMP_ARCHIVE="${GMP_ARCHIVE:-$(basename "$LOCAL_GMP_ARCHIVE_PATH")}"
MPFR_ARCHIVE="${MPFR_ARCHIVE:-$(basename "$LOCAL_MPFR_ARCHIVE_PATH")}"
MPC_ARCHIVE="${MPC_ARCHIVE:-$(basename "$LOCAL_MPC_ARCHIVE_PATH")}"
SDK_ROOT="${SDK_ROOT:-/Volumes/slopos-data/toolchain/current}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-/Volumes/slopos-data/toolchain/native}"
GLIBC_STAGE_ROOT="${GLIBC_STAGE_ROOT:-/Volumes/slopos-data/toolchain/glibc-stage}"
KERNEL_HEADERS_ROOT="${KERNEL_HEADERS_ROOT:-/Volumes/slopos-data/toolchain/kernel-headers}"
SOURCE_ROOT="${SOURCE_ROOT:-/Volumes/slopos-data/toolchain/sources}"
BUILD_ROOT="${BUILD_ROOT:-/Volumes/slopos-data/toolchain/build}"
BUILD_JOBS="${BUILD_JOBS:-1}"

for archive in \
  "$LOCAL_GCC_ARCHIVE_PATH" \
  "$LOCAL_GMP_ARCHIVE_PATH" \
  "$LOCAL_MPFR_ARCHIVE_PATH" \
  "$LOCAL_MPC_ARCHIVE_PATH"; do
  if [[ ! -f "$archive" ]]; then
    echo "Missing cached archive: $archive" >&2
    exit 1
  fi
done

guest_script="$(mktemp)"
trap 'rm -f "$guest_script"' EXIT

cat >"$guest_script" <<EOF
#!/bin/bash
set -euo pipefail

gcc_archive=$(printf '%q' "$GCC_ARCHIVE")
gmp_archive=$(printf '%q' "$GMP_ARCHIVE")
mpfr_archive=$(printf '%q' "$MPFR_ARCHIVE")
mpc_archive=$(printf '%q' "$MPC_ARCHIVE")
sdk_root=$(printf '%q' "$SDK_ROOT")
toolchain_root=$(printf '%q' "$TOOLCHAIN_ROOT")
glibc_stage_root=$(printf '%q' "$GLIBC_STAGE_ROOT")
kernel_headers_root=$(printf '%q' "$KERNEL_HEADERS_ROOT")
source_root=$(printf '%q' "$SOURCE_ROOT")
build_root=$(printf '%q' "$BUILD_ROOT")
build_jobs=$(printf '%q' "$BUILD_JOBS")
gcc_archive_path="\$source_root/\$gcc_archive"
gmp_archive_path="\$source_root/\$gmp_archive"
mpfr_archive_path="\$source_root/\$mpfr_archive"
mpc_archive_path="\$source_root/\$mpc_archive"
gcc_build_dir="\$build_root/gcc-build"
smoke_dir="\$build_root/gcc-smoke"
sdk_gcc="\$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc"
sdk_gxx="\$sdk_root/bin/aarch64-buildroot-linux-gnu-g++"
native_bin="\$toolchain_root/bin"
xgcc_cpp_wrapper=/lib/cpp
sdk_runtime_libs="\$sdk_root/aarch64-buildroot-linux-gnu/sysroot/usr/lib:\$sdk_root/aarch64-buildroot-linux-gnu/sysroot/lib"

mkdir -p "\$source_root" "\$build_root" "\$toolchain_root"

for tool in \
  "\$sdk_gcc" \
  "\$sdk_gxx" \
  "\$native_bin/aarch64-linux-gnu-as" \
  "\$native_bin/aarch64-linux-gnu-ld"; do
  if [[ ! -x "\$tool" ]]; then
    echo "Missing required bootstrap tool: \$tool" >&2
    exit 1
  fi
done

if [[ ! -d "\$kernel_headers_root/include" ]]; then
  echo "Missing kernel headers: \$kernel_headers_root/include" >&2
  exit 1
fi

set +o pipefail
gcc_source_dir="\$source_root/\$(tar -tf "\$gcc_archive_path" | head -n 1 | cut -d/ -f1)"
gmp_source_dir="\$source_root/\$(tar -tf "\$gmp_archive_path" | head -n 1 | cut -d/ -f1)"
mpfr_source_dir="\$source_root/\$(tar -tf "\$mpfr_archive_path" | head -n 1 | cut -d/ -f1)"
mpc_source_dir="\$source_root/\$(tar -tf "\$mpc_archive_path" | head -n 1 | cut -d/ -f1)"
set -o pipefail

for dir in "\$gcc_source_dir" "\$gmp_source_dir" "\$mpfr_source_dir" "\$mpc_source_dir"; do
  archive_path=
  case "\$dir" in
    "\$gcc_source_dir") archive_path="\$gcc_archive_path" ;;
    "\$gmp_source_dir") archive_path="\$gmp_archive_path" ;;
    "\$mpfr_source_dir") archive_path="\$mpfr_archive_path" ;;
    "\$mpc_source_dir") archive_path="\$mpc_archive_path" ;;
  esac
  if [[ ! -d "\$dir" ]]; then
    tar -xf "\$archive_path" -C "\$source_root"
  fi
done

rm -rf "\$gcc_source_dir/gmp" "\$gcc_source_dir/mpfr" "\$gcc_source_dir/mpc"
ln -s "\$gmp_source_dir" "\$gcc_source_dir/gmp"
ln -s "\$mpfr_source_dir" "\$gcc_source_dir/mpfr"
ln -s "\$mpc_source_dir" "\$gcc_source_dir/mpc"

rm -rf "\$gcc_build_dir" "\$smoke_dir"
mkdir -p "\$gcc_build_dir" "\$smoke_dir"
cd "\$gcc_build_dir"

export PATH="\$sdk_root/bin:/usr/bin:/bin"
export CONFIG_SHELL=/bin/bash
export MAKEINFO=true
export CC="\$sdk_gcc -B\$native_bin"
export CXX="\$sdk_gxx -B\$native_bin"
export AR="\$native_bin/aarch64-linux-gnu-ar"
export AS="\$native_bin/aarch64-linux-gnu-as"
export LD="\$native_bin/aarch64-linux-gnu-ld"
export RANLIB="\$native_bin/aarch64-linux-gnu-ranlib"
export CC_FOR_BUILD="\$sdk_gcc -B\$native_bin"
export CXX_FOR_BUILD="\$sdk_gxx -B\$native_bin"
export LD_LIBRARY_PATH="\$sdk_root/aarch64-buildroot-linux-gnu/sysroot/usr/lib:\$sdk_root/aarch64-buildroot-linux-gnu/sysroot/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

"\$gcc_source_dir/configure" \
  --prefix="\$toolchain_root" \
  --build=aarch64-linux-gnu \
  --host=aarch64-linux-gnu \
  --target=aarch64-linux-gnu \
  --with-sysroot="\$glibc_stage_root" \
  --with-build-sysroot="\$glibc_stage_root" \
  --with-native-system-header-dir=/usr/include \
  --with-as="\$native_bin/aarch64-linux-gnu-as" \
  --with-ld="\$native_bin/aarch64-linux-gnu-ld" \
  --enable-languages=c \
  --disable-bootstrap \
  --disable-multilib \
  --disable-nls \
  --disable-libatomic \
  --disable-libgomp \
  --disable-libquadmath \
  --disable-libsanitizer \
  --disable-libssp \
  --disable-libstdcxx-pch \
  --disable-libvtv \
  --disable-werror \
  --without-isl

if [[ ! -f "\$glibc_stage_root/usr/include/linux/limits.h" ]]; then
  rsync -a "\$kernel_headers_root/include/" "\$glibc_stage_root/usr/include/"
fi

if [[ ! -e "\$xgcc_cpp_wrapper" ]]; then
  cat >"\$xgcc_cpp_wrapper" <<CPP
#!/bin/sh
export LD_LIBRARY_PATH="\$sdk_runtime_libs\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$gcc_build_dir/gcc/xgcc" -B"\$gcc_build_dir/gcc/" -B"\$toolchain_root/aarch64-linux-gnu/bin/" -B"\$toolchain_root/aarch64-linux-gnu/lib/" -isystem "\$toolchain_root/aarch64-linux-gnu/include" -isystem "\$toolchain_root/aarch64-linux-gnu/sys-include" --sysroot="\$glibc_stage_root" -E "\$@"
CPP
  chmod 0755 "\$xgcc_cpp_wrapper"
fi

make -j"\$build_jobs" all-gcc all-target-libgcc
make install-gcc install-target-libgcc

versioned_gcc="\$(find "\$toolchain_root/bin" -maxdepth 1 -type f -name 'aarch64-linux-gnu-gcc-*' | sort | head -n 1)"
if [[ -n "\$versioned_gcc" ]]; then
  rm -f "\$toolchain_root/bin/aarch64-linux-gnu-gcc"
  cat >"\$toolchain_root/bin/aarch64-linux-gnu-gcc" <<GCCWRAP
#!/bin/sh
export LD_LIBRARY_PATH="\$sdk_runtime_libs\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$versioned_gcc" "\$@"
GCCWRAP
  chmod 0755 "\$toolchain_root/bin/aarch64-linux-gnu-gcc"
fi

cat >"\$smoke_dir/hello.c" <<'SRC'
#include <stdio.h>

int main(void) {
  puts("native-gcc-stage-ok");
  return 0;
}
SRC

LD_LIBRARY_PATH="\$sdk_runtime_libs\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" "\$toolchain_root/bin/aarch64-linux-gnu-gcc" --sysroot="\$glibc_stage_root" "\$smoke_dir/hello.c" -o "\$smoke_dir/hello"
"\$glibc_stage_root/lib/ld-linux-aarch64.so.1" --library-path "\$glibc_stage_root/lib:\$glibc_stage_root/usr/lib" "\$smoke_dir/hello"
LD_LIBRARY_PATH="\$sdk_runtime_libs\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" "\$toolchain_root/bin/aarch64-linux-gnu-gcc" --version | head -n 1
EOF

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$SOURCE_ROOT'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_GCC_ARCHIVE_PATH" "$SOURCE_ROOT/$GCC_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_GMP_ARCHIVE_PATH" "$SOURCE_ROOT/$GMP_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_MPFR_ARCHIVE_PATH" "$SOURCE_ROOT/$MPFR_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_MPC_ARCHIVE_PATH" "$SOURCE_ROOT/$MPC_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$guest_script" /tmp/build-native-gcc.sh
"$ROOT_DIR/scripts/ssh-guest.sh" "bash /tmp/build-native-gcc.sh"
