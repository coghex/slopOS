# linux-vm

This directory contains the actual VM project in this repository.

It builds an AArch64 Linux guest with Buildroot, boots it in QEMU, and now uses a persistent ext4 root disk instead of relying on an initramfs-only root.

This file is the canonical technical reference for the VM project. The repository root `README.md` is intentionally shorter.

## Overview

The system has three main layers:

- Buildroot in `buildroot-src/` produces the kernel and root filesystem artifacts
- host-side scripts in `scripts/` build artifacts, seed disk images, and launch QEMU
- guest-side overlay files in `board/rootfs-overlay/` customize boot behavior and persistence

The result is a guest with:

- a Buildroot-generated Linux kernel
- a persistent ext4 root disk
- a second persistent data disk at `/Volumes/slopos-data`
- Dropbear for SSH/SCP access
- a native toolchain and other guest-built software stored on the data disk

## Repository checkout

`buildroot-src/` is tracked as a Git submodule that points at upstream Buildroot.

After cloning the repository, initialize it with:

```bash
git submodule update --init --recursive
```

## Current boot model

The guest no longer boots into an initramfs root as its normal runtime model.

Instead:

1. Buildroot produces `artifacts/buildroot-output/images/Image`
2. Buildroot also produces `artifacts/buildroot-output/images/rootfs.ext4`
3. `scripts/ensure-root-disk.sh` seeds `qemu/slopos-root.img` from that ext4 image
4. `scripts/run-phase2.sh` boots QEMU with:
   - `slopos-root.img` as `/dev/vda`
   - `slopos-data.img` as `/dev/vdb`
5. The kernel mounts `/dev/vda` as `/`
6. boot scripts mount `/dev/vdb` at `/Volumes/slopos-data`

That means changes under `/bin`, `/usr`, `/etc`, `/opt`, and `/root` now persist across reboot.

## Disk layout

### Root disk

- host path: `qemu/slopos-root.img`
- guest device: `/dev/vda`
- filesystem: ext4
- source image: `artifacts/buildroot-output/images/rootfs.ext4`

This disk is persistent across boots. It is only reset when you intentionally reseed it, for example:

```bash
cd linux-vm && RESET_ROOT_DISK=1 ./scripts/run-phase2.sh
```

### Data disk

- host path: `qemu/slopos-data.img`
- guest device: `/dev/vdb`
- filesystem label: `slopos-data`
- mountpoint in guest: `/Volumes/slopos-data`

This disk is used for large durable state that is convenient to keep separate from the root filesystem, such as:

- toolchains
- source trees
- build directories
- persistent service data

## Main scripts

### Build and boot

- `scripts/host-preflight.sh`
  Checks the macOS host for required tools such as QEMU, GNU gcc/g++, GNU patch, `flock`, and Python.

- `scripts/build-phase2-lima.sh`
  Preferred build path on macOS. Uses Lima as the Linux build host, runs Buildroot there, and copies the key artifacts back into `artifacts/buildroot-output/`.

- `scripts/build-phase2-linux.sh`
  Linux-only Buildroot build entrypoint. This is what the Lima flow runs inside the builder VM.

- `scripts/build-phase2.sh`
  Direct macOS Buildroot build path without Lima.

- `scripts/run-phase2.sh`
  Ensures both disks exist, then boots QEMU using the built kernel and the persistent ext4 root disk.

### Disk helpers

- `scripts/ensure-root-disk.sh`
  Seeds `qemu/slopos-root.img` from `artifacts/buildroot-output/images/rootfs.ext4` if it does not exist yet.

- `scripts/ensure-persistent-disk.sh`
  Creates or resizes the separate data disk image and formats it as ext4.

### Guest access

- `scripts/prepare-guest-ssh.sh`
  Copies a host public key into the rootfs overlay and records the matching private key path.

- `scripts/ssh-guest.sh`
  SSH into the running guest through the forwarded host port.

- `scripts/scp-to-guest.sh`
  Copy files into the guest.

### Toolchain helpers

- `scripts/export-bootstrap-sdk.sh`
  Exports a Buildroot SDK tarball into `artifacts/toolchain/`.

- `scripts/install-bootstrap-sdk.sh`
  Installs that SDK inside the guest under `/Volumes/slopos-data/toolchain/`.

- `scripts/build-native-binutils.sh`
- `scripts/build-native-glibc.sh`
- `scripts/build-native-gcc.sh`

These build a native AArch64 toolchain inside the guest, using the persistent data disk for sources, build trees, and install roots.

## Build outputs

Important files under `artifacts/buildroot-output/`:

- `images/Image` - kernel image
- `images/rootfs.ext4` - Buildroot-generated root filesystem image used to seed the persistent root disk
- `images/rootfs.cpio.gz` - optional initramfs artifact still produced by Buildroot
- `.config` / `.config.linux-builder` - resolved Buildroot config
- `build-time.linux-builder.log` - build log copied back from the Linux builder

## Guest boot-time customization

The overlay in `board/rootfs-overlay/` contains the logic that makes the guest usable.

### Important init scripts

- `etc/init.d/S11persistent-disk`
  Uses `blkid` to find the disk labeled `slopos-data` and mounts it at `/Volumes/slopos-data`.

- `etc/init.d/S12ssh-setup`
  Persists root SSH authorization data and Dropbear host keys on the data disk.

- `etc/init.d/S13toolchain-links`
  Exposes the persistent toolchain as standard commands like `gcc`, `cc`, and `g++`.

- `etc/init.d/S14persistent-dropbear`
  Rewires `/usr/sbin/dropbear` and related client commands to the Dropbear build installed on the data disk.

## Buildroot configuration

The project defconfig is `configs/slopos_aarch64_virt_defconfig`.

Important points:

- target architecture is AArch64
- kernel version is `6.18.7`
- root filesystem image generation includes ext4 via Buildroot's ext2 backend
- the rootfs overlay comes from `../board/rootfs-overlay`
- Buildroot package selection includes Dropbear, Bash, Make, Git, Python 3, and other core tools needed in the guest

Note that paths like `board/qemu/aarch64-virt/linux.config` are relative to the Buildroot checkout in `buildroot-src/`, not to the repository root.

## Runtime networking

QEMU uses user-mode networking and forwards guest port 22 to host port `2222` by default.

That means guest access is usually:

```bash
cd linux-vm && ./scripts/ssh-guest.sh
```

If you reseed the root disk, the guest host keys change. In that case the local `qemu/known_hosts` entry may need to be refreshed.

## Common workflows

### Full rebuild and boot

```bash
cd linux-vm && ./scripts/host-preflight.sh
cd linux-vm && ./scripts/prepare-guest-ssh.sh
cd linux-vm && ./scripts/build-phase2-lima.sh
cd linux-vm && ./scripts/run-phase2.sh
```

### Reset the root filesystem back to the current Buildroot image

```bash
cd linux-vm && RESET_ROOT_DISK=1 ./scripts/run-phase2.sh
```

### Keep the current root filesystem and just reboot

```bash
cd linux-vm && ./scripts/run-phase2.sh
```

### Build software natively in the guest and keep it persistent

- use `/` for normal system installs that should remain part of the persistent root
- use `/Volumes/slopos-data` for large source/build/install trees and versioned persistent payloads

## Recommended mental model

Treat the project like this:

- Buildroot defines the baseline operating system image
- `slopos-root.img` is the long-lived VM root filesystem
- `slopos-data.img` is the long-lived data and tooling disk
- the overlay scripts are the glue that reconnects persistent components at boot

That model is the foundation for the next layer of work, such as a source-based package manager or other persistent guest tooling.
