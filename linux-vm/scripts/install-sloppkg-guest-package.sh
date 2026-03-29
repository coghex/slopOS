#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
TARGET="${TARGET:-aarch64-unknown-linux-gnu}"
TARGET_ENV_NAME="$(printf '%s' "$TARGET" | tr '[:lower:]-' '[:upper:]_')"
LINKER_SCRIPT="$ROOT_DIR/scripts/guest-linker.py"
BUILD_JOBS="${BUILD_JOBS:-1}"
RUSTFLAGS_VALUE="${RUSTFLAGS_VALUE:--C panic=abort}"
STATE_ROOT="${STATE_ROOT:-/Volumes/slopos-data/pkg}"
PACKAGE_NAME="sloppkg"
PACKAGE_RELEASE="${PACKAGE_RELEASE:-1}"
BOOTSTRAP_GUEST_SLOPPKG_BIN="${BOOTSTRAP_GUEST_SLOPPKG_BIN:-/tmp/sloppkg-bootstrap}"
GUEST_SLOPPKG_BIN="${GUEST_SLOPPKG_BIN:-/usr/local/bin/sloppkg}"
PERSISTENT_GUEST_SLOPPKG_BIN="${PERSISTENT_GUEST_SLOPPKG_BIN:-/Volumes/slopos-data/opt/sloppkg/current/bin/sloppkg}"
PUBLISH_GUEST_HTTP_REPO="${PUBLISH_GUEST_HTTP_REPO:-1}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ "$TARGET" != "aarch64-unknown-linux-gnu" ]]; then
  echo "This installer currently supports only aarch64-unknown-linux-gnu, got: $TARGET" >&2
  exit 1
fi

PACKAGE_VERSION="$(
  python3 - <<'PY' "$ROOT_DIR/pkgmgr/Cargo.toml"
import pathlib
import sys
import tomllib

data = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
print(data["workspace"]["package"]["version"])
PY
)"
PACKAGE_DIR_NAME="${PACKAGE_VERSION}-${PACKAGE_RELEASE}"
RECIPE_TEMPLATE_DIR="$ROOT_DIR/packages/$PACKAGE_NAME/$PACKAGE_DIR_NAME"

if [[ ! -f "$RECIPE_TEMPLATE_DIR/package.toml" ]]; then
  echo "Missing recipe template: $RECIPE_TEMPLATE_DIR/package.toml" >&2
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
if path.read_bytes()[:4] != b"\x7fELF":
    raise SystemExit(f"{path} is not an ELF binary")
print(f"Built ELF guest binary: {path}")
PY

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

staged_recipe_dir="$tmp_dir/$PACKAGE_NAME/$PACKAGE_DIR_NAME"
mkdir -p "$staged_recipe_dir/payload"
cp "$RECIPE_TEMPLATE_DIR/package.toml" "$staged_recipe_dir/package.toml"
cp "$OUTPUT_PATH" "$staged_recipe_dir/payload/sloppkg"

guest_recipe_root="${GUEST_RECIPE_ROOT:-$PERSISTENT_MOUNTPOINT/packages}"
guest_package_dir="$guest_recipe_root/$PACKAGE_NAME/$PACKAGE_DIR_NAME"
guest_package_parent="$(dirname "$guest_package_dir")"
guest_bin_parent="$(dirname "$GUEST_SLOPPKG_BIN")"
bootstrap_bin_parent="$(dirname "$BOOTSTRAP_GUEST_SLOPPKG_BIN")"
constraint="=${PACKAGE_VERSION}-${PACKAGE_RELEASE}"

"$ROOT_DIR/scripts/ssh-guest.sh" "rm -rf '$guest_package_dir' && mkdir -p '$guest_package_dir/payload' '$bootstrap_bin_parent' '$guest_bin_parent'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$staged_recipe_dir/package.toml" "$guest_package_dir/package.toml"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$OUTPUT_PATH" "$guest_package_dir/payload/sloppkg"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$OUTPUT_PATH" "$BOOTSTRAP_GUEST_SLOPPKG_BIN"
"$ROOT_DIR/scripts/ssh-guest.sh" \
  "chmod 0755 '$BOOTSTRAP_GUEST_SLOPPKG_BIN' && mkdir -p '$STATE_ROOT' && '$BOOTSTRAP_GUEST_SLOPPKG_BIN' --state-root '$STATE_ROOT' --recipe-root '$guest_recipe_root' build '$PACKAGE_NAME' --constraint '$constraint' && '$BOOTSTRAP_GUEST_SLOPPKG_BIN' --state-root '$STATE_ROOT' --recipe-root '$guest_recipe_root' install '$PACKAGE_NAME' --constraint '$constraint' --root / && if [ -x /etc/init.d/S16persistent-sloppkg ]; then /etc/init.d/S16persistent-sloppkg; elif [ -x '$PERSISTENT_GUEST_SLOPPKG_BIN' ]; then ln -sf '$PERSISTENT_GUEST_SLOPPKG_BIN' '$GUEST_SLOPPKG_BIN'; fi && '$GUEST_SLOPPKG_BIN' --help >/dev/null && rm -f '$BOOTSTRAP_GUEST_SLOPPKG_BIN'"

echo "Installed managed guest sloppkg package $PACKAGE_VERSION-$PACKAGE_RELEASE"
echo "Guest recipe: $guest_package_dir"

if [[ "$PUBLISH_GUEST_HTTP_REPO" == "1" ]]; then
  "$ROOT_DIR/scripts/publish-guest-http-repo.sh"
fi
