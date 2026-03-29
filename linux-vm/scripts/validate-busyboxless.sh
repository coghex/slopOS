#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"
NORMAL_OUTPUT_DIR="$ROOT_DIR/artifacts/buildroot-output"
RECOVERY_OUTPUT_DIR="$ROOT_DIR/artifacts/buildroot-recovery-output"
NORMAL_ROOTFS_IMAGE="$NORMAL_OUTPUT_DIR/images/rootfs.ext4"
RECOVERY_INITRAMFS_GZ="$RECOVERY_OUTPUT_DIR/images/rootfs.cpio.gz"
RECOVERY_INITRAMFS_RAW="$RECOVERY_OUTPUT_DIR/images/rootfs.cpio"
INSTANCE="${LIMA_INSTANCE:-slopos-builder}"
VALIDATE_SSH_PORT="${VALIDATE_SSH_PORT:-2223}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-180}"
NORMAL_VM_PID=""
NORMAL_TMPDIR=""

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-busyboxless.sh [--artifacts-only] [--live-only]

Validates that the current normal seed image and recovery initramfs are
BusyBox-free according to the repository contract.
EOF
}

run_artifact_checks=1
run_live_checks=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts-only)
      run_live_checks=0
      ;;
    --live-only)
      run_artifact_checks=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$run_artifact_checks" -eq 0 && "$run_live_checks" -eq 0 ]]; then
  echo "Nothing to do: both artifact and live checks are disabled." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing host config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ ! -f "$NORMAL_ROOTFS_IMAGE" ]]; then
  echo "Missing normal rootfs image: $NORMAL_ROOTFS_IMAGE" >&2
  echo "Run ./scripts/build-phase2-lima.sh first." >&2
  exit 1
fi

if [[ ! -f "$RECOVERY_INITRAMFS_GZ" && ! -f "$RECOVERY_INITRAMFS_RAW" ]]; then
  echo "Missing recovery initramfs image in $RECOVERY_OUTPUT_DIR/images" >&2
  echo "Run ./scripts/build-recovery-lima.sh first." >&2
  exit 1
fi

if [[ ! -f "$ROOT_DIR/qemu/guest-ssh-identity.path" ]]; then
  echo "Missing guest SSH identity path file: $ROOT_DIR/qemu/guest-ssh-identity.path" >&2
  echo "Run ./scripts/prepare-guest-ssh.sh and rebuild the normal image first." >&2
  exit 1
fi

cleanup() {
  if [[ -n "$NORMAL_VM_PID" ]] && kill -0 "$NORMAL_VM_PID" 2>/dev/null; then
    kill "$NORMAL_VM_PID" 2>/dev/null || true
    wait "$NORMAL_VM_PID" 2>/dev/null || true
  fi

  if [[ -n "$NORMAL_TMPDIR" && -d "$NORMAL_TMPDIR" ]]; then
    rm -rf "$NORMAL_TMPDIR"
  fi
}

trap cleanup EXIT

run_normal_artifact_check() {
  local image_path="$NORMAL_ROOTFS_IMAGE"
  local shell_cmd

  read -r -d '' shell_cmd <<EOF || true
set -euo pipefail
image=$(printf '%q' "$image_path")
tmp=\$(mktemp -d)
trap 'rm -rf "\$tmp"' EXIT
mkdir -p "\$tmp/rootfs"
debugfs -R "rdump / \$tmp/rootfs" "\$image" >/dev/null 2>&1
python3 - "\$tmp/rootfs" <<'PY'
import os
import sys

root = sys.argv[1]

def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)

def path(*parts: str) -> str:
    return os.path.join(root, *parts)

for unexpected in ("bin/busybox", "linuxrc", "bin/ash"):
    if os.path.lexists(path(*unexpected.split("/"))):
        fail(f"normal artifact unexpectedly contains {unexpected}")

for required in ("bin/sh", "sbin/getty", "usr/sbin/seedrng"):
    if not os.path.lexists(path(*required.split("/"))):
        fail(f"normal artifact is missing required path {required}")

busybox_links = []
for rel_dir in ("bin", "sbin", "usr/bin", "usr/sbin"):
    directory = path(*rel_dir.split("/"))
    if not os.path.isdir(directory):
        continue
    for entry in os.listdir(directory):
        full_path = os.path.join(directory, entry)
        if not os.path.islink(full_path):
            continue
        target = os.readlink(full_path)
        if "busybox" in target.split("/"):
            busybox_links.append(f"{rel_dir}/{entry}->{target}")

if busybox_links:
    fail("normal artifact contains BusyBox symlinks: " + ", ".join(sorted(busybox_links)))

print("normal artifact busyboxless validation passed")
PY
EOF

  if command -v debugfs >/dev/null 2>&1; then
    bash -lc "$shell_cmd"
    return 0
  fi

  if ! command -v limactl >/dev/null 2>&1; then
    echo "debugfs is unavailable locally and limactl is not installed." >&2
    exit 1
  fi

  if ! limactl list -q | grep -qx "$INSTANCE"; then
    echo "Lima instance $INSTANCE is required for normal image validation." >&2
    echo "Run ./scripts/build-phase2-lima.sh first." >&2
    exit 1
  fi

  limactl shell --start "$INSTANCE" bash -lc "$shell_cmd"
}

run_recovery_artifact_check() {
  local archive_path="$RECOVERY_INITRAMFS_GZ"
  if [[ ! -f "$archive_path" ]]; then
    archive_path="$RECOVERY_INITRAMFS_RAW"
  fi

  python3 - "$archive_path" <<'PY'
import gzip
import io
import os
import stat
import sys

archive_path = sys.argv[1]

with open(archive_path, "rb") as fh:
    raw = fh.read()

if archive_path.endswith(".gz"):
    raw = gzip.decompress(raw)

allowed_dirs = {".", "bin", "dev", "etc", "proc", "recovery", "root", "sys"}
allowed_symlinks = {
    "bin/help": "/recovery/toolbox",
    "bin/sh": "/recovery/toolbox",
    "bin/ls": "/recovery/toolbox",
    "bin/cat": "/recovery/toolbox",
    "bin/dmesg": "/recovery/toolbox",
    "bin/sysctl": "/recovery/toolbox",
    "bin/uname": "/recovery/toolbox",
    "bin/lsmod": "/recovery/toolbox",
    "bin/poweroff": "/recovery/toolbox",
    "bin/reboot": "/recovery/toolbox",
}
allowed_regular = {"init", "recovery/toolbox", "etc/passwd", "etc/shells"}
allowed_char = {"dev/console"}
unexpected = {"bin/busybox", "linuxrc", "etc/inittab", "recovery/busybox"}

offset = 0
seen = set()

while True:
    if raw[offset:offset + 6] != b"070701":
      raise SystemExit(f"bad cpio magic at offset {offset}")

    mode = int(raw[offset + 14:offset + 22], 16)
    filesize = int(raw[offset + 54:offset + 62], 16)
    namesize = int(raw[offset + 94:offset + 102], 16)

    offset += 110
    name = raw[offset:offset + namesize - 1].decode()
    offset += namesize
    offset = (offset + 3) & ~3
    data = raw[offset:offset + filesize]
    offset += filesize
    offset = (offset + 3) & ~3

    if name == "TRAILER!!!":
      break

    if name in unexpected:
      raise SystemExit(f"recovery artifact unexpectedly contains {name}")

    kind = stat.S_IFMT(mode)
    seen.add(name)

    if kind == stat.S_IFDIR:
      if name not in allowed_dirs:
        raise SystemExit(f"unexpected recovery directory {name}")
      continue

    if kind == stat.S_IFREG:
      if name not in allowed_regular:
        raise SystemExit(f"unexpected recovery regular file {name}")
      continue

    if kind == stat.S_IFLNK:
      target = data.decode()
      if name not in allowed_symlinks:
        raise SystemExit(f"unexpected recovery symlink {name} -> {target}")
      if allowed_symlinks[name] != target:
        raise SystemExit(f"unexpected recovery symlink target for {name}: {target}")
      continue

    if kind == stat.S_IFCHR:
      if name not in allowed_char:
        raise SystemExit(f"unexpected recovery device node {name}")
      continue

    raise SystemExit(f"unexpected recovery entry type for {name}: {oct(mode)}")

expected = allowed_dirs | allowed_regular | set(allowed_symlinks) | allowed_char
missing = sorted(expected - seen)
if missing:
  raise SystemExit("recovery artifact is missing expected entries: " + ", ".join(missing))

print("recovery artifact busyboxless validation passed")
PY
}

wait_for_guest_ssh() {
  local known_hosts_file="$1"
  local deadline=$((SECONDS + BOOT_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    if GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
      KNOWN_HOSTS_FILE="$known_hosts_file" \
      "$ROOT_DIR/scripts/ssh-guest.sh" 'true' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

shutdown_normal_vm() {
  local known_hosts_file="$1"
  local deadline
  GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    KNOWN_HOSTS_FILE="$known_hosts_file" \
    "$ROOT_DIR/scripts/ssh-guest.sh" 'poweroff' >/dev/null 2>&1 || true

  if [[ -n "$NORMAL_VM_PID" ]]; then
    deadline=$((SECONDS + 60))
    while kill -0 "$NORMAL_VM_PID" 2>/dev/null; do
      if (( SECONDS >= deadline )); then
        kill "$NORMAL_VM_PID" 2>/dev/null || true
        break
      fi
      sleep 1
    done
    wait "$NORMAL_VM_PID" || true
    NORMAL_VM_PID=""
  fi
}

run_normal_live_check() {
  local known_hosts_file
  local qemu_log
  local remote_check

  mkdir -p "$ROOT_DIR/qemu"
  NORMAL_TMPDIR="$(mktemp -d "$ROOT_DIR/qemu/validate-busyboxless.XXXXXX")"
  known_hosts_file="$NORMAL_TMPDIR/known_hosts"
  qemu_log="$NORMAL_TMPDIR/normal-qemu.log"

  cp "$NORMAL_ROOTFS_IMAGE" "$NORMAL_TMPDIR/root.img"
  PERSISTENT_DISK_IMAGE="$NORMAL_TMPDIR/data.img" "$ROOT_DIR/scripts/ensure-persistent-disk.sh" >/dev/null

  (
    cd "$ROOT_DIR"
    ROOT_DISK_IMAGE="$NORMAL_TMPDIR/root.img" \
      PERSISTENT_DISK_IMAGE="$NORMAL_TMPDIR/data.img" \
      GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
      ./scripts/run-phase2.sh >"$qemu_log" 2>&1
  ) &
  NORMAL_VM_PID=$!

  if ! wait_for_guest_ssh "$known_hosts_file"; then
    echo "timed out waiting for isolated normal guest SSH" >&2
    tail -n 80 "$qemu_log" >&2 || true
    exit 1
  fi

  read -r -d '' remote_check <<'EOF' || true
python3 - <<'PY'
import os

for unexpected in ("/bin/busybox", "/linuxrc", "/bin/ash"):
    if os.path.lexists(unexpected):
        raise SystemExit(f"unexpected live path present: {unexpected}")

for required in ("/bin/sh", "/sbin/getty", "/usr/sbin/seedrng"):
    if not os.path.lexists(required):
        raise SystemExit(f"missing live path: {required}")

bad = []
for directory in ("/bin", "/sbin", "/usr/bin", "/usr/sbin"):
    for entry in os.listdir(directory):
        full_path = os.path.join(directory, entry)
        if not os.path.islink(full_path):
            continue
        target = os.readlink(full_path)
        if "busybox" in target.split("/"):
            bad.append(f"{full_path}->{target}")

if bad:
    raise SystemExit("unexpected live BusyBox symlinks: " + ", ".join(sorted(bad)))

print("normal live busyboxless validation passed")
PY
EOF

  GUEST_SSH_FORWARD_PORT="$VALIDATE_SSH_PORT" \
    KNOWN_HOSTS_FILE="$known_hosts_file" \
    "$ROOT_DIR/scripts/ssh-guest.sh" "$remote_check"

  shutdown_normal_vm "$known_hosts_file"
  rm -rf "$NORMAL_TMPDIR"
  NORMAL_TMPDIR=""
}

run_recovery_live_check() {
  python3 - "$ROOT_DIR" <<'PY'
import os
import pty
import select
import subprocess
import sys
import time

root = sys.argv[1]
master_fd, slave_fd = pty.openpty()
proc = subprocess.Popen(
    ["./scripts/run-recovery.sh"],
    cwd=root,
    stdin=slave_fd,
    stdout=slave_fd,
    stderr=slave_fd,
    text=False,
)
os.close(slave_fd)

buffer = b""

def fail(message: str) -> None:
    global buffer
    if proc.poll() is None:
        proc.kill()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    raise SystemExit(message + "\n\nCaptured output tail:\n" + buffer[-4000:].decode(errors="replace"))

def read_until(token: bytes, timeout: int) -> str:
    global buffer
    start = len(buffer)
    deadline = time.time() + timeout
    while token not in buffer[start:]:
        if time.time() > deadline:
            fail(f"timed out waiting for {token!r}")
        ready, _, _ = select.select([master_fd], [], [], 1)
        if master_fd not in ready:
            continue
        try:
            chunk = os.read(master_fd, 1024)
        except OSError as exc:
            fail(f"recovery VM read failed: {exc}")
        if not chunk:
            fail(f"recovery VM exited before {token!r}")
        buffer += chunk
    end = buffer.index(token, start) + len(token)
    return buffer[start:end].decode(errors="replace")

read_until(b"(recovery) # ", 120)

checks = [
    ('sh -c "help; uname -a"\n', ["Available recovery commands:", "Linux "]),
    ('ls /\n', ["bin", "recovery"]),
    ('cat /etc/passwd\n', ["root::0:0:root:/root:/bin/sh"]),
]

for command, needles in checks:
    os.write(master_fd, command.encode())
    output = read_until(b"(recovery) # ", 30)
    for needle in needles:
        if needle not in output:
            fail(f"missing expected recovery output {needle!r} for command {command.strip()!r}")

os.write(master_fd, b"poweroff\n")
read_until(b"reboot: Power down", 30)

try:
    proc.wait(timeout=30)
except subprocess.TimeoutExpired:
    fail("recovery VM did not exit after poweroff")

os.close(master_fd)

if proc.returncode != 0:
    fail(f"unexpected recovery VM exit code: {proc.returncode}")

print("recovery live busyboxless validation passed")
PY
}

if [[ "$run_artifact_checks" -eq 1 ]]; then
  echo "==> Validating normal image artifacts"
  run_normal_artifact_check
  echo "==> Validating recovery image artifacts"
  run_recovery_artifact_check
fi

if [[ "$run_live_checks" -eq 1 ]]; then
  echo "==> Validating isolated normal guest boot"
  run_normal_live_check
  echo "==> Validating recovery guest boot"
  run_recovery_live_check
fi

echo "BusyBox-less validation passed."
