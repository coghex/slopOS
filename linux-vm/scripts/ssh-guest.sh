#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-$ROOT_DIR/qemu/known_hosts}"
OVERRIDE_GUEST_SSH_FORWARD_PORT="${GUEST_SSH_FORWARD_PORT:-}"
GUEST_SSH_CONNECT_TIMEOUT_SECONDS="${GUEST_SSH_CONNECT_TIMEOUT_SECONDS:-10}"
GUEST_SSH_SERVER_ALIVE_INTERVAL_SECONDS="${GUEST_SSH_SERVER_ALIVE_INTERVAL_SECONDS:-5}"
GUEST_SSH_SERVER_ALIVE_COUNT_MAX="${GUEST_SSH_SERVER_ALIVE_COUNT_MAX:-3}"

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

if [[ -n "$OVERRIDE_GUEST_SSH_FORWARD_PORT" ]]; then
  GUEST_SSH_FORWARD_PORT="$OVERRIDE_GUEST_SSH_FORWARD_PORT"
fi
read -r IDENTITY_FILE < "$IDENTITY_PATH_FILE"

if [[ ! -f "$IDENTITY_FILE" ]]; then
  echo "Missing SSH identity file: $IDENTITY_FILE" >&2
  exit 1
fi

mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"

if [[ $# -eq 0 ]]; then
  exec ssh \
    -i "$IDENTITY_FILE" \
    -o BatchMode=yes \
    -o ConnectTimeout="$GUEST_SSH_CONNECT_TIMEOUT_SECONDS" \
    -o ConnectionAttempts=1 \
    -o IdentitiesOnly=yes \
    -o ServerAliveInterval="$GUEST_SSH_SERVER_ALIVE_INTERVAL_SECONDS" \
    -o ServerAliveCountMax="$GUEST_SSH_SERVER_ALIVE_COUNT_MAX" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
    -p "$GUEST_SSH_FORWARD_PORT" \
    root@127.0.0.1
fi

if [[ $# -eq 1 ]]; then
  remote_command="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; $1"
  exec ssh \
    -i "$IDENTITY_FILE" \
    -o BatchMode=yes \
    -o ConnectTimeout="$GUEST_SSH_CONNECT_TIMEOUT_SECONDS" \
    -o ConnectionAttempts=1 \
    -o IdentitiesOnly=yes \
    -o ServerAliveInterval="$GUEST_SSH_SERVER_ALIVE_INTERVAL_SECONDS" \
    -o ServerAliveCountMax="$GUEST_SSH_SERVER_ALIVE_COUNT_MAX" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
    -p "$GUEST_SSH_FORWARD_PORT" \
    root@127.0.0.1 \
    "$remote_command"
fi

exec ssh \
  -i "$IDENTITY_FILE" \
  -o BatchMode=yes \
  -o ConnectTimeout="$GUEST_SSH_CONNECT_TIMEOUT_SECONDS" \
  -o ConnectionAttempts=1 \
  -o IdentitiesOnly=yes \
  -o ServerAliveInterval="$GUEST_SSH_SERVER_ALIVE_INTERVAL_SECONDS" \
  -o ServerAliveCountMax="$GUEST_SSH_SERVER_ALIVE_COUNT_MAX" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -p "$GUEST_SSH_FORWARD_PORT" \
  root@127.0.0.1 \
  "$@"
