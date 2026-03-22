#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
SDK_PREFIX="${SDK_PREFIX:-slopos-aarch64-bootstrap-sdk}"
SDK_ARCHIVE="${SDK_ARCHIVE:-$ROOT_DIR/artifacts/toolchain/$SDK_PREFIX.tar.gz}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

if [[ ! -f "$SDK_ARCHIVE" ]]; then
  echo "Missing SDK archive: $SDK_ARCHIVE" >&2
  echo "Run ./scripts/export-bootstrap-sdk.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

guest_cache_dir="$PERSISTENT_MOUNTPOINT/toolchain-cache"
guest_toolchain_root="$PERSISTENT_MOUNTPOINT/toolchain"
guest_archive_path="$guest_cache_dir/$SDK_PREFIX.tar.gz"
guest_sdk_dir="$guest_toolchain_root/$SDK_PREFIX"
guest_current_link="$guest_toolchain_root/current"
guest_smoke_dir="$guest_toolchain_root/smoke-test"

"$ROOT_DIR/scripts/ssh-guest.sh" "mkdir -p '$guest_cache_dir' '$guest_toolchain_root' '$guest_smoke_dir'"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$SDK_ARCHIVE" "$guest_archive_path"

guest_script="$(mktemp)"
trap 'rm -f "$guest_script"' EXIT

cat >"$guest_script" <<EOF
set -eu
mkdir -p "$guest_cache_dir" "$guest_toolchain_root" "$guest_smoke_dir"
rm -rf "$guest_sdk_dir"
gzip -dc "$guest_archive_path" | tar -xf - -C "$guest_toolchain_root"
"$guest_sdk_dir/relocate-sdk.sh" >/dev/null
ln -sfn "$guest_sdk_dir" "$guest_current_link"
cat >"$guest_smoke_dir/hello.c" <<'SRC'
int main(void) { return 0; }
SRC
"$guest_sdk_dir/bin/aarch64-buildroot-linux-gnu-gcc" "$guest_smoke_dir/hello.c" -o "$guest_smoke_dir/hello"
file "$guest_smoke_dir/hello"
"$guest_sdk_dir/bin/aarch64-buildroot-linux-gnu-gcc" --version | head -n 1
EOF

"$ROOT_DIR/scripts/scp-to-guest.sh" "$guest_script" /tmp/install-bootstrap-sdk.sh
"$ROOT_DIR/scripts/ssh-guest.sh" "sh /tmp/install-bootstrap-sdk.sh"

echo "Installed bootstrap SDK at $guest_sdk_dir"
