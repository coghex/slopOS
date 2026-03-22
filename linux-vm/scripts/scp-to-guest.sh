#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
KNOWN_HOSTS_FILE="$ROOT_DIR/qemu/known_hosts"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <local-path> [guest-path]" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

if [[ ! -f "$IDENTITY_PATH_FILE" ]]; then
  echo "Missing SSH identity path file: $IDENTITY_PATH_FILE" >&2
  echo "Run ./scripts/build-phase2-lima.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
read -r IDENTITY_FILE < "$IDENTITY_PATH_FILE"

if [[ ! -f "$IDENTITY_FILE" ]]; then
  echo "Missing SSH identity file: $IDENTITY_FILE" >&2
  exit 1
fi

SOURCE_PATH="$1"
TARGET_PATH="${2:-$PERSISTENT_MOUNTPOINT/}"
SCP_ARGS=()

if [[ ! -e "$SOURCE_PATH" ]]; then
  echo "Source path does not exist: $SOURCE_PATH" >&2
  exit 1
fi

if [[ -d "$SOURCE_PATH" ]]; then
  SCP_ARGS+=(-r)
fi

mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"

exec scp \
  -O \
  "${SCP_ARGS[@]}" \
  -i "$IDENTITY_FILE" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -P "$GUEST_SSH_FORWARD_PORT" \
  "$SOURCE_PATH" \
  "root@127.0.0.1:$TARGET_PATH"
