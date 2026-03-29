#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export BOOT_MODE=recovery

exec "$ROOT_DIR/scripts/run-phase2.sh" "$@"
