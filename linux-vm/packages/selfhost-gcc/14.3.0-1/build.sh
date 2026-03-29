#!/bin/bash
set -euo pipefail
: "${SELFHOST_SDK_ROOT:?}"
: "${SELFHOST_STAGE1_ROOT:?}"
: "${SELFHOST_STAGE2_ROOT:?}"
: "${SELFHOST_GLIBC_STAGE_ROOT:?}"
: "${SELFHOST_FINAL_ROOT:?}"
sdk_root="$SELFHOST_SDK_ROOT"
stage1_root="$SELFHOST_STAGE1_ROOT"
stage2_root="$SELFHOST_STAGE2_ROOT"
glibc_stage_root="$SELFHOST_GLIBC_STAGE_ROOT"
final_root="$SELFHOST_FINAL_ROOT"
final_dest="$PKG_DESTDIR$final_root"
stage1_bin="$stage1_root/bin"
stage2_gcc="$stage2_root/bin/selfhost-gcc"
stage2_gxx="$stage2_root/bin/selfhost-g++"
build_dir="$PKG_BUILD_DIR/gcc-final"
smoke_dir="$PKG_BUILD_DIR/smoke-final"
rm -rf "$build_dir" "$smoke_dir"
mkdir -p "$build_dir" "$smoke_dir" "$final_dest"
cd "$build_dir"
export PATH="$sdk_root/bin:$stage2_root/bin:$stage1_bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CONFIG_SHELL=/bin/bash
export MAKEINFO=true
export CC="$stage2_gcc"
export CXX="$stage2_gxx"
export AR="$stage1_bin/aarch64-linux-gnu-ar"
export AS="$stage1_bin/aarch64-linux-gnu-as"
export LD="$stage1_bin/aarch64-linux-gnu-ld"
export RANLIB="$stage1_bin/aarch64-linux-gnu-ranlib"
export CC_FOR_BUILD="$stage2_gcc"
export CXX_FOR_BUILD="$stage2_gxx"
export CFLAGS="-g -O2 -fno-PIE"
export CXXFLAGS="-g -O2 -fno-PIE"
export CFLAGS_FOR_BUILD="-g -O2 -fno-PIE"
export CXXFLAGS_FOR_BUILD="-g -O2 -fno-PIE"
export CPPFLAGS="-I$stage1_root/include"
export LDFLAGS="-L$stage1_root/lib -L$stage1_root/lib64 -no-pie"
export LDFLAGS_FOR_BUILD="-L$stage1_root/lib -L$stage1_root/lib64 -no-pie"
export LIBRARY_PATH="$stage1_root/lib:$stage1_root/lib64"
export LD_LIBRARY_PATH="$stage2_root/lib64:$stage2_root/lib:$stage1_root/lib:$stage1_root/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$PKG_SOURCE_DIR/configure" --prefix="$final_root" --build=aarch64-linux-gnu --host=aarch64-linux-gnu --target=aarch64-linux-gnu --with-sysroot="$glibc_stage_root" --with-build-sysroot="$glibc_stage_root" --with-native-system-header-dir=/usr/include --with-as="$stage1_bin/aarch64-linux-gnu-as" --with-ld="$stage1_bin/aarch64-linux-gnu-ld" --with-gmp="$stage1_root" --with-mpfr="$stage1_root" --with-mpc="$stage1_root" --enable-languages=c,c++ --disable-bootstrap --disable-multilib --disable-nls --disable-libsanitizer --disable-libquadmath --disable-libgomp --disable-libitm --disable-libvtv --disable-libssp --disable-werror --without-isl
make -j"$BUILD_JOBS" all-gcc all-target-libgcc all-target-libstdc++-v3
make DESTDIR="$PKG_DESTDIR" install-gcc install-target-libgcc install-target-libstdc++-v3
cat >"$final_dest/bin/selfhost-gcc" <<WRAP
#!/bin/sh
stage1_root="$stage1_root"
final_root="$final_root"
glibc_stage_root="$glibc_stage_root"
stage1_bin="\$stage1_root/bin"
export PATH="\$stage1_bin:\$PATH"
export LD_LIBRARY_PATH="\$final_root/lib64:\$final_root/lib:\$stage2_root/lib64:\$stage2_root/lib:\$stage1_root/lib64:\$stage1_root/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$final_root/bin/aarch64-linux-gnu-gcc" -B"\$stage1_bin" --sysroot="\$glibc_stage_root" "\$@"
WRAP
chmod 0755 "$final_dest/bin/selfhost-gcc"
cat >"$final_dest/bin/selfhost-g++" <<WRAP
#!/bin/sh
stage1_root="$stage1_root"
final_root="$final_root"
glibc_stage_root="$glibc_stage_root"
stage1_bin="\$stage1_root/bin"
export PATH="\$stage1_bin:\$PATH"
export LD_LIBRARY_PATH="\$final_root/lib64:\$final_root/lib:\$stage2_root/lib64:\$stage2_root/lib:\$stage1_root/lib64:\$stage1_root/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$final_root/bin/aarch64-linux-gnu-g++" -B"\$stage1_bin" --sysroot="\$glibc_stage_root" "\$@"
WRAP
chmod 0755 "$final_dest/bin/selfhost-g++"
mkdir -p "$PKG_DESTDIR/usr/bin" "$PKG_DESTDIR/usr/local/bin"
for base in "$PKG_DESTDIR/usr/bin" "$PKG_DESTDIR/usr/local/bin"; do
  ln -sf "$final_root/bin/selfhost-gcc" "$base/gcc"
  ln -sf "$final_root/bin/selfhost-g++" "$base/g++"
  ln -sf "gcc" "$base/cc"
  ln -sf "g++" "$base/c++"
done
ln -sf "$final_root/bin/selfhost-gcc" "$PKG_DESTDIR/usr/bin/aarch64-linux-gnu-gcc"
ln -sf "$final_root/bin/selfhost-g++" "$PKG_DESTDIR/usr/bin/aarch64-linux-gnu-g++"
cat >"$smoke_dir/hello.cc" <<'SRC'
#include <iostream>
int main() { std::cout << "selfhost-final-package" << std::endl; return 0; }
SRC
LD_LIBRARY_PATH="$final_dest/lib64:$final_dest/lib:$stage2_root/lib64:$stage2_root/lib:$stage1_root/lib64:$stage1_root/lib" "$final_dest/bin/aarch64-linux-gnu-g++" -B"$stage1_bin" --sysroot="$glibc_stage_root" "$smoke_dir/hello.cc" -o "$smoke_dir/hello"
LD_LIBRARY_PATH="$final_dest/lib64:$final_dest/lib:$glibc_stage_root/lib:$glibc_stage_root/usr/lib:$stage2_root/lib64:$stage2_root/lib:$stage1_root/lib64:$stage1_root/lib" "$smoke_dir/hello" >/dev/null
