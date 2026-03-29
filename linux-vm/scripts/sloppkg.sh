#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SLOPPKG_RECIPE_ROOT="${SLOPPKG_RECIPE_ROOT:-$ROOT_DIR/packages}"

exec cargo run --manifest-path "$ROOT_DIR/pkgmgr/Cargo.toml" --bin sloppkg -- "$@"
