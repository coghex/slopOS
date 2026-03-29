#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${TARGET:-aarch64-unknown-linux-gnu}"
TARGET_ENV_NAME="$(printf '%s' "$TARGET" | tr '[:lower:]-' '[:upper:]_')"
LINKER_SCRIPT="$ROOT_DIR/scripts/guest-linker.py"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/sloppkg}"
RUSTFLAGS_VALUE="${RUSTFLAGS_VALUE:--C panic=abort}"
BUILD_JOBS="${BUILD_JOBS:-1}"

if [[ "$TARGET" != "aarch64-unknown-linux-gnu" ]]; then
  echo "This bootstrap script currently supports only aarch64-unknown-linux-gnu, got: $TARGET" >&2
  exit 1
fi

chmod 0755 "$LINKER_SCRIPT"

export RUSTC_BOOTSTRAP=1
export RUSTFLAGS="$RUSTFLAGS_VALUE"
export SLOPOS_GUEST_TOOL="${SLOPOS_GUEST_TOOL:-/Volumes/slopos-data/toolchain/selfhost-sysroot/final/bin/selfhost-gcc}"
export "CARGO_TARGET_${TARGET_ENV_NAME}_LINKER=$LINKER_SCRIPT"
export CC_aarch64_unknown_linux_gnu="$LINKER_SCRIPT"
export CXX_aarch64_unknown_linux_gnu="$LINKER_SCRIPT"

cargo build \
  --manifest-path "$ROOT_DIR/pkgmgr/Cargo.toml" \
  -p sloppkg-cli \
  --bin sloppkg \
  --release \
  -j "$BUILD_JOBS" \
  --target "$TARGET" \
  -Z build-std=std,panic_abort \
  -Z build-std-features=panic_immediate_abort

OUTPUT_PATH="$ROOT_DIR/pkgmgr/target/$TARGET/release/sloppkg"
if [[ ! -f "$OUTPUT_PATH" ]]; then
  echo "Expected output missing: $OUTPUT_PATH" >&2
  exit 1
fi

python3 - <<'PY' "$OUTPUT_PATH"
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()[:4]
if data != b"\x7fELF":
    raise SystemExit(f"{path} is not an ELF binary")
print(f"Built ELF guest binary: {path}")
PY

"$ROOT_DIR/scripts/scp-to-guest.sh" "$OUTPUT_PATH" "$INSTALL_PATH"
"$ROOT_DIR/scripts/ssh-guest.sh" "chmod 0755 '$INSTALL_PATH' && '$INSTALL_PATH' --help >/dev/null"

echo "Installed guest sloppkg to $INSTALL_PATH"
