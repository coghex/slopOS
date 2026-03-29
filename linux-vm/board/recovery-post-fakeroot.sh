#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${O:-}"

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "expected Buildroot O= output directory in environment" >&2
  exit 1
fi

TARGET_CC="$OUTPUT_DIR/host/bin/aarch64-buildroot-linux-gnu-gcc"
TARGET_STRIP="$OUTPUT_DIR/host/bin/aarch64-buildroot-linux-gnu-strip"
RECOVERY_INIT_SOURCE="$SCRIPT_DIR/recovery-init.c"
RECOVERY_TOOLBOX_SOURCE="$SCRIPT_DIR/recovery-toolbox.c"
RECOVERY_ROOTFS_TREE="$SCRIPT_DIR/recovery-rootfs-tree"

if [[ ! -x "$TARGET_CC" ]]; then
  echo "expected target compiler at $TARGET_CC" >&2
  exit 1
fi

if [[ ! -x "$TARGET_STRIP" ]]; then
  echo "expected target strip at $TARGET_STRIP" >&2
  exit 1
fi

if [[ ! -f "$RECOVERY_INIT_SOURCE" ]]; then
  echo "missing recovery init source: $RECOVERY_INIT_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$RECOVERY_TOOLBOX_SOURCE" ]]; then
  echo "missing recovery toolbox source: $RECOVERY_TOOLBOX_SOURCE" >&2
  exit 1
fi

if [[ ! -d "$RECOVERY_ROOTFS_TREE" ]]; then
  echo "missing recovery rootfs tree: $RECOVERY_ROOTFS_TREE" >&2
  exit 1
fi

find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

install -d -m 0755 \
  "$TARGET_DIR/bin" \
  "$TARGET_DIR/dev" \
  "$TARGET_DIR/etc" \
  "$TARGET_DIR/proc" \
  "$TARGET_DIR/recovery" \
  "$TARGET_DIR/root" \
  "$TARGET_DIR/sys"

install -m 0644 "$RECOVERY_ROOTFS_TREE/etc/passwd" "$TARGET_DIR/etc/passwd"
install -m 0644 "$RECOVERY_ROOTFS_TREE/etc/shells" "$TARGET_DIR/etc/shells"

"$TARGET_CC" -D_GNU_SOURCE -Os -static -ffunction-sections -fdata-sections \
  "$RECOVERY_TOOLBOX_SOURCE" -Wl,--gc-sections -o "$TARGET_DIR/recovery/toolbox"
"$TARGET_CC" -D_GNU_SOURCE -Os -static -ffunction-sections -fdata-sections \
  "$RECOVERY_INIT_SOURCE" -Wl,--gc-sections -o "$TARGET_DIR/init"
"$TARGET_STRIP" "$TARGET_DIR/recovery/toolbox" "$TARGET_DIR/init"

for applet in help sh ls cat dmesg sysctl uname lsmod poweroff reboot; do
  ln -snf /recovery/toolbox "$TARGET_DIR/bin/$applet"
done

chmod 0755 "$TARGET_DIR/init" "$TARGET_DIR/recovery/toolbox"
