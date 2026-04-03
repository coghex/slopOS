#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
REBUILD_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-rebuild-world"
READINESS_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-validate-rebuild-readiness"
VALIDATION_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-validate-managed-world"
PUBLISH_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-publish-http-repo"
SYNC_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-sync-world"
BUILD_SLOPPKG_GUEST_SCRIPT="$ROOT_DIR/scripts/build-sloppkg-guest.sh"
HOST_RECIPE_ROOT="${HOST_RECIPE_ROOT:-$ROOT_DIR/packages}"
OVERRIDE_GUEST_SSH_FORWARD_PORT="${GUEST_SSH_FORWARD_PORT:-}"
SLOPPKG_RECIPE_DIR="$(find "$HOST_RECIPE_ROOT/sloppkg" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1 || true)"

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
GUEST_RECIPE_ROOT="${GUEST_RECIPE_ROOT:-$PERSISTENT_MOUNTPOINT/packages}"
STAGE_CURRENT_RECIPE_ROOT="${STAGE_CURRENT_RECIPE_ROOT:-1}"
STAGED_GUEST_RECIPE_ROOT="${STAGED_GUEST_RECIPE_ROOT:-/tmp/packages}"
GUEST_HTTP_REPO_PORT="${GUEST_HTTP_REPO_PORT:-18083}"
GUEST_HTTP_REPO_BIND="${GUEST_HTTP_REPO_BIND:-127.0.0.1}"
STABLE_REPO_NAME="${STABLE_REPO_NAME:-${REPO_NAME:-workspace}}"
STABLE_CHANNEL="${STABLE_CHANNEL:-${CHANNEL:-stable}}"
STABLE_REVISION="${STABLE_REVISION:-${REVISION:-}}"
CANDIDATE_REPO_NAME="${CANDIDATE_REPO_NAME:-${STABLE_REPO_NAME}-candidate}"
CANDIDATE_CHANNEL="${CANDIDATE_CHANNEL:-candidate}"
CANDIDATE_REVISION="${CANDIDATE_REVISION:-}"
REMOTE_STABLE_REVISION="${STABLE_REVISION:-__AUTO_REVISION__}"
REMOTE_CANDIDATE_REVISION="${CANDIDATE_REVISION:-__AUTO_REVISION__}"
GUEST_HTTP_REPO_ROOT="${GUEST_HTTP_REPO_ROOT:-$STATE_ROOT/published/$CANDIDATE_REPO_NAME/live}"
GUEST_SLOPPKG_BIN="${GUEST_SLOPPKG_BIN:-/usr/local/bin/sloppkg}"
STAGE_CURRENT_SLOPPKG="${STAGE_CURRENT_SLOPPKG:-1}"
STAGED_GUEST_SLOPPKG_BIN="${STAGED_GUEST_SLOPPKG_BIN:-/tmp/sloppkg-rebuild-world}"
CANONICAL_WORLD_TARGET="${CANONICAL_WORLD_TARGET:-selfhost-world}"
PID_FILE="${PID_FILE:-$STATE_ROOT/http-repo.pid}"
LOG_FILE="${LOG_FILE:-$STATE_ROOT/http-repo.log}"
GUEST_REBUILD_HELPER_DEST="${GUEST_REBUILD_HELPER_DEST:-/tmp/slopos-rebuild-world}"
GUEST_READINESS_HELPER_DEST="${GUEST_READINESS_HELPER_DEST:-/tmp/slopos-validate-rebuild-readiness}"
GUEST_VALIDATION_HELPER_DEST="${GUEST_VALIDATION_HELPER_DEST:-/tmp/slopos-validate-managed-world}"
GUEST_PUBLISH_HELPER_DEST="${GUEST_PUBLISH_HELPER_DEST:-/tmp/slopos-publish-http-repo}"
GUEST_SYNC_HELPER_DEST="${GUEST_SYNC_HELPER_DEST:-/tmp/slopos-sync-world}"

if [[ "$STAGE_CURRENT_SLOPPKG" == "1" ]]; then
  INSTALL_PATH="$STAGED_GUEST_SLOPPKG_BIN" "$BUILD_SLOPPKG_GUEST_SCRIPT" >/dev/null
  GUEST_SLOPPKG_BIN="$STAGED_GUEST_SLOPPKG_BIN"
fi

if [[ "$STAGE_CURRENT_RECIPE_ROOT" == "1" ]]; then
  "$ROOT_DIR/scripts/ssh-guest.sh" "rm -rf '$STAGED_GUEST_RECIPE_ROOT'"
  "$ROOT_DIR/scripts/scp-to-guest.sh" "$HOST_RECIPE_ROOT" "$(dirname "$STAGED_GUEST_RECIPE_ROOT")/"
  if [[ -n "$SLOPPKG_RECIPE_DIR" ]]; then
    sloppkg_recipe_basename="$(basename "$SLOPPKG_RECIPE_DIR")"
    "$ROOT_DIR/scripts/ssh-guest.sh" \
      "test -f '$GUEST_SLOPPKG_BIN' && mkdir -p '$STAGED_GUEST_RECIPE_ROOT/sloppkg/$sloppkg_recipe_basename/payload' && install -m 0755 '$GUEST_SLOPPKG_BIN' '$STAGED_GUEST_RECIPE_ROOT/sloppkg/$sloppkg_recipe_basename/payload/sloppkg'"
  fi
  GUEST_RECIPE_ROOT="$STAGED_GUEST_RECIPE_ROOT"
fi

"$ROOT_DIR/scripts/scp-to-guest.sh" "$REBUILD_HELPER_SOURCE" "$GUEST_REBUILD_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$READINESS_HELPER_SOURCE" "$GUEST_READINESS_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$VALIDATION_HELPER_SOURCE" "$GUEST_VALIDATION_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$PUBLISH_HELPER_SOURCE" "$GUEST_PUBLISH_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$SYNC_HELPER_SOURCE" "$GUEST_SYNC_HELPER_DEST"

"$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- \
  "$GUEST_REBUILD_HELPER_DEST" \
  "$GUEST_READINESS_HELPER_DEST" \
  "$GUEST_VALIDATION_HELPER_DEST" \
  "$GUEST_PUBLISH_HELPER_DEST" \
  "$GUEST_SYNC_HELPER_DEST" \
  "$STATE_ROOT" \
  "$GUEST_RECIPE_ROOT" \
  "$GUEST_HTTP_REPO_ROOT" \
  "$GUEST_HTTP_REPO_PORT" \
  "$GUEST_HTTP_REPO_BIND" \
  "$STABLE_REPO_NAME" \
  "$STABLE_CHANNEL" \
  "$REMOTE_STABLE_REVISION" \
  "$CANDIDATE_REPO_NAME" \
  "$CANDIDATE_CHANNEL" \
  "$REMOTE_CANDIDATE_REVISION" \
  "$GUEST_SLOPPKG_BIN" \
  "$CANONICAL_WORLD_TARGET" \
  "$PID_FILE" \
  "$LOG_FILE" \
  "$@" <<'EOF'
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

rebuild_helper="$1"
shift
readiness_helper="$1"
shift
validation_helper="$1"
shift
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
candidate_repo_name="$1"
shift
candidate_channel="$1"
shift
candidate_revision="$1"
shift
guest_sloppkg_bin="$1"
shift
canonical_world_target="$1"
shift
pid_file="$1"
shift
log_file="$1"
shift

if [ "$revision" = "__AUTO_REVISION__" ]; then
  revision=""
fi

if [ "$candidate_revision" = "__AUTO_REVISION__" ]; then
  candidate_revision=""
fi

chmod 0755 "$rebuild_helper" "$readiness_helper" "$validation_helper" "$publish_helper" "$sync_helper"
env \
  STATE_ROOT="$state_root" \
  GUEST_RECIPE_ROOT="$guest_recipe_root" \
  GUEST_HTTP_REPO_ROOT="$guest_http_repo_root" \
  GUEST_HTTP_REPO_PORT="$guest_http_repo_port" \
  GUEST_HTTP_REPO_BIND="$guest_http_repo_bind" \
  STABLE_REPO_NAME="$repo_name" \
  STABLE_CHANNEL="$channel" \
  STABLE_REVISION="$revision" \
  CANDIDATE_REPO_NAME="$candidate_repo_name" \
  CANDIDATE_CHANNEL="$candidate_channel" \
  CANDIDATE_REVISION="$candidate_revision" \
  GUEST_SLOPPKG_BIN="$guest_sloppkg_bin" \
  CANONICAL_WORLD_TARGET="$canonical_world_target" \
  PID_FILE="$pid_file" \
  LOG_FILE="$log_file" \
  SLOPOS_VALIDATE_REBUILD_READINESS="$readiness_helper" \
  SLOPOS_VALIDATE_MANAGED_WORLD="$validation_helper" \
  SLOPOS_PUBLISH_HTTP_REPO="$publish_helper" \
  SLOPOS_SYNC_WORLD="$sync_helper" \
  "$rebuild_helper" "$@"
EOF
