#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
PUBLISH_HELPER_SOURCE="$ROOT_DIR/board/rootfs-overlay/usr/sbin/slopos-publish-http-repo"
SYNC_HELPER_SOURCE="$ROOT_DIR/board/rootfs-overlay/usr/sbin/slopos-sync-world"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

STATE_ROOT="${STATE_ROOT:-$PERSISTENT_MOUNTPOINT/pkg}"
GUEST_RECIPE_ROOT="${GUEST_RECIPE_ROOT:-$PERSISTENT_MOUNTPOINT/packages}"
GUEST_HTTP_REPO_PORT="${GUEST_HTTP_REPO_PORT:-18083}"
GUEST_HTTP_REPO_BIND="${GUEST_HTTP_REPO_BIND:-127.0.0.1}"
REPO_NAME="${REPO_NAME:-workspace}"
CHANNEL="${CHANNEL:-stable}"
REVISION="${REVISION:-}"
REMOTE_REVISION="${REVISION:-__AUTO_REVISION__}"
GUEST_HTTP_REPO_ROOT="${GUEST_HTTP_REPO_ROOT:-$STATE_ROOT/published/$REPO_NAME/live}"
GUEST_SLOPPKG_BIN="${GUEST_SLOPPKG_BIN:-/usr/local/bin/sloppkg}"
PID_FILE="${PID_FILE:-$STATE_ROOT/http-repo.pid}"
LOG_FILE="${LOG_FILE:-$STATE_ROOT/http-repo.log}"
GUEST_PUBLISH_HELPER_DEST="${GUEST_PUBLISH_HELPER_DEST:-/tmp/slopos-publish-http-repo}"
GUEST_SYNC_HELPER_DEST="${GUEST_SYNC_HELPER_DEST:-/tmp/slopos-sync-world}"

"$ROOT_DIR/scripts/scp-to-guest.sh" "$PUBLISH_HELPER_SOURCE" "$GUEST_PUBLISH_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$SYNC_HELPER_SOURCE" "$GUEST_SYNC_HELPER_DEST"

"$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- \
  "$GUEST_PUBLISH_HELPER_DEST" \
  "$GUEST_SYNC_HELPER_DEST" \
  "$STATE_ROOT" \
  "$GUEST_RECIPE_ROOT" \
  "$GUEST_HTTP_REPO_ROOT" \
  "$GUEST_HTTP_REPO_PORT" \
  "$GUEST_HTTP_REPO_BIND" \
  "$REPO_NAME" \
  "$CHANNEL" \
  "$REMOTE_REVISION" \
  "$GUEST_SLOPPKG_BIN" \
  "$PID_FILE" \
  "$LOG_FILE" \
  "$@" <<'EOF'
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

publish_helper="$1"
shift
sync_helper="$1"
shift
state_root="$1"
shift
guest_recipe_root="$1"
shift
guest_http_repo_root="$1"
shift
guest_http_repo_port="$1"
shift
guest_http_repo_bind="$1"
shift
repo_name="$1"
shift
channel="$1"
shift
revision="$1"
shift
guest_sloppkg_bin="$1"
shift
pid_file="$1"
shift
log_file="$1"
shift

if [ "$revision" = "__AUTO_REVISION__" ]; then
  revision=""
fi

chmod 0755 "$publish_helper" "$sync_helper"
env \
  STATE_ROOT="$state_root" \
  GUEST_RECIPE_ROOT="$guest_recipe_root" \
  GUEST_HTTP_REPO_ROOT="$guest_http_repo_root" \
  GUEST_HTTP_REPO_PORT="$guest_http_repo_port" \
  GUEST_HTTP_REPO_BIND="$guest_http_repo_bind" \
  REPO_NAME="$repo_name" \
  CHANNEL="$channel" \
  REVISION="$revision" \
  GUEST_SLOPPKG_BIN="$guest_sloppkg_bin" \
  PID_FILE="$pid_file" \
  LOG_FILE="$log_file" \
  SLOPOS_PUBLISH_HTTP_REPO="$publish_helper" \
  "$sync_helper" "$@"
EOF
