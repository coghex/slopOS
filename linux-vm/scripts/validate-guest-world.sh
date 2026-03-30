#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
VALIDATION_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-validate-managed-world"
PUBLISH_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-publish-http-repo"
OVERRIDE_GUEST_SSH_FORWARD_PORT="${GUEST_SSH_FORWARD_PORT:-}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ -n "$OVERRIDE_GUEST_SSH_FORWARD_PORT" ]]; then
  GUEST_SSH_FORWARD_PORT="$OVERRIDE_GUEST_SSH_FORWARD_PORT"
fi

STATE_ROOT="${STATE_ROOT:-$PERSISTENT_MOUNTPOINT/pkg}"
GUEST_HTTP_REPO_PORT="${GUEST_HTTP_REPO_PORT:-18083}"
GUEST_HTTP_REPO_BIND="${GUEST_HTTP_REPO_BIND:-127.0.0.1}"
GUEST_HTTP_REPO_ROOT="${GUEST_HTTP_REPO_ROOT:-$STATE_ROOT/published/${REPO_NAME:-workspace}/live}"
GUEST_SLOPPKG_BIN="${GUEST_SLOPPKG_BIN:-/usr/local/bin/sloppkg}"
CANONICAL_WORLD_TARGET="${CANONICAL_WORLD_TARGET:-selfhost-world}"
PID_FILE="${PID_FILE:-$STATE_ROOT/http-repo.pid}"
LOG_FILE="${LOG_FILE:-$STATE_ROOT/http-repo.log}"
GUEST_VALIDATION_HELPER_DEST="${GUEST_VALIDATION_HELPER_DEST:-/tmp/slopos-validate-managed-world}"
GUEST_PUBLISH_HELPER_DEST="${GUEST_PUBLISH_HELPER_DEST:-/tmp/slopos-publish-http-repo}"

"$ROOT_DIR/scripts/scp-to-guest.sh" "$VALIDATION_HELPER_SOURCE" "$GUEST_VALIDATION_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$PUBLISH_HELPER_SOURCE" "$GUEST_PUBLISH_HELPER_DEST"

"$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- \
  "$GUEST_VALIDATION_HELPER_DEST" \
  "$GUEST_PUBLISH_HELPER_DEST" \
  "$STATE_ROOT" \
  "$PERSISTENT_MOUNTPOINT" \
  "$GUEST_HTTP_REPO_ROOT" \
  "$GUEST_HTTP_REPO_PORT" \
  "$GUEST_HTTP_REPO_BIND" \
  "$GUEST_SLOPPKG_BIN" \
  "$CANONICAL_WORLD_TARGET" \
  "$PID_FILE" \
  "$LOG_FILE" \
  "$@" <<'EOF'
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

validation_helper="$1"
shift
publish_helper="$1"
shift
state_root="$1"
shift
persistent_mountpoint="$1"
shift
guest_http_repo_root="$1"
shift
guest_http_repo_port="$1"
shift
guest_http_repo_bind="$1"
shift
guest_sloppkg_bin="$1"
shift
canonical_world_target="$1"
shift
pid_file="$1"
shift
log_file="$1"
shift

chmod 0755 "$validation_helper" "$publish_helper"
env \
  STATE_ROOT="$state_root" \
  PERSISTENT_MOUNTPOINT="$persistent_mountpoint" \
  GUEST_HTTP_REPO_ROOT="$guest_http_repo_root" \
  GUEST_HTTP_REPO_PORT="$guest_http_repo_port" \
  GUEST_HTTP_REPO_BIND="$guest_http_repo_bind" \
  GUEST_SLOPPKG_BIN="$guest_sloppkg_bin" \
  CANONICAL_WORLD_TARGET="$canonical_world_target" \
  PID_FILE="$pid_file" \
  LOG_FILE="$log_file" \
  SLOPOS_PUBLISH_HTTP_REPO="$publish_helper" \
  "$validation_helper" "$@"
EOF
