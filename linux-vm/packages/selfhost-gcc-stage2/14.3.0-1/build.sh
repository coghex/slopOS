#!/bin/bash
set -euo pipefail
: "${SELFHOST_SDK_ROOT:?}"
: "${SELFHOST_STAGE1_ROOT:?}"
: "${SELFHOST_STAGE2_ROOT:?}"
: "${SELFHOST_NATIVE_GLIBC_STAGE_ROOT:?}"
sdk_root="$SELFHOST_SDK_ROOT"
stage1_root="$SELFHOST_STAGE1_ROOT"
stage2_root="$SELFHOST_STAGE2_ROOT"
glibc_stage_root="$SELFHOST_NATIVE_GLIBC_STAGE_ROOT"
stage2_dest="$PKG_DESTDIR$stage2_root"
stage1_bin="$stage1_root/bin"
sdk_cc="$sdk_root/bin/aarch64-buildroot-linux-gnu-gcc -B$stage1_bin"
sdk_cxx="$sdk_root/bin/aarch64-buildroot-linux-gnu-g++ -B$stage1_bin"
build_dir="$PKG_BUILD_DIR/gcc-stage2"
smoke_dir="$PKG_BUILD_DIR/smoke-stage2"
rm -rf "$build_dir" "$smoke_dir"
mkdir -p "$build_dir" "$smoke_dir" "$stage2_dest"
cd "$build_dir"
export PATH="$sdk_root/bin:$stage1_bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CONFIG_SHELL=/bin/bash
export MAKEINFO=true
export CC="$sdk_cc"
export CXX="$sdk_cxx"
export AR="$stage1_bin/aarch64-linux-gnu-ar"
export AS="$stage1_bin/aarch64-linux-gnu-as"
export LD="$stage1_bin/aarch64-linux-gnu-ld"
export RANLIB="$stage1_bin/aarch64-linux-gnu-ranlib"
export CC_FOR_BUILD="$sdk_cc"
export CXX_FOR_BUILD="$sdk_cxx"
export CFLAGS="-g -O2 -fno-PIE"
export CXXFLAGS="-g -O2 -fno-PIE"
export CFLAGS_FOR_BUILD="-g -O2 -fno-PIE"
export CXXFLAGS_FOR_BUILD="-g -O2 -fno-PIE"
export CPPFLAGS="-I$stage1_root/include"
export LDFLAGS="-L$stage1_root/lib -L$stage1_root/lib64 -no-pie"
export LDFLAGS_FOR_BUILD="-L$stage1_root/lib -L$stage1_root/lib64 -no-pie"
export LIBRARY_PATH="$stage1_root/lib:$stage1_root/lib64"
export LD_LIBRARY_PATH="$sdk_root/aarch64-buildroot-linux-gnu/sysroot/usr/lib:$sdk_root/aarch64-buildroot-linux-gnu/sysroot/lib:$stage1_root/lib:$stage1_root/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$PKG_SOURCE_DIR/configure" --prefix="$stage2_root" --build=aarch64-linux-gnu --host=aarch64-linux-gnu --target=aarch64-linux-gnu --with-sysroot="$glibc_stage_root" --with-build-sysroot="$glibc_stage_root" --with-native-system-header-dir=/usr/include --with-as="$stage1_bin/aarch64-linux-gnu-as" --with-ld="$stage1_bin/aarch64-linux-gnu-ld" --with-gmp="$stage1_root" --with-mpfr="$stage1_root" --with-mpc="$stage1_root" --enable-languages=c,c++ --disable-bootstrap --disable-multilib --disable-nls --disable-libsanitizer --disable-libquadmath --disable-libgomp --disable-libitm --disable-libvtv --disable-libssp --disable-werror --without-isl
make -j"$BUILD_JOBS" all-gcc all-target-libgcc all-target-libstdc++-v3
make DESTDIR="$PKG_DESTDIR" install-gcc install-target-libgcc install-target-libstdc++-v3
cat >"$stage2_dest/bin/selfhost-gcc" <<WRAP
#!/bin/sh
stage1_root="$stage1_root"
stage2_root="$stage2_root"
glibc_stage_root="$glibc_stage_root"
stage1_bin="\$stage1_root/bin"
export PATH="\$stage1_bin:\$PATH"
export LD_LIBRARY_PATH="\$stage2_root/lib64:\$stage2_root/lib:\$stage1_root/lib64:\$stage1_root/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$stage2_root/bin/aarch64-linux-gnu-gcc" -B"\$stage1_bin" --sysroot="\$glibc_stage_root" "\$@"
WRAP
chmod 0755 "$stage2_dest/bin/selfhost-gcc"
cat >"$stage2_dest/bin/selfhost-g++" <<WRAP
#!/bin/sh
stage1_root="$stage1_root"
stage2_root="$stage2_root"
glibc_stage_root="$glibc_stage_root"
stage1_bin="\$stage1_root/bin"
export PATH="\$stage1_bin:\$PATH"
export LD_LIBRARY_PATH="\$stage2_root/lib64:\$stage2_root/lib:\$stage1_root/lib64:\$stage1_root/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$stage2_root/bin/aarch64-linux-gnu-g++" -B"\$stage1_bin" --sysroot="\$glibc_stage_root" "\$@"
WRAP
chmod 0755 "$stage2_dest/bin/selfhost-g++"
cat >"$smoke_dir/hello.cc" <<'SRC'
#include <iostream>
int main() { std::cout << "selfhost-stage2-package" << std::endl; return 0; }
SRC
LD_LIBRARY_PATH="$stage2_dest/lib64:$stage2_dest/lib:$stage1_root/lib64:$stage1_root/lib" "$stage2_dest/bin/aarch64-linux-gnu-g++" -B"$stage1_bin" --sysroot="$glibc_stage_root" "$smoke_dir/hello.cc" -o "$smoke_dir/hello"
LD_LIBRARY_PATH="$stage2_dest/lib64:$stage2_dest/lib:$glibc_stage_root/lib:$glibc_stage_root/usr/lib:$stage1_root/lib64:$stage1_root/lib" "$smoke_dir/hello" >/dev/null
