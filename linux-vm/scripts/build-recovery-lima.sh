#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
LINUX_BUILD_SCRIPT="$ROOT_DIR/scripts/build-recovery-linux.sh"
PREPARE_GUEST_SSH_SCRIPT="$ROOT_DIR/scripts/prepare-guest-ssh.sh"
INSTANCE="${LIMA_INSTANCE:-slopos-builder}"
VM_TYPE="${LIMA_VM_TYPE:-vz}"
CPUS="${LIMA_CPUS:-4}"
MEMORY_GIB="${LIMA_MEMORY_GIB:-8}"
DISK_GIB="${LIMA_DISK_GIB:-40}"
MOUNT_TYPE="${LIMA_MOUNT_TYPE:-virtiofs}"
BUILD_JOBS="${BUILD_JOBS:-}"
GUEST_OUTPUT_DIR='${HOME}/.slopos-buildroot-recovery-output'

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended to run on macOS." >&2
  exit 1
fi

if ! command -v limactl >/dev/null 2>&1; then
  echo "limactl is required. Install Lima with: brew install lima" >&2
  exit 1
fi

if [[ ! -x "$LINUX_BUILD_SCRIPT" ]]; then
  echo "Missing Linux build script: $LINUX_BUILD_SCRIPT" >&2
  exit 1
fi

if [[ ! -x "$PREPARE_GUEST_SSH_SCRIPT" ]]; then
  echo "Missing guest SSH preparation script: $PREPARE_GUEST_SSH_SCRIPT" >&2
  exit 1
fi

"$PREPARE_GUEST_SSH_SCRIPT"

packages=(
  build-essential
  bc
  binutils
  bison
  cpio
  file
  flex
  gawk
  git
  gzip
  locales
  make
  patch
  perl
  python3
  rsync
  sed
  tar
  unzip
  wget
  xz-utils
)

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

limactl shell --start "$INSTANCE" bash -lc '
  set -euo pipefail
  marker="$HOME/.slopos-buildroot-deps-ready"
  if [[ ! -f "$marker" ]]; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y '"${packages[*]}"'
    touch "$marker"
  fi
'

build_cmd='set -euo pipefail; '
if [[ -n "$BUILD_JOBS" ]]; then
  build_cmd+="export BUILD_JOBS=$(printf '%q' "$BUILD_JOBS"); "
fi
build_cmd+="export OUTPUT_DIR=$GUEST_OUTPUT_DIR; "
build_cmd+="cd $(printf '%q' "$ROOT_DIR") && ./scripts/build-recovery-linux.sh; "
build_cmd+="mkdir -p $(printf '%q' "$ROOT_DIR/artifacts/buildroot-recovery-output/images") ; "
build_cmd+="cp \"\$OUTPUT_DIR/images/Image\" $(printf '%q' "$ROOT_DIR/artifacts/buildroot-recovery-output/images/Image") ; "
build_cmd+="if [[ -f \"\$OUTPUT_DIR/images/rootfs.cpio.gz\" ]]; then cp \"\$OUTPUT_DIR/images/rootfs.cpio.gz\" $(printf '%q' "$ROOT_DIR/artifacts/buildroot-recovery-output/images/rootfs.cpio.gz"); else cp \"\$OUTPUT_DIR/images/rootfs.cpio\" $(printf '%q' "$ROOT_DIR/artifacts/buildroot-recovery-output/images/rootfs.cpio"); fi; "
build_cmd+="cp \"\$OUTPUT_DIR/.config\" $(printf '%q' "$ROOT_DIR/artifacts/buildroot-recovery-output/.config.linux-builder") ; "
build_cmd+="cp \"\$OUTPUT_DIR/build/build-time.log\" $(printf '%q' "$ROOT_DIR/artifacts/buildroot-recovery-output/build-time.linux-builder.log")"

limactl shell --start --workdir "$ROOT_DIR" "$INSTANCE" bash -lc "$build_cmd"
