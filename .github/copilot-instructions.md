# Repository scope

The hand-written project lives under `linux-vm/`. Most Copilot work should focus on:

- `linux-vm/scripts/` for build orchestration, QEMU launch, Lima integration, SSH/SCP helpers, and toolchain bootstrap flows
- `linux-vm/configs/` for host/guest settings and the Buildroot defconfig
- `linux-vm/board/rootfs-overlay/` for guest boot, persistent-disk mounting, and SSH setup

Treat `linux-vm/buildroot-src/` as the upstream Buildroot checkout and `linux-vm/artifacts/` as generated output unless a task explicitly requires changing them.

## Build, validation, and run commands

Run these from the repository root.

### Main workflow

```bash
cd linux-vm && ./scripts/host-preflight.sh
cd linux-vm && ./scripts/prepare-guest-ssh.sh
cd linux-vm && ./scripts/build-phase2-lima.sh
cd linux-vm && ./scripts/run-phase2.sh
cd linux-vm && ./scripts/ssh-guest.sh
```

### Alternative build paths

Use the direct macOS Buildroot path when you intentionally want to build without Lima:

```bash
cd linux-vm && ./scripts/build-phase2.sh
```

Use the Linux-only builder script inside a Linux environment:

```bash
cd linux-vm && ./scripts/build-phase2-linux.sh
```

### Persistent disk and SDK/toolchain flows

```bash
cd linux-vm && ./scripts/ensure-root-disk.sh
cd linux-vm && ./scripts/ensure-persistent-disk.sh
cd linux-vm && ./scripts/export-bootstrap-sdk.sh
cd linux-vm && ./scripts/install-bootstrap-sdk.sh
cd linux-vm && ./scripts/build-native-binutils.sh
cd linux-vm && ./scripts/build-native-glibc.sh
cd linux-vm && ./scripts/build-native-gcc.sh
```

### Targeted validation

There is no dedicated repo-level test runner or lint target. The smallest checks used in this repository are:

```bash
bash -n linux-vm/scripts/host-preflight.sh
bash -n linux-vm/scripts/run-phase2.sh
cd linux-vm && ./scripts/host-preflight.sh
```

`host-preflight.sh` is the real dependency gate for the macOS flow; it verifies Homebrew GNU tools, QEMU, `flock`, and the expected guest architecture settings from `configs/host-guest.env`.

## High-level architecture

This repository is a Buildroot-based AArch64 VM environment for QEMU on macOS, with Lima used as the preferred Linux build host.

The build starts from `linux-vm/configs/slopos_aarch64_virt_defconfig`, which tells Buildroot to build an AArch64 system, Linux kernel `6.18.7`, Dropbear, Python 3, the host environment setup package, and an ext4 root filesystem image. Build output lands in `linux-vm/artifacts/buildroot-output/`, especially `images/Image` and `images/rootfs.ext4`. The cpio initramfs artifact may still be produced, but the normal runtime path now boots from the ext4 root disk, not from initramfs.

The guest customization layer is `linux-vm/board/rootfs-overlay/`. `S11persistent-disk` identifies the data disk by filesystem label and mounts it at `/Volumes/slopos-data`. `S12ssh-setup` persists Dropbear host keys and root SSH authorization data onto that mounted disk. `S13toolchain-links` exposes the persistent toolchains as `gcc`, `cc`, and related commands, and `S14persistent-dropbear` rewires `/usr/sbin/dropbear` and companion client tools to the persistent Dropbear build under `/Volumes/slopos-data/opt/dropbear/current`.

The runtime path is driven by `linux-vm/scripts/run-phase2.sh`. It reads `linux-vm/configs/host-guest.env`, seeds `linux-vm/qemu/slopos-root.img` from the Buildroot ext4 artifact when needed, ensures the separate data disk exists, then boots QEMU with the Buildroot kernel, the persistent root disk as `/dev/vda`, the data disk as `/dev/vdb`, and user-mode networking with SSH forwarded to `127.0.0.1:${GUEST_SSH_FORWARD_PORT}`.

The preferred macOS build flow is `linux-vm/scripts/build-phase2-lima.sh`. It prepares guest SSH access, boots or reuses a Lima VM named `slopos-builder`, installs Linux build dependencies in that VM, runs `scripts/build-phase2-linux.sh` against the checked-out `buildroot-src/`, then copies the kernel, ext4 rootfs artifact, optional initramfs, and build logs back into `artifacts/buildroot-output/`.

The repository also carries a second-stage toolchain workflow. `export-bootstrap-sdk.sh` packages a Buildroot SDK tarball into `linux-vm/artifacts/toolchain/`, `install-bootstrap-sdk.sh` installs it inside the guest under `/Volumes/slopos-data/toolchain/`, and the `build-native-{binutils,glibc,gcc}.sh` scripts use SSH/SCP helpers plus that persistent disk layout to build a native AArch64 toolchain inside the guest.

## Key conventions

- `linux-vm/scripts/*.sh` consistently use `set -euo pipefail`, derive `ROOT_DIR` relative to the script location, and source `linux-vm/configs/host-guest.env` when host/guest settings are needed. Keep new scripts aligned with that pattern.
- The repo-specific customization boundary is `scripts/`, `configs/`, and `board/rootfs-overlay/`. Avoid changing `buildroot-src/` for project behavior unless the task explicitly requires upstream Buildroot edits.
- SSH access is intentionally bootstrapped through the rootfs overlay. `prepare-guest-ssh.sh` copies a host public key into `board/rootfs-overlay/root/.ssh/authorized_keys` and records the matching private key path in `linux-vm/qemu/guest-ssh-identity.path`. `ssh-guest.sh` and `scp-to-guest.sh` depend on that file.
- The guest root itself is now persistent through the file-backed ext4 root disk `linux-vm/qemu/slopos-root.img`. Larger durable state still lives on the separate data disk mounted at `/Volumes/slopos-data/...`.
- Lima-based scripts use a guest-local output directory (`${HOME}/.slopos-buildroot-output`) and then copy only the important outputs back into `linux-vm/artifacts/buildroot-output/`. If a task changes build outputs, check both sides of that handoff.
- `configs/slopos_aarch64_virt_defconfig` references `board/qemu/patches` and `board/qemu/aarch64-virt/linux.config` relative to the Buildroot checkout in `linux-vm/buildroot-src/`, not relative to the repository root.
