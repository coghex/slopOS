#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
BUILDROOT_DIR="$ROOT_DIR/buildroot-src"
BUILDROOT_EXTERNAL_DIR="$ROOT_DIR/buildroot-external"
INSTANCE="${LIMA_INSTANCE:-slopos-builder}"
VM_TYPE="${LIMA_VM_TYPE:-vz}"
CPUS="${LIMA_CPUS:-4}"
MEMORY_GIB="${LIMA_MEMORY_GIB:-8}"
DISK_GIB="${LIMA_DISK_GIB:-40}"
MOUNT_TYPE="${LIMA_MOUNT_TYPE:-virtiofs}"
GUEST_OUTPUT_DIR='${HOME}/.slopos-buildroot-output'
SDK_PREFIX="${SDK_PREFIX:-slopos-aarch64-bootstrap-sdk}"
ARTIFACT_DIR="$ROOT_DIR/artifacts/toolchain"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended to run on macOS." >&2
  exit 1
fi

if ! command -v limactl >/dev/null 2>&1; then
  echo "limactl is required. Install Lima with: brew install lima" >&2
  exit 1
fi

if [[ ! -d "$BUILDROOT_DIR/.git" ]]; then
  echo "Buildroot checkout not found at $BUILDROOT_DIR" >&2
  exit 1
fi

if [[ ! -f "$BUILDROOT_EXTERNAL_DIR/external.desc" ]]; then
  echo "Missing Buildroot external tree: $BUILDROOT_EXTERNAL_DIR" >&2
  exit 1
fi

if limactl list -q | grep -qx "$INSTANCE"; then
  limactl start "$INSTANCE" --yes
else
  limactl start \
    --name="$INSTANCE" \
    --vm-type="$VM_TYPE" \
    --cpus="$CPUS" \
    --memory="$MEMORY_GIB" \
    --disk="$DISK_GIB" \
    --mount-only "$PROJECT_ROOT:w" \
    --mount-type="$MOUNT_TYPE" \
    --containerd=none \
    --yes
fi

mkdir -p "$ARTIFACT_DIR"

sdk_cmd='set -euo pipefail; '
sdk_cmd+="export OUTPUT_DIR=$GUEST_OUTPUT_DIR; "
sdk_cmd+="cd $(printf '%q' "$ROOT_DIR"); "
sdk_cmd+="test -d \"\$OUTPUT_DIR/host\" || { echo \"Missing Buildroot host tree in \$OUTPUT_DIR. Run ./scripts/build-phase2-lima.sh first.\" >&2; exit 1; }; "
sdk_cmd+="make -C $(printf '%q' "$BUILDROOT_DIR") O=\"\$OUTPUT_DIR\" BR2_EXTERNAL=$(printf '%q' "$BUILDROOT_EXTERNAL_DIR") BR2_SDK_PREFIX=$(printf '%q' "$SDK_PREFIX") sdk; "
sdk_cmd+="cp \"\$OUTPUT_DIR/images/$SDK_PREFIX.tar.gz\" $(printf '%q' "$ARTIFACT_DIR/$SDK_PREFIX.tar.gz")"

limactl shell --start --workdir "$ROOT_DIR" "$INSTANCE" bash -lc "$sdk_cmd"

echo "Exported SDK: $ARTIFACT_DIR/$SDK_PREFIX.tar.gz"
