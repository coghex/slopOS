# slopos

This repository contains a small Linux VM project built with Buildroot.

The working project lives in `linux-vm/`. It builds an AArch64 guest, boots it in QEMU, and gives you a simple environment for experimenting with persistent tooling and system changes.

## What it does

- builds a Linux kernel and root filesystem with Buildroot
- boots the guest with QEMU on macOS
- uses Lima as the preferred Linux build environment
- keeps the guest root filesystem on a persistent ext4 disk
- mounts a second persistent data disk at `/Volumes/slopos-data`
- supports SSH/SCP access with Dropbear
- includes scripts for building a native toolchain inside the guest

## Main workflow

Run these from the repository root:

```bash
git submodule update --init --recursive
cd linux-vm && ./scripts/host-preflight.sh
cd linux-vm && ./scripts/prepare-guest-ssh.sh
cd linux-vm && ./scripts/build-phase2-lima.sh
cd linux-vm && ./scripts/run-phase2.sh
cd linux-vm && ./scripts/ssh-guest.sh
```

## Persistence model

The VM now uses two disk images:

- `linux-vm/qemu/slopos-root.img` is the persistent root filesystem
- `linux-vm/qemu/slopos-data.img` is the larger data disk mounted at `/Volumes/slopos-data`

This means changes under `/`, `/bin`, `/usr`, `/etc`, and `/root` survive reboot.

## Documentation

The detailed technical reference is:

- `linux-vm/README.md`

## Current direction

This environment is set up for experimenting with persistent guest changes, native toolchain work, and higher-level tooling on top of a small custom Linux VM.
