#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUTABLE_SEED_SSH_DIR="$ROOT_DIR/board/rootfs-overlay/root/.ssh"
AUTHORIZED_KEYS_FILE="$MUTABLE_SEED_SSH_DIR/authorized_keys"
IDENTITY_PATH_FILE="$ROOT_DIR/qemu/guest-ssh-identity.path"

pick_public_key() {
  local candidates=()
  if [[ -n "${HOST_SSH_PUBKEY_FILE:-}" ]]; then
    candidates+=("$HOST_SSH_PUBKEY_FILE")
  fi
  candidates+=(
    "$HOME/.ssh/id_ed25519.pub"
    "$HOME/.ssh/id_ecdsa.pub"
    "$HOME/.ssh/id_rsa.pub"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended to run on macOS." >&2
  exit 1
fi

PUBLIC_KEY_FILE="$(pick_public_key)" || {
  echo "No public SSH key found. Set HOST_SSH_PUBKEY_FILE or create ~/.ssh/id_ed25519.pub." >&2
  exit 1
}

PRIVATE_KEY_FILE="${PUBLIC_KEY_FILE%.pub}"
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
  echo "Missing private key for $PUBLIC_KEY_FILE" >&2
  exit 1
fi

mkdir -p "$MUTABLE_SEED_SSH_DIR" "$ROOT_DIR/qemu"
install -m 600 "$PUBLIC_KEY_FILE" "$AUTHORIZED_KEYS_FILE"
chmod 700 "$MUTABLE_SEED_SSH_DIR"
printf '%s\n' "$PRIVATE_KEY_FILE" > "$IDENTITY_PATH_FILE"

echo "Prepared guest SSH access with public key: $PUBLIC_KEY_FILE"
