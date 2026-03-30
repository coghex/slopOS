#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
PROMOTE_HELPER_SOURCE="$ROOT_DIR/board/normal-rootfs-tree/usr/sbin/slopos-promote-rebuild"
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
SOURCE_REPO_NAME="${SOURCE_REPO_NAME:-${CANDIDATE_REPO_NAME:-workspace-candidate}}"
SOURCE_CHANNEL="${SOURCE_CHANNEL:-${CANDIDATE_CHANNEL:-candidate}}"
SOURCE_REVISION="${SOURCE_REVISION:-}"
TARGET_REPO_NAME="${TARGET_REPO_NAME:-${STABLE_REPO_NAME:-${REPO_NAME:-workspace}}}"
TARGET_CHANNEL="${TARGET_CHANNEL:-${STABLE_CHANNEL:-${CHANNEL:-stable}}}"
KEEP_REVISIONS="${KEEP_REVISIONS:-1}"
GUEST_SLOPPKG_BIN="${GUEST_SLOPPKG_BIN:-/usr/local/bin/sloppkg}"
PID_FILE="${PID_FILE:-$STATE_ROOT/http-repo.pid}"
LOG_FILE="${LOG_FILE:-$STATE_ROOT/http-repo.log}"
GUEST_PROMOTE_HELPER_DEST="${GUEST_PROMOTE_HELPER_DEST:-/tmp/slopos-promote-rebuild}"
GUEST_PUBLISH_HELPER_DEST="${GUEST_PUBLISH_HELPER_DEST:-/tmp/slopos-publish-http-repo}"

"$ROOT_DIR/scripts/scp-to-guest.sh" "$PROMOTE_HELPER_SOURCE" "$GUEST_PROMOTE_HELPER_DEST"
"$ROOT_DIR/scripts/scp-to-guest.sh" "$PUBLISH_HELPER_SOURCE" "$GUEST_PUBLISH_HELPER_DEST"

"$ROOT_DIR/scripts/ssh-guest.sh" bash -s -- \
  "$GUEST_PROMOTE_HELPER_DEST" \
  "$GUEST_PUBLISH_HELPER_DEST" \
  "$STATE_ROOT" \
  "$SOURCE_REPO_NAME" \
  "$SOURCE_CHANNEL" \
  "$SOURCE_REVISION" \
  "$TARGET_REPO_NAME" \
  "$TARGET_CHANNEL" \
  "$KEEP_REVISIONS" \
  "$GUEST_SLOPPKG_BIN" \
  "$PID_FILE" \
  "$LOG_FILE" <<'EOF'
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

promote_helper="$1"
shift
publish_helper="$1"
shift
state_root="$1"
shift
source_repo_name="$1"
shift
source_channel="$1"
shift
source_revision="$1"
shift
target_repo_name="$1"
shift
target_channel="$1"
shift
keep_revisions="$1"
shift
guest_sloppkg_bin="$1"
shift
pid_file="$1"
shift
log_file="$1"
shift

chmod 0755 "$promote_helper" "$publish_helper"

set -- \
  env \
  STATE_ROOT="$state_root" \
  SOURCE_REPO_NAME="$source_repo_name" \
  SOURCE_CHANNEL="$source_channel" \
  TARGET_REPO_NAME="$target_repo_name" \
  TARGET_CHANNEL="$target_channel" \
  KEEP_REVISIONS="$keep_revisions" \
  GUEST_SLOPPKG_BIN="$guest_sloppkg_bin" \
  PID_FILE="$pid_file" \
  LOG_FILE="$log_file" \
  SLOPOS_PUBLISH_HTTP_REPO="$publish_helper" \
  "$promote_helper"

if [ -n "$source_revision" ]; then
  set -- "$@" --source-revision "$source_revision"
fi

"$@"
EOF
