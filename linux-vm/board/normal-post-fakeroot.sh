#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMAL_SEED_TREE="$SCRIPT_DIR/normal-rootfs-tree"
PRUNE_MANIFEST="$NORMAL_SEED_TREE/usr/share/slopos/normal-post-fakeroot-prune.toml"
MUTABLE_OVERLAY_DIR="$SCRIPT_DIR/rootfs-overlay"
MUTABLE_AUTHORIZED_KEYS="$MUTABLE_OVERLAY_DIR/root/.ssh/authorized_keys"
BUSYBOX_BIN="$TARGET_DIR/bin/busybox"
removed=0

if [[ ! -d "$NORMAL_SEED_TREE" ]]; then
  echo "missing normal seed tree: $NORMAL_SEED_TREE" >&2
  exit 1
fi

if [[ ! -f "$PRUNE_MANIFEST" ]]; then
  echo "missing normal post-fakeroot prune manifest: $PRUNE_MANIFEST" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "missing required tool: python3" >&2
  exit 1
fi

load_prune_manifest_list() {
  local key="$1"

  python3 - "$PRUNE_MANIFEST" "$key" <<'PY'
import sys
import tomllib

manifest_path = sys.argv[1]
key = sys.argv[2]

with open(manifest_path, "rb") as fh:
    manifest = tomllib.load(fh)

for item in manifest[key]:
    print(item)
PY
}

prune_busybox_path() {
  local target="$1"

  if [[ ! -L "$target" ]]; then
    return 0
  fi

  if [[ "$(readlink -f "$target")" != "$BUSYBOX_BIN" ]]; then
    return 0
  fi

  rm -f "$target"
  ((removed += 1))
}

remove_path_if_present() {
  local target="$1"

  if [[ ! -e "$target" && ! -L "$target" ]]; then
    return 0
  fi

  rm -f "$target"
  ((removed += 1))
}

install_normal_seed_tree() {
  local source
  local relative
  local destination
  local mode

  while IFS= read -r -d '' source; do
    relative="${source#$NORMAL_SEED_TREE/}"
    destination="$TARGET_DIR/$relative"
    install -d -m 0755 "$destination"
  done < <(find "$NORMAL_SEED_TREE" -type d -print0)

  while IFS= read -r -d '' source; do
    relative="${source#$NORMAL_SEED_TREE/}"
    destination="$TARGET_DIR/$relative"
    rm -f "$destination"
    if [[ -x "$source" ]]; then
      mode=0755
    else
      mode=0644
    fi
    install -D -m "$mode" "$source" "$destination"
  done < <(find "$NORMAL_SEED_TREE" -type f -print0)

  while IFS= read -r -d '' source; do
    relative="${source#$NORMAL_SEED_TREE/}"
    destination="$TARGET_DIR/$relative"
    rm -f "$destination"
    install -d -m 0755 "$(dirname "$destination")"
    ln -snf "$(readlink "$source")" "$destination"
  done < <(find "$NORMAL_SEED_TREE" -type l -print0)
}

install_mutable_seed_inputs() {
  if [[ -f "$MUTABLE_AUTHORIZED_KEYS" ]]; then
    install -d -m 0700 "$TARGET_DIR/root/.ssh"
    install -m 0600 "$MUTABLE_AUTHORIZED_KEYS" "$TARGET_DIR/root/.ssh/authorized_keys"
  else
    rm -f "$TARGET_DIR/root/.ssh/authorized_keys"
  fi
}

install_normal_seed_tree
install_mutable_seed_inputs

mapfile -t busybox_link_paths < <(load_prune_manifest_list busybox_link_paths)
for path in "${busybox_link_paths[@]}"; do
  prune_busybox_path "$TARGET_DIR$path"
done

mapfile -t remove_paths < <(load_prune_manifest_list remove_paths)
for path in "${remove_paths[@]}"; do
  remove_path_if_present "$TARGET_DIR$path"
done

if [[ -x "$TARGET_DIR/usr/sbin/ifup" ]]; then
  ln -snf /usr/sbin/ifup "$TARGET_DIR/sbin/ifup"
fi

if [[ -e "$TARGET_DIR/usr/sbin/ifdown" || -L "$TARGET_DIR/usr/sbin/ifdown" ]]; then
  ln -snf /usr/sbin/ifdown "$TARGET_DIR/sbin/ifdown"
fi

if [[ -x "$TARGET_DIR/sbin/agetty" ]]; then
  ln -snf /sbin/agetty "$TARGET_DIR/sbin/getty"
fi

if [[ -f "$TARGET_DIR/etc/shells" ]] && grep -qx '/bin/ash' "$TARGET_DIR/etc/shells"; then
  grep -vx '/bin/ash' "$TARGET_DIR/etc/shells" > "$TARGET_DIR/etc/shells.tmp"
  mv "$TARGET_DIR/etc/shells.tmp" "$TARGET_DIR/etc/shells"
fi

if [[ -x "$TARGET_DIR/sbin/syslogd" && ! -e "$TARGET_DIR/sbin/klogd" ]]; then
  rm -f "$TARGET_DIR/etc/init.d/S02klogd"
fi

if [[ -x "$TARGET_DIR/usr/sbin/crond" ]]; then
  rm -f "$TARGET_DIR/etc/init.d/S50crond"
fi

if (( removed > 0 )); then
  echo "Pruned $removed stale BusyBox paths from seed image"
fi
