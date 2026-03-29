#!/usr/bin/env bash
set -euo pipefail

echo "warning: build-selfhost-libs.sh is a legacy/manual helper." >&2
echo "warning: preferred workflow: /usr/local/bin/sloppkg --state-root /Volumes/slopos-data/pkg install selfhost-toolchain --root /" >&2

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_GMP_ARCHIVE_PATH="${LOCAL_GMP_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/gmp/gmp-6.3.0.tar.xz}"
LOCAL_MPFR_ARCHIVE_PATH="${LOCAL_MPFR_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/mpfr/mpfr-4.1.1.tar.xz}"
LOCAL_MPC_ARCHIVE_PATH="${LOCAL_MPC_ARCHIVE_PATH:-$ROOT_DIR/buildroot-src/dl/mpc/mpc-1.3.1.tar.gz}"
GMP_ARCHIVE="${GMP_ARCHIVE:-$(basename "$LOCAL_GMP_ARCHIVE_PATH")}"
MPFR_ARCHIVE="${MPFR_ARCHIVE:-$(basename "$LOCAL_MPFR_ARCHIVE_PATH")}"
MPC_ARCHIVE="${MPC_ARCHIVE:-$(basename "$LOCAL_MPC_ARCHIVE_PATH")}"
SOURCE_ROOT="${SOURCE_ROOT:-/Volumes/slopos-data/toolchain/sources}"
BUILD_ROOT="${BUILD_ROOT:-/Volumes/slopos-data/toolchain/build}"
SELFHOST_ROOT="${SELFHOST_ROOT:-/Volumes/slopos-data/toolchain/selfhost-stage1}"
GLIBC_STAGE_ROOT="${GLIBC_STAGE_ROOT:-/Volumes/slopos-data/toolchain/glibc-stage}"
NATIVE_BINUTILS_ROOT="${NATIVE_BINUTILS_ROOT:-/Volumes/slopos-data/toolchain/native}"
SDK_ROOT="${SDK_ROOT:-/Volumes/slopos-data/toolchain/current}"
BUILD_JOBS="${BUILD_JOBS:-2}"

for archive in \
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

gmp_archive=$(printf '%q' "$GMP_ARCHIVE")
mpfr_archive=$(printf '%q' "$MPFR_ARCHIVE")
mpc_archive=$(printf '%q' "$MPC_ARCHIVE")
source_root=$(printf '%q' "$SOURCE_ROOT")
build_root=$(printf '%q' "$BUILD_ROOT")
selfhost_root=$(printf '%q' "$SELFHOST_ROOT")
glibc_stage_root=$(printf '%q' "$GLIBC_STAGE_ROOT")
native_binutils_root=$(printf '%q' "$NATIVE_BINUTILS_ROOT")
sdk_root=$(printf '%q' "$SDK_ROOT")
build_jobs=$(printf '%q' "$BUILD_JOBS")

compiler=/usr/bin/gcc
ar="\$native_binutils_root/bin/aarch64-linux-gnu-ar"
ranlib="\$native_binutils_root/bin/aarch64-linux-gnu-ranlib"
strip="\$native_binutils_root/bin/aarch64-linux-gnu-strip"
smoke_dir="\$build_root/selfhost-smoke"

for tool in "\$compiler" "\$ar" "\$ranlib" "\$strip"; do
  if [[ ! -x "\$tool" ]]; then
    echo "Missing required tool: \$tool" >&2
    exit 1
  fi
done

mkdir -p "\$source_root" "\$build_root"
rm -rf "\$selfhost_root" "\$smoke_dir"
mkdir -p "\$selfhost_root" "\$smoke_dir"

gmp_archive_path="\$source_root/\$gmp_archive"
mpfr_archive_path="\$source_root/\$mpfr_archive"
mpc_archive_path="\$source_root/\$mpc_archive"

set +o pipefail
gmp_source_dir="\$source_root/\$(tar -tf "\$gmp_archive_path" | head -n 1 | cut -d/ -f1)"
mpfr_source_dir="\$source_root/\$(tar -tf "\$mpfr_archive_path" | head -n 1 | cut -d/ -f1)"
mpc_source_dir="\$source_root/\$(tar -tf "\$mpc_archive_path" | head -n 1 | cut -d/ -f1)"
set -o pipefail

for dir in "\$gmp_source_dir" "\$mpfr_source_dir" "\$mpc_source_dir"; do
  archive_path=
  case "\$dir" in
    "\$gmp_source_dir") archive_path="\$gmp_archive_path" ;;
    "\$mpfr_source_dir") archive_path="\$mpfr_archive_path" ;;
    "\$mpc_source_dir") archive_path="\$mpc_archive_path" ;;
  esac
  if [[ ! -d "\$dir" ]]; then
    tar -xf "\$archive_path" -C "\$source_root"
  fi
done

build_one() {
  local name="\$1"
  local source_dir="\$2"
  local build_dir="\$3"
  shift 3

  rm -rf "\$build_dir"
  mkdir -p "\$build_dir"
  cd "\$build_dir"

  export PATH="\$sdk_root/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export CC="\$compiler"
  export AR="\$ar"
  export RANLIB="\$ranlib"
  export STRIP="\$strip"
  export CPPFLAGS="-I\$selfhost_root/include"
  export LDFLAGS="-L\$selfhost_root/lib -L\$selfhost_root/lib64"
  export LD_LIBRARY_PATH="\$selfhost_root/lib:\$selfhost_root/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

  "\$source_dir/configure" --prefix="\$selfhost_root" "\$@"
  make -j"\$build_jobs"
  make install
}

build_one gmp "\$gmp_source_dir" "\$build_root/gmp-selfhost-build"
build_one mpfr "\$mpfr_source_dir" "\$build_root/mpfr-selfhost-build" --with-gmp="\$selfhost_root"
build_one mpc "\$mpc_source_dir" "\$build_root/mpc-selfhost-build" --with-gmp="\$selfhost_root" --with-mpfr="\$selfhost_root"

cat >"\$smoke_dir/math-libs.c" <<'SRC'
#include <gmp.h>
#include <mpfr.h>
#include <mpc.h>
#include <stdio.h>

int main(void) {
  mpz_t z;
  mpfr_t f;
  mpc_t c;

  mpz_init_set_ui(z, 42);
  mpfr_init2(f, 128);
  mpc_init2(c, 128);

  mpfr_set_z(f, z, MPFR_RNDN);
  mpc_set_fr_fr(c, f, f, MPC_RNDNN);
  printf("selfhost-libs-ok %lu\n", mpz_get_ui(z));

  mpc_clear(c);
  mpfr_clear(f);
  mpz_clear(z);
  return 0;
}
SRC

gcc \
  -I"\$selfhost_root/include" \
  -L"\$selfhost_root/lib" \
  -L"\$selfhost_root/lib64" \
  "\$smoke_dir/math-libs.c" \
  -lgmp -lmpfr -lmpc \
  -o "\$smoke_dir/math-libs"

LD_LIBRARY_PATH="\$selfhost_root/lib:\$selfhost_root/lib64:\$glibc_stage_root/lib:\$glibc_stage_root/usr/lib" \
  "\$smoke_dir/math-libs"

/usr/bin/file "\$selfhost_root/lib/libgmp.so" "\$selfhost_root/lib/libmpfr.so" "\$selfhost_root/lib/libmpc.so" 2>/dev/null || true
EOF

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$SOURCE_ROOT'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_GMP_ARCHIVE_PATH" "$SOURCE_ROOT/$GMP_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_MPFR_ARCHIVE_PATH" "$SOURCE_ROOT/$MPFR_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$LOCAL_MPC_ARCHIVE_PATH" "$SOURCE_ROOT/$MPC_ARCHIVE"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$guest_script" /tmp/build-selfhost-libs.sh
"$ROOT_DIR/scripts/ssh-guest.sh" "bash /tmp/build-selfhost-libs.sh"
