#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/configs/host-guest.env"

for gnubin_dir in \
  /opt/homebrew/bin \
  /opt/homebrew/opt/util-linux/bin \
  /opt/homebrew/opt/gpatch/libexec/gnubin \
  /opt/homebrew/opt/gnu-sed/libexec/gnubin \
  /opt/homebrew/opt/findutils/libexec/gnubin \
  /opt/homebrew/opt/coreutils/libexec/gnubin \
  /opt/homebrew/opt/grep/libexec/gnubin \
  /opt/homebrew/opt/gawk/libexec/gnubin \
  /opt/homebrew/opt/gnu-tar/libexec/gnubin
do
  if [[ -d "$gnubin_dir" ]]; then
    PATH="$gnubin_dir:$PATH"
  fi
done

export PATH

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

host_arch="$(uname -m)"
macos_version="$(sw_vers -productVersion)"
cpu_brand="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"

if [[ "$host_arch" == "arm64" ]]; then
  guest_arch="${GUEST_ARCH:-aarch64}"
  qemu_system="${QEMU_SYSTEM:-qemu-system-aarch64}"
  qemu_machine="${QEMU_MACHINE:-virt}"
  qemu_accel="${QEMU_ACCEL:-hvf}"
  linux_console="${LINUX_CONSOLE:-ttyAMA0}"
else
  guest_arch="${GUEST_ARCH:-x86_64}"
  qemu_system="${QEMU_SYSTEM:-qemu-system-x86_64}"
  qemu_machine="${QEMU_MACHINE:-pc}"
  qemu_accel="${QEMU_ACCEL:-hvf}"
  linux_console="${LINUX_CONSOLE:-ttyS0}"
fi

printf 'Host architecture : %s\n' "$host_arch"
printf 'macOS version     : %s\n' "$macos_version"
printf 'CPU               : %s\n' "$cpu_brand"
printf 'Guest architecture: %s\n' "$guest_arch"
printf 'QEMU system       : %s\n' "$qemu_system"
printf 'QEMU machine      : %s\n' "$qemu_machine"
printf 'QEMU accel        : %s\n' "$qemu_accel"
printf 'Linux console     : %s\n' "$linux_console"
printf '\n'

required_tools=(brew git make clang python3)
missing_tools=()

shopt -s nullglob

for tool in "${required_tools[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '[ok] %s -> %s\n' "$tool" "$(command -v "$tool")"
  else
    printf '[missing] %s\n' "$tool"
    missing_tools+=("$tool")
  fi
done

gnu_gcc="${HOST_GCC:-}"
gnu_gxx="${HOST_GXX:-}"

if [[ -z "$gnu_gcc" ]]; then
  gcc_candidates=(/opt/homebrew/bin/gcc-[0-9]*)
  if [[ "${#gcc_candidates[@]}" -gt 0 ]]; then
    gnu_gcc="$(printf '%s\n' "${gcc_candidates[@]}" | sort -V | tail -n 1)"
  fi
fi

if [[ -z "$gnu_gxx" && -n "$gnu_gcc" ]]; then
  gnu_gxx="${gnu_gcc/gcc-/g++-}"
fi

if [[ -n "$gnu_gcc" && -x "$gnu_gcc" ]] && "$gnu_gcc" -v 2>&1 | grep -q '^gcc version '; then
  printf '[ok] gnu gcc -> %s\n' "$gnu_gcc"
else
  printf '[missing] gnu gcc (expected Homebrew gcc-*)\n'
  printf 'Install hint: brew install gcc\n'
  missing_tools+=("gnu-gcc")
fi

if [[ -n "$gnu_gxx" && -x "$gnu_gxx" ]]; then
  printf '[ok] gnu g++ -> %s\n' "$gnu_gxx"
else
  printf '[missing] gnu g++ (expected Homebrew g++-*)\n'
  printf 'Install hint: brew install gcc\n'
  missing_tools+=("gnu-g++")
fi

if patch --version 2>/dev/null | grep -q '^GNU patch '; then
  printf '[ok] gnu patch -> %s\n' "$(command -v patch)"
else
  printf '[missing] gnu patch\n'
  printf 'Install hint: brew install gpatch\n'
  missing_tools+=("gnu-patch")
fi

if command -v flock >/dev/null 2>&1; then
  printf '[ok] flock -> %s\n' "$(command -v flock)"
else
  printf '[missing] flock\n'
  printf 'Install hint: brew install util-linux\n'
  missing_tools+=("flock")
fi

if command -v "$qemu_system" >/dev/null 2>&1; then
  printf '[ok] %s -> %s\n' "$qemu_system" "$(command -v "$qemu_system")"
else
  printf '[missing] %s\n' "$qemu_system"
  printf 'Install hint: brew install qemu\n'
  missing_tools+=("$qemu_system")
fi

if [[ "${#missing_tools[@]}" -gt 0 ]]; then
  printf '\nPreflight result: missing %s item(s).\n' "${#missing_tools[@]}"
  exit 1
fi

printf '\nPreflight result: host is ready for the next phase.\n'
