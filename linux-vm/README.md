# linux-vm

This directory contains the actual VM project in this repository.

It builds an AArch64 Linux guest with Buildroot, boots it in QEMU, and now uses a persistent ext4 root disk for normal mode plus a separate recovery initramfs build.

This file is the canonical technical reference for the VM project. The repository root `README.md` is intentionally shorter.

## Overview

The system has four main layers:

- Buildroot in `buildroot-src/` produces the kernel and root filesystem artifacts, with repo-owned package/config additions layered from `buildroot-external/`
- a separate Buildroot recovery profile produces a tiny initramfs for break-glass boots
- host-side scripts in `scripts/` build artifacts, seed disk images, and launch QEMU
- checked-in normal-seed files in `board/normal-rootfs-tree/` plus mutable host-provided seed inputs in `board/rootfs-overlay/` customize boot behavior and persistence
- `rootfs/bootstrap-manifest.toml` records the ownership boundary between Buildroot stage0 and the first `sloppkg` bootstrap world

The result is a guest with:

- a Buildroot-generated Linux kernel
- a persistent ext4 root disk
- a recovery initramfs that boots independently of the managed root filesystem
- a second persistent data disk at `/Volumes/slopos-data`
- Dropbear for SSH/SCP access
- a native toolchain and other guest-built software stored on the data disk

## Repository checkout

`buildroot-src/` is tracked as a Git submodule that points at upstream Buildroot. Repo-owned Buildroot additions should live under `buildroot-external/` so the submodule can stay close to upstream.

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

There is now also a separate recovery path:

1. `scripts/build-recovery-lima.sh` builds `artifacts/buildroot-recovery-output/`
2. that profile emits a tiny `rootfs.cpio.gz`
3. `scripts/run-recovery.sh` boots QEMU with `-initrd` and `rdinit=/init`
4. recovery does not require a healthy managed root filesystem to boot

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

- `scripts/build-recovery-lima.sh`
  Preferred recovery build path on macOS. Builds the dedicated recovery kernel and initramfs into `artifacts/buildroot-recovery-output/`.

- `scripts/build-recovery-linux.sh`
  Linux-only recovery Buildroot build entrypoint.

- `scripts/build-phase2.sh`
  Direct macOS Buildroot build path without Lima.

- `scripts/run-phase2.sh`
  Boots either the normal ext4-root runtime or the recovery initramfs depending on `BOOT_MODE`.

- `scripts/run-recovery.sh`
  Convenience wrapper for `BOOT_MODE=recovery ./scripts/run-phase2.sh`.

### Disk helpers

- `scripts/ensure-root-disk.sh`
  Seeds `qemu/slopos-root.img` from the current default rootfs source when it is created or reset, and records the exact paired rootfs+kernel generation in a sibling `*.boot-selection.toml` file so later boots reuse that same pair until the root disk is reset again.

- `scripts/ensure-persistent-disk.sh`
  Creates or resizes the separate data disk image and formats it as ext4.

### Guest access

- `scripts/prepare-guest-ssh.sh`
  Copies a host public key into the rootfs overlay and records the matching private key path.

- `scripts/ssh-guest.sh`
  SSH into the running guest through the forwarded host port. When invoked with a single remote command string, it prepends the managed `/usr/local` PATH so package-managed tools are visible in common scripted usage.

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
- `scripts/build-guest-kernel-artifacts.sh`
- `scripts/promote-guest-kernel-candidate.sh`
- `scripts/build-guest-rootfs-artifacts.sh`
- `scripts/audit-guest-ext4-sealing.sh`
- `scripts/validate-guest-mke2fs-d-support.sh`
- `scripts/validate-guest-rootfs-artifacts.sh`
- `scripts/validate-guest-rootfs-boot-candidate.sh`
- `scripts/validate-guest-combined-boot-candidate.sh`
- `scripts/promote-guest-boot-default.sh`
- `scripts/validate-promoted-boot-default.sh`
- `scripts/validate-promoted-boot-rollback.sh`
- `scripts/validate-reset-to-world.sh`

These build a native AArch64 toolchain inside the guest, using the persistent data disk for sources, build trees, and install roots.

`scripts/build-guest-kernel-artifacts.sh` stages the current normal-image kernel
inputs into the guest and invokes the checked-in guest helper
`/usr/sbin/slopos-build-kernel-artifacts`, which builds a native ARM64 `Image`
plus modules under `/Volumes/slopos-data/kernel/artifacts/` without replacing
the normal boot kernel yet. `scripts/promote-guest-kernel-candidate.sh` copies
the latest guest-built kernel artifact back to
`artifacts/guest-kernel-candidate/current/Image` for explicit host-side kernel
handoff testing, and `run-phase2.sh` now accepts `KERNEL_IMAGE=...` for that
opt-in path while leaving the default Buildroot kernel unchanged.

`scripts/build-guest-rootfs-artifacts.sh` stages a plain tar archive of the current
Buildroot normal rootfs tree plus the checked-in normal seed inputs into the
guest and invokes `/usr/sbin/slopos-build-rootfs-artifacts`, which reruns the
same `board/normal-post-fakeroot.sh` assembly logic in-guest, archives the
assembled tree as a plain tar stream, and now seals `rootfs.ext4` in-guest with
`mke2fs -d` on the current rebuilt seed image. The plain-tar staging/archiving
keeps the workflow independent of a seeded `gzip` binary or Python compression
modules. `scripts/build-guest-rootfs-artifacts.sh` still keeps the old
host/Lima sealing path as a compatibility fallback for older guests that have
not yet been reseeded onto the new e2fsprogs-capable image.
The companion
`scripts/validate-guest-rootfs-artifacts.sh` copies the latest guest-built image
back to the host, runs the existing isolated normal-image validator against it,
and publishes the validated result to
`artifacts/guest-rootfs-candidate/current/rootfs.ext4` for explicit host-side
boot handoff testing. That export now also writes
`artifacts/guest-rootfs-candidate/current/host-handoff.toml` with the copied
image SHA-256, copied manifest SHA-256, guest manifest schema version, and both
the final `seal_method` plus the staged `staged_seal_method` that the guest
recorded before any host compatibility fallback. `scripts/validate-guest-rootfs-boot-candidate.sh` then
boots `run-phase2.sh` through that host-side candidate path with
`ROOTFS_SOURCE_IMAGE=...` plus `RESET_ROOT_DISK=1`, while still keeping the
Buildroot kernel, so the opt-in handoff can be proven before any broader
promotion. `scripts/validate-guest-combined-boot-candidate.sh` then combines
that rootfs candidate with
`KERNEL_IMAGE=artifacts/guest-kernel-candidate/current/Image` to prove the full
guest-built kernel+rootfs opt-in boot path. The combined validator now rejects
stale or mismatched host handoff metadata before it ever boots the temporary VM.
The kernel side now stages versioned input bundles under
`/Volumes/slopos-data/kernel/input/<bundle>/`, records source provenance in
`kernel-inputs.toml`, and requires the schema-2 guest kernel manifest to carry
`staged_input_metadata`, `staged_input_root_manifest`, and
`staged_patch_manifest`.

`scripts/audit-guest-ext4-sealing.sh` stages and runs the checked-in guest
helper `/usr/sbin/slopos-audit-ext4-sealing-prereqs`, copies the resulting
report back under `artifacts/guest-ext4-sealing-audit/current/`, and records
the host-side kernel-config/defconfig context for the current blockers that
still keep the rootfs workflow hybrid.

`scripts/validate-guest-mke2fs-d-support.sh` boots a temporary VM from the
current rebuilt seed image, proves that guest ext4 sealing is now available
through `mke2fs -d`, builds a guest rootfs artifact on that temporary VM with
`ALLOW_HOST_ROOTFS_SEAL_FALLBACK=0`, and verifies the resulting manifest
records `seal_method = "guest-mke2fs-d"`.

`scripts/promote-guest-boot-default.sh` then copies the current host-side guest
rootfs and kernel candidates into `artifacts/guest-boot-promoted/current/`
without overwriting any Buildroot output. It also copies the candidate
`host-handoff.toml` files forward and writes `promotion.toml` with the promoted
rootfs/kernel image and manifest SHA-256 values for the paired default boot
selection, plus the promoted kernel `System.map` and resolved `linux.config`
hashes. When that promoted path exists, new or reset root disks use that
resolved promoted pair by default unless the caller explicitly sets
`ROOTFS_SOURCE_IMAGE=...` or `KERNEL_IMAGE=...`. Existing root disks now keep
booting the exact pair recorded in their sibling `*.boot-selection.toml`
metadata, so clearing `current/` only affects future reseeds.
`scripts/validate-promoted-boot-default.sh` proves that default-selection
behavior through a temporary VM and verifies that the promoted hashes still
match the copied artifacts on disk, and `scripts/promote-guest-boot-default.sh --clear`
removes the promoted default so future boots fall back to the Buildroot
artifacts again.

The older `scripts/build-selfhost-*.sh` helpers are now best treated as fallback/manual debugging tools. The supported steady-state toolchain workflow is the package-managed path:

```bash
sloppkg --state-root /Volumes/slopos-data/pkg install selfhost-toolchain --root /
sloppkg --state-root /Volumes/slopos-data/pkg upgrade --root /
```

Those helpers still exist because they are useful when isolating recipe bugs or reproducing pre-bootstrap behavior, but they are no longer the primary architecture.

### Package manager prototype

- `pkgmgr/`
  Rust workspace for the `sloppkg` prototype.

- `packages/`
  Local recipe repository used by the prototype solver and CLI.

- `scripts/sloppkg.sh`
  Convenience wrapper that runs `sloppkg` from the workspace with `SLOPPKG_RECIPE_ROOT` pointed at `packages/`.

- `scripts/install-sloppkg-guest-package.sh`
  Cross-builds the guest `sloppkg` ELF, seeds the `sloppkg` recipe into the guest's persistent recipe repo, and reinstalls `sloppkg` through package management so it can upgrade itself later.

The workspace recipe repo now carries eight validated general-purpose source package waves around the selfhost core. The first wave is `zlib 1.3.2-1`, `xz 5.8.2-1`, `pkgconf 2.3.0-1`, `libffi 3.4.8-1`, `openssl 3.6.1-1`, and `dropbear 2025.89-1`. The second wave adds `expat 2.7.5-1`, `ncurses 6.6-20251231-1`, `readline 8.3-1`, `sqlite 3.51.3-1`, `zstd 1.5.7-1`, and `curl 8.19.0-1`. The third wave adds `m4 1.4.21-1`, `bison 3.8.2-1`, `flex 2.6.4-1`, `ninja 1.13.2-1`, `meson 1.10.1-1`, and `cmake 4.2.3-1`. The fourth wave adds `libtool 2.4.6-1`, `autoconf 2.72-1`, and `automake 1.16.5-1`. The fifth wave adds `patch 2.7.6-1`, `diffutils 3.12-1`, `sed 4.9-1`, `grep 3.12-1`, `gawk 5.4.0-1`, `findutils 4.10.0-1`, and `which 2.23-1`. The sixth wave adds `make 4.4.1-1`, so the guest now has a package-managed GNU Make instead of relying on the seeded base-image copy. The seventh wave adds `file 5.47-1`, including the managed `file(1)` binary, `libmagic`, and the compiled `magic.mgc` database under `/usr/local/share/misc`. The eighth wave adds `perl 5.42.0-1`, bringing the Perl interpreter, `ExtUtils::MakeMaker`, `pod2man`, `prove`, `xsubpp`, and the core module tree under `/usr/local`. The `dropbear` package installs into `/Volumes/slopos-data/opt/dropbear/current` specifically so `board/normal-rootfs-tree/etc/init.d/S14persistent-dropbear` can expose the persistent SSH tools at boot.

The build runner now prepends `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` for both source fetching and package build commands, so managed tools installed under `/usr/local/bin` participate in later recipe fetch/build steps without relying on the caller's shell profile. The `meson` wrapper also prepends the bootstrap SDK Python 3.14 library tree from `/Volumes/slopos-data/toolchain/slopos-aarch64-bootstrap-sdk/lib/python3.14` so Meson can use the full stdlib and extension modules even though the seeded guest Python is slimmer.

Phase 5 validation now includes a Meson+Ninja smoke project, an Autotools+Libtool smoke project, a text-helper smoke path that exercises `sed`, `grep`, `patch`, `diff`, `find`, `xargs`, `gawk`, and `which` from `/usr/local/bin`, a dedicated GNU Make smoke build that compiles a small C program using `/usr/local/bin/make`, a `file(1)` smoke path that correctly classifies plain text, shell scripts, and managed ELF binaries using the managed magic database, and a Perl smoke path that runs `perl Makefile.PL`, `make`, `make test`, `prove -v`, and `pod2man` entirely through the managed `/usr/local` toolchain. The Autotools smoke path uses `libtoolize --copy --install`, `autoreconf -fi`, `./configure`, and `make` entirely inside the guest and successfully builds and runs a small shared-library-backed demo.

Phase 6 has now started with a shell/runtime slice: `bash 5.2.37-1`, `less 692-1`, and `nano 8.7.1-1` are installed under `/usr/local/bin`, login shells source `/etc/profile.d/00-managed-path.sh` to prefer `/usr/local`, and `scripts/ssh-guest.sh` prepends that managed PATH for the common single-command case. A second phase-6 slice adds `gzip 1.14-1`, `tar 1.35-1`, and `coreutils 9.10-1`, so common archive flows and day-to-day userland commands such as `ls`, `cp`, `mv`, `rm`, `head`, `tail`, `sort`, `tr`, `basename`, `dirname`, `realpath`, and `uptime` now resolve from `/usr/local/bin`. A third phase-6 networking slice adds `iproute2 6.17.0-1`, `iputils 20250605-1`, `netcat 0.7.1-1`, `traceroute 2.1.6-1`, `wget 1.25.0-1`, and `telnet 2.6-1`, replacing the BusyBox-backed `ip`, `ping`, `traceroute`, and `telnet` commands while adding managed `wget` under `/usr/local/bin`; `ss` and `nc` are now available there as well. A fourth boot-adjacent staging slice adds `util-linux 2.41.3-4`, which now exposes source-built `mount`, `umount`, `mountpoint`, `findmnt`, `blkid`, and `agetty` under `/usr/local` along with the supporting util-linux libraries. A fifth boot-adjacent shell slice adds `dash 0.5.13.1-1` under `/usr/local/bin` as the candidate replacement for `/bin/sh`. The `board/normal-rootfs-tree/etc/init.d/S17persistent-getty` hook now normalizes the fresh seed image onto `/sbin/agetty` and later rewires both `/sbin/agetty` and `/sbin/getty` to `/usr/local/sbin/agetty` once the managed util-linux slice is installed, so both the rebuilt stage0 image and the restored persistent guest use util-linux `agetty` on `ttyAMA0` with the reseeded `shadow` `/bin/login` binary already in place. Phase 4 now switches the rebuilt stage0 image itself to `sysvinit`: `configs/slopos_aarch64_virt_defconfig` selects `BR2_INIT_SYSV`, `BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_DEVTMPFS`, `BR2_PACKAGE_UTIL_LINUX`, and `BR2_PACKAGE_UTIL_LINUX_AGETTY`, relies on sysvinit's `BR2_PACKAGE_BUSYBOX_SHOW_OTHERS` compatibility visibility so `dash`, `bash`, `dcron`, and similar alternatives stay selectable in Buildroot, and uses the overlaid `board/normal-rootfs-tree/etc/inittab` line `T0:12345:respawn:/sbin/agetty -L ttyAMA0 0 vt100` to preserve the existing `rcS`, `rcK`, and `ttyAMA0` contract under sysvinit syntax without a BusyBox serial-console fallback. Phase 5 makes the device-management policy explicit: `board/normal-rootfs-tree/etc/init.d/S18devtmpfs-policy` clears any legacy userspace hotplug helper, removes `/etc/mdev.conf`, and deletes any stale BusyBox `/sbin/mdev` symlink so the booted system is deliberately `devtmpfs`-only rather than implicitly relying on unused `mdev` behavior. The next shell/login cutover now replaces BusyBox ownership in the seeded image too: `configs/slopos_aarch64_virt_defconfig` selects `BR2_SYSTEM_BIN_SH_DASH` and enables `BR2_PACKAGE_SHADOW`, so BusyBox no longer provides `ash`, `sh`, `login`, or `getty` in the normal image. The `board/normal-rootfs-tree/etc/init.d/S19persistent-sh` hook repoints `/bin/sh` to the managed `/usr/local/bin/dash` on the current persistent guest, removes any stale `/bin/ash` symlink, and prunes `/bin/ash` from `/etc/shells`; on a fresh rebuilt stage0 image, the same hook falls back to `/bin/dash` so stale incremental-build `ash` links are cleaned there as well. The final normal-root cleanup then removes BusyBox from the image entirely: `configs/slopos_aarch64_virt_defconfig` no longer selects `BR2_PACKAGE_BUSYBOX`, and it now also drops the old seeded `wget`, the seeded `file`/`make`/`patch`/`perl` developer tools, the old seeded `git` binary, and the old seeded `rsync` binary because managed-world recovery later supplies `wget` through `selfhost-network`, `patch` through `selfhost-base`, and `file`, `make`, and `perl` through `selfhost-devel` under `/usr/local/bin`, while version-control and archive/sync tooling are not part of the current stage0 boot or recovery contract; `board/normal-post-fakeroot.sh` explicitly installs the checked-in normal seed tree, strips any stale `/bin/busybox`, legacy BusyBox links, and the unused `/linuxrc` symlink from the final target, and imports mutable host-provided SSH authorization data from `board/rootfs-overlay/root/.ssh/authorized_keys` when present before the ext4 image is sealed. An isolated boot of the rebuilt image verified `/proc/1/exe -> /sbin/init`, the overlaid inittab line `T0:12345:respawn:/sbin/agetty -L ttyAMA0 0 vt100`, an empty `/proc/sys/kernel/hotplug`, no `/etc/mdev.conf`, no `/sbin/mdev`, `/bin/sh -> /bin/dash`, no `/bin/ash`, a real `/bin/login` binary from `shadow`, `/sbin/agetty` owned by util-linux, `/sbin/getty -> /sbin/agetty`, no `/bin/busybox`, no `/usr/bin/wget`, no `ash`/`sh`/`login`/`getty` BusyBox applets left in the normal image, and the expected sysvinit-installed `reboot`/`poweroff` symlinks. Phase 7 is now defined by first-class meta-packages: `selfhost-base`, `selfhost-devel`, `selfhost-network`, and `selfhost-world` now describe the intended guest shape, and `selfhost-world` is installed in the persistent package state as the canonical full-system target. Phase 9 now moves the remaining repo-publish and world-convergence orchestration into guest-resident helpers: `/usr/sbin/slopos-publish-http-repo` owns the guest unified-repo publish/serve/update flow and `/usr/sbin/slopos-sync-world` owns the publish-plus-install/upgrade flow, while `scripts/publish-guest-http-repo.sh` and `scripts/sync-guest-world.sh` are just SSH transport wrappers that stage and invoke those guest helpers. Validation covers managed tool resolution for `bash`, `less`, `nano`, `gzip`, `tar`, `ls`, `cp`, `mv`, `rm`, `ip`, `ss`, `ping`, `traceroute`, `nc`, `wget`, `telnet`, `curl`, `perl`, `make`, `file`, `mount`, `umount`, `mountpoint`, `findmnt`, `blkid`, `agetty`, and `dash`, plus a gzip round-trip smoke path, a tar create/extract smoke path, representative coreutils command checks, networking smoke checks for `ip -brief link`, `ss -ltn`, `ping -c 1 127.0.0.1`, `traceroute -n -m 1 127.0.0.1`, `wget -qO- http://127.0.0.1:18083/repo.toml`, and a telnet connection to `127.0.0.1:18083`, plus a util-linux smoke path covering `findmnt /Volumes/slopos-data`, `blkid /dev/vda /dev/vdb`, a bind mount/unmount round trip, a `dash -n` audit of `/init`, `rcS`, `rcK`, `S11`-`S19`, and `/etc/profile.d/00-managed-path.sh`, a reset-to-world flow that reseeds the root disk, republishes the guest HTTP repo, runs `sloppkg --state-root /Volumes/slopos-data/pkg update` plus `sloppkg --state-root /Volumes/slopos-data/pkg upgrade --root /`, and then reboots, a live reboot check that confirmed the restored persistent guest now runs `/usr/local/sbin/agetty` on `ttyAMA0`, resolves `/bin/login` to the reseeded `shadow` binary, resolves `/bin/sh` to `/usr/local/bin/dash`, leaves `/bin/ash` absent, keeps `/dev` on `devtmpfs`, leaves `/proc/sys/kernel/hotplug` empty, and preserves the persistent `sloppkg` exposure, and isolated rebuilt-image boots that confirmed sysvinit becomes PID 1 with no BusyBox-backed links left under `/bin`, `/sbin`, `/usr/bin`, or `/usr/sbin`, and that the final normal image no longer ships `/bin/busybox` at all. After the validated reset-to-world replay, `sloppkg doctor` reported 76 managed packages. `dig`, `git`, `rsync`, `tcpdump`, and `nmap` are not yet packaged.

## Build outputs

Important files under `artifacts/buildroot-output/`:

- `images/Image` - kernel image
- `images/rootfs.ext4` - Buildroot-generated root filesystem image used to seed the persistent root disk
- `images/rootfs.cpio.gz` - optional initramfs artifact still produced by Buildroot
- `.config` / `.config.linux-builder` - resolved Buildroot config
- `build-time.linux-builder.log` - build log copied back from the Linux builder

Important guest-native kernel artifact paths under `/Volumes/slopos-data/kernel/`:

- `input/<bundle>/` - versioned staged kernel input bundle with the defconfig, kernel config, patch dir, source tarball, and `kernel-inputs.toml` provenance file
- `input/current/` - symlink to the latest staged kernel input bundle
- `artifacts/<kernelrelease>-<timestamp>/` - versioned guest-built `Image`, `modules.tar.xz`, installed modules tree, inputs, and manifest
- `artifacts/current` - symlink to the latest validated guest-built kernel artifact set
- `logs/` - guest-native kernel build logs

Important host-side guest-kernel handoff paths under `artifacts/guest-kernel-candidate/`:

- `current/Image` - latest guest-built kernel image copied back for opt-in host boot tests
- `current/modules.tar.xz` - packaged modules payload copied back alongside that kernel image
- `current/manifest.toml` - copied guest artifact manifest for that kernel candidate
- `current/System.map` / `current/linux.config` - copied support files for validating the promoted kernel contract
- `current/host-handoff.toml` - host-side provenance for when the candidate was promoted, including copied Image/modules/manifest/System.map/linux.config SHA-256 values, manifest schema version, and `kernel_release`

Important host-side ext4 audit paths under `artifacts/guest-ext4-sealing-audit/`:

- `current/report.txt` - latest guest-side ext4 sealing prerequisite audit report
- `current/host-context.txt` - host-side kernel-config and defconfig context for that audit

Important guest-native rootfs artifact paths under `/Volumes/slopos-data/rootfs/`:

- `input/<bundle>/` - versioned staged rootfs input bundle with the Buildroot base archive, seed inputs, and `rootfs-inputs.toml` provenance file
- `input/current/` - symlink to the latest staged rootfs input bundle
- `artifacts/rootfs-<timestamp>/rootfs-tree.tar` - guest-assembled rootfs tree after rerunning the normal seed assembly hook
- `artifacts/rootfs-<timestamp>/rootfs.ext4` - guest-sealed ext4 image on rebuilt seeds, or host/Lima-sealed compatibility fallback image on older guests
- `artifacts/current` - symlink to the latest validated guest-built rootfs artifact set
- `logs/` - guest-native rootfs assembly logs

Important host-side guest-rootfs handoff paths under `artifacts/guest-rootfs-candidate/`:

- `current/rootfs.ext4` - latest validated guest-built rootfs image copied back for opt-in host boot tests
- `current/manifest.toml` - copied guest artifact manifest for that candidate image
- `current/host-handoff.toml` - host-side provenance for when the candidate was validated and promoted, including copied image/manifest SHA-256 values, manifest schema version, and the final/staged seal methods

Important host-side promoted-default boot paths under `artifacts/guest-boot-promoted/`:

- `current/rootfs.ext4` - promoted default rootfs seed image used when no explicit override is set
- `current/Image` - promoted default kernel image used when no explicit override is set
- `current/promotion.toml` - host-side provenance for the paired promoted default, including promoted image/manifest SHA-256 values for both rootfs and kernel

Important files under `artifacts/buildroot-recovery-output/`:

- `images/Image` - kernel image for the recovery profile
- `images/rootfs.cpio.gz` - recovery initramfs
- `.config.linux-builder` - resolved recovery Buildroot config
- `build-time.linux-builder.log` - recovery build log copied back from the Linux builder

## Guest boot-time customization

The checked-in normal seed tree in `board/normal-rootfs-tree/` now contains the
static repo-owned boot glue for the normal image. `board/normal-post-fakeroot.sh`
installs that tree directly into the final normal-image target during Buildroot's
fakeroot phase, while `board/rootfs-overlay/` is now reserved for mutable
host-provided inputs such as `root/.ssh/authorized_keys`.

The recovery userspace tree now comes from repo-owned files under
`board/recovery-rootfs-tree/`, `board/recovery-init.c`,
`board/recovery-toolbox.c`, and `board/recovery-post-fakeroot.sh`. The final
recovery initramfs boots straight into a shell with only these user-facing
commands:

- `sh`
- `ls`
- `cat`
- `dmesg`
- `sysctl`
- `uname`
- `lsmod`

### Important init scripts

- `etc/init.d/S11persistent-disk`
  Uses `blkid` to find the disk labeled `slopos-data` and mounts it at `/Volumes/slopos-data`.

- `etc/init.d/S12ssh-setup`
  Persists root SSH authorization data and Dropbear host keys on the data disk.

- `etc/init.d/S13toolchain-links`
  Exposes the persistent toolchain as standard commands like `gcc`, `cc`, and `g++`, preferring the selfhost final toolchain under `/Volumes/slopos-data/toolchain/selfhost-sysroot/final/bin`.

- `etc/init.d/S14persistent-dropbear`
  Rewires `/usr/sbin/dropbear` and related client commands to the Dropbear build installed on the data disk.

- `etc/init.d/S15local-lib-links`
  Exposes shared libraries from `/usr/local/lib` and `/usr/local/lib64` into `/usr/lib64` so source-built packages can run without per-package runtime linker wrappers.

- `etc/init.d/S16persistent-sloppkg`
  Rewires `/usr/local/bin/sloppkg` to the managed `sloppkg` binary installed on the persistent disk.

- `etc/init.d/S17persistent-getty`
  Keeps the legacy `/sbin/getty` path pointed at `agetty`: the seed image uses `/sbin/agetty`, and once the managed util-linux slice is available it rewires both `/sbin/getty` and `/sbin/agetty` to `/usr/local/sbin/agetty`.

- `etc/init.d/S18devtmpfs-policy`
  Enforces the devtmpfs-only device-management contract by clearing the kernel hotplug helper, removing any `mdev.conf`, and deleting the leftover BusyBox `/sbin/mdev` symlink.

- `etc/init.d/S19persistent-sh`
  Rewires `/bin/sh` to `dash`, removes any stale BusyBox `/bin/ash` symlink, and prunes `/bin/ash` from `/etc/shells` so the live guest and fresh stage0 image agree on the non-BusyBox shell provider.

- `etc/init.d/S20managed-userland-links`
  Rewires selected non-boot-critical legacy paths such as `/usr/bin/less`, `/usr/bin/which`, `/usr/bin/telnet`, `/usr/bin/traceroute`, `/usr/bin/nslookup`, `/bin/gzip`/`gunzip`/`zcat`, `/bin/base32`, `/bin/dmesg`, `/bin/ping`, `/usr/bin/logger`, `/usr/sbin/fsfreeze`, `/sbin/fdisk`, `/sbin/hwclock`, `/sbin/losetup`, and `/sbin/ip` to managed `/usr/local` binaries when those packages are present, and prunes stale BusyBox-backed or broken managed symlinks when they are not, including the BusyBox-only `ipaddr`/`iplink`/`iproute`/`iprule`/`ipneigh`/`iptunnel` aliases.
  The true early-boot `/bin/hostname`, `/bin/mount`, `/bin/umount`, `/bin/mountpoint`, `/bin/run-parts`, `/sbin/blkid`, `/sbin/mkswap`, `/sbin/swapon`, `/sbin/swapoff`, `/sbin/start-stop-daemon`, `/sbin/syslogd`, `/sbin/ifup`, `/sbin/ifdown`, `/sbin/{insmod,lsmod,modprobe,rmmod}`, `/sbin/killall5`, `/sbin/pidof`, `/usr/sbin/seedrng`, and the boot cron/DHCP service paths are intentionally outside this hook and are seeded directly from Buildroot providers in the image itself, including the compatibility `/sbin/{ifup,ifdown}` links back to ifupdown's `/usr/sbin` install and the Buildroot-installed `urandom-scripts` seed refresh hook. `seedrng` itself is now provided by a small imported standalone Buildroot package rather than the BusyBox applet. Later cleanup slices also seed direct providers for `/bin/{cpio,free,ps,top,w,watch}`, `/sbin/sysctl`, and `/usr/bin/{bc,dc,lsof,time,tree}`, drop stale BusyBox-only aliases such as `/bin/{arch,chattr,dumpkmap,fdflush,lsattr,more,mt,nuke,pipe_progress,resume,setpriv,setserial,su,usleep,vi}`, the normal-root orphan/operator batch `/usr/bin/{[[,ascii,chrt,chvt,crc32,deallocvt,dos2unix,fuser,getfattr,hexedit,killall,lspci,lsscsi,lsusb,lzopcat,mesg,microcom,mkpasswd,openvt,resize,setfattr,setkeycodes,sha3sum,svc,svok,tftp,ts,unix2dos,unlzop,unzip,uudecode,uuencode,vlock,xxd}`, `/usr/sbin/{addgroup,adduser,delgroup,deluser,dnsd,ether-wake,fbset,fdformat,i2cdetect,i2cdump,i2cget,i2cset,i2ctransfer,inetd,killall5,loadfont,mim,nologin,partprobe,rdate,setlogcons,ubirename}`, and the normal-rootfs-only `/sbin/{devmem,freeramdisk,fsck,hdparm,loadkmap,makedevs,mdev,mkdosfs,mke2fs,pivot_root,run-init,runlevel,setconsole,sulogin,switch_root,uevent,vconfig,watchdog}` cleanup batch. The normal ext4-booted image also removes the legacy BusyBox `/linuxrc` symlink because `run-phase2.sh` boots it directly with `root=/dev/vda` and no initrd, while the separate recovery image now boots its own repo-owned `/init` plus `/recovery/toolbox` command surface with no BusyBox dependency at all. The legacy `/sbin/getty` path stays pointed at `agetty` rather than BusyBox.

- `etc/inittab`
  Overlays a sysvinit-formatted inittab that keeps the existing `rcS`, `rcK`, and `ttyAMA0` boot flow while phase 4 moves PID 1 from BusyBox to sysvinit.

## Buildroot configuration

The project defconfig is `configs/slopos_aarch64_virt_defconfig`.

Important points:

- target architecture is AArch64
- kernel version is `6.18.7`
- root filesystem image generation includes ext4 via Buildroot's ext2 backend
- the normal image no longer uses a static Buildroot rootfs overlay for its checked-in boot glue
- `board/normal-post-fakeroot.sh` installs the checked-in `board/normal-rootfs-tree/` into the final normal-image target during fakeroot and also imports mutable host-provided `root/.ssh/authorized_keys` data from `board/rootfs-overlay/` when present
- Buildroot package selection includes Dropbear, Bash, Make, Git, Python 3, and other core tools needed in the guest
- the seeded stage0 boot helpers now include real non-BusyBox providers for storage, early networking, hostname, core service orchestration, the latent module-loading path, the current runtime-only cleanup batch, and the final RNG handoff: the defconfig enables the util-linux basic binary set plus `mount`/`mountpoint`, enables seeded `debianutils`, `iproute2`, `iputils`, `kmod`, `net-tools`, `start-stop-daemon`, `sysklogd`, `ifupdown`, ISC `dhclient`, `dcron`, `cpio`, `bc`, `tree`, `time`, `lsof`, `procps-ng`, and a vendored standalone `seedrng` package that `urandom-scripts` selects automatically, while `sysvinit` owns the normal-root `/sbin/killall5` and `/sbin/pidof` paths and Buildroot's `urandom-scripts` hook still consumes the seeded `/usr/sbin/seedrng` helper during early boot; the normal defconfig no longer selects `BR2_PACKAGE_BUSYBOX`, and `board/normal-post-fakeroot.sh` now explicitly installs the checked-in normal seed tree, imports mutable host-provided SSH authorization data, strips any stale `/bin/busybox`, legacy BusyBox links, and the unused normal-root `/linuxrc` symlink from the final target, and still seeds `/sbin/getty -> /sbin/agetty` plus scrubs `/bin/ash` from `/etc/shells`; the recovery image now uses the repo-owned `board/recovery-rootfs-tree/`, `board/recovery-init.c`, and `board/recovery-toolbox.c` rescue substrate assembled by `board/recovery-post-fakeroot.sh`

The recovery defconfig is `configs/slopos_aarch64_virt_recovery_defconfig`.

Important points for recovery:

- it emits only a compressed cpio initramfs
- the defconfig still enables `BR2_INIT_SYSV`, `BR2_SYSTEM_BIN_SH_DASH`, and `BR2_PACKAGE_BUSYBOX_SHOW_OTHERS` only as Buildroot scaffolding; the final runtime does not use BusyBox
- `board/recovery-post-fakeroot.sh` replaces Buildroot's generated recovery tree with the repo-owned final userspace tree right before the cpio image is packed
- the final archive is intentionally minimal: repo-owned `init`, `recovery/toolbox`, `/bin/*` symlinks, `/etc/passwd`, `/etc/shells`, a small directory skeleton, and the required `/dev/console` device node that Buildroot's cpio step still adds
- `rootfs/bootstrap-manifest.toml` records the intended ownership split: Buildroot owns stage0 boot/recovery, `sloppkg` owns the long-term bootstrap world

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

### Build and boot the recovery image

```bash
cd linux-vm && ./scripts/build-recovery-lima.sh
cd linux-vm && ./scripts/run-recovery.sh
```

The recovery image now uses a repo-owned rescue substrate with no BusyBox at
all. `board/recovery-init.c` still handles the early `/dev`, `/proc`, `/sys`,
console, and banner setup, then execs `/bin/sh`, which is now a symlink to the
custom multicall binary built from `board/recovery-toolbox.c`. The final
initramfs exposes a small explicit command surface: `help`, `sh`, `ls`, `cat`,
`dmesg`, `sysctl`, `uname`, `lsmod`, `poweroff`, and `reboot`.

### BusyBox-less contract

The current repository contract is that both bootable images are BusyBox-free,
but they are not assembled the same way.

For the normal phase-2 ext4 image:

- QEMU boots the kernel directly with `root=/dev/vda`, so `/linuxrc` is intentionally absent
- `/bin/busybox` is intentionally absent from the seed image
- early-boot paths are seeded from direct Buildroot providers rather than BusyBox applets
- the final ext4 tree is still mostly Buildroot package output plus the checked-in repo-owned normal seed tree and `board/normal-post-fakeroot.sh` normalization; unlike recovery, it is not yet assembled as a wholly repo-owned final userspace tree
- some legacy paths remain as intentional compatibility links to those non-BusyBox providers, such as `/bin/sh`, `/sbin/getty`, `/sbin/{ifup,ifdown}`, and `/sbin/{insmod,lsmod,modprobe,rmmod}`
- later boot hooks may repoint selected paths like `/bin/sh`, `/sbin/getty`, and parts of the userland surface to managed `/usr/local` providers, but the seeded image itself must already boot cleanly without BusyBox

For the recovery initramfs:

- QEMU boots with `rdinit=/init`, and that `/init` is the repo-owned binary built from `board/recovery-init.c`
- `/bin/sh` and the advertised recovery commands are symlinks to the repo-owned multicall binary `recovery/toolbox`
- `/bin/busybox`, `/linuxrc`, and BusyBox-backed recovery command links are intentionally absent
- the final userspace tree is repo-owned and intentionally minimal; Buildroot is still used to build the kernel and target toolchain, and its cpio packing step still contributes the required `/dev/console` device node

When changing this area, the important distinction is between intentional
runtime contract and build-time assembly mechanics. BusyBox-free means the
booted normal image and the booted recovery image must not depend on BusyBox
binaries or BusyBox applet symlinks for their supported workflows, even if
Buildroot still provides the kernel/toolchain build and the final cpio packing
step. The repo-owned proof command for that contract is:

```bash
cd linux-vm && ./scripts/validate-busyboxless.sh
```

That validator checks the built normal `rootfs.ext4` and recovery
`rootfs.cpio.gz` artifacts for BusyBox leakage, verifies that
`rootfs/bootstrap-manifest.toml` still matches the checked-in
`board/normal-rootfs-tree/` and the now-narrow mutable `board/rootfs-overlay/`
surface, checks that the normal artifact still contains the declared repo-owned
seed paths without shipping managed `/usr/local` payloads, boots an isolated
copy of the normal image with fresh temporary root/data disks to verify the
same ownership boundary live, and then boots recovery through a pseudo-terminal
to prove the custom prompt, `sh -c` path, repo-owned command surface, and clean
shutdown still work. Use `--artifacts-only` or `--live-only` when you only want
one half of the proof.

### Reset the root filesystem back to the current Buildroot image

```bash
cd linux-vm && RESET_ROOT_DISK=1 ./scripts/run-phase2.sh
```

### Keep the current root filesystem and just reboot

```bash
cd linux-vm && ./scripts/run-phase2.sh
```

### Boot recovery mode through the shared launcher

```bash
cd linux-vm && BOOT_MODE=recovery ./scripts/run-phase2.sh
```

### Build software natively in the guest and keep it persistent

- use `/` for normal system installs that should remain part of the persistent root
- use `/Volumes/slopos-data` for large source/build/install trees and versioned persistent payloads

### Try the `sloppkg` prototype on the host

```bash
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" init
cd linux-vm && ./scripts/sloppkg.sh repo export --output /tmp/sloppkg-repo --channel stable --revision local
cd /tmp/sloppkg-repo && python3 -m http.server 8080
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" repo list
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" repo add --name main --kind unified --url http://127.0.0.1:8080 --channel stable
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" update
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" resolve curl --json
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" build hello-stage --json
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" repo index --json
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" install hello-stage --root "$(mktemp -d)/root" --json
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" upgrade --root "$(mktemp -d)/root" --json
cd linux-vm && ./scripts/sloppkg.sh --state-root "$(mktemp -d)/state" remove hello-stage --root "$(mktemp -d)/root" --json
```

This first slice implements:

- Rust workspace and crate boundaries
- package and repo metadata parsing from `packages/`
- RPM-style EVR comparison and constraint parsing
- deterministic dependency resolution with virtual providers
- SQLite state bootstrap and repository config
- offline build staging into `DESTDIR`
- JSON manifest generation for staged filesystem contents
- binary package emission as `.sloppkg.tar.zst`
- binary repository index generation as `state/packages/repodata/index.sqlite.zst`
- dependency-aware cache-backed install/upgrade/remove transactions into a target root
- world-set tracking for explicit package requests plus auto dependency tracking
- transaction records under `state/db/transactions/`
- cache metadata records in SQLite under `cache_packages`

The sample package `packages/hello-stage/0.1.0-1/` is included specifically to exercise the offline build/stage path without relying on network fetches.

The workspace now also includes a first native bootstrap toolchain slice under `packages/`:

- `binutils/2.45-1`
- `gmp/6.3.0-1`
- `mpfr/4.2.1-1`
- `mpc/1.3.1-1`
- `gcc/14.3.0-1`

These recipes are intentionally aimed at `/usr/local` so they can layer on top of the current Buildroot-owned base system without fighting it for ownership.

Because `sloppkg` currently resolves build dependencies but does not yet inject them into an isolated build sysroot, the working bootstrap flow today is sequential on the guest:

```bash
mkdir -p /Volumes/slopos-data/pkg/distfiles

# Either preseed the release tarballs into the distfile cache with these exact names:
#   binutils-2.45.tar.xz
#   gmp-6.3.0.tar.xz
#   mpfr-4.2.1.tar.xz
#   mpc-1.3.1.tar.gz
#   gcc-14.3.0.tar.xz
#
# Or let sloppkg fetch verified remote distfiles into that cache:
#   sloppkg fetch binutils
#   sloppkg fetch gmp
#   sloppkg fetch mpfr
#   sloppkg fetch mpc
#   sloppkg fetch gcc

cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg init

cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg build binutils
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg install binutils --root /

cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg build gmp
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg install gmp --root /

cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg build mpfr
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg install mpfr --root /

cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg build mpc
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg install mpc --root /

cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg build gcc
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg install gcc --root /
```

After that first pass, `/usr/local/bin/gcc` can be used as the preferred compiler. The recipe schema's `[build].env` table is now honored by the build runner, so a second-pass self-hosted rebuild is possible by bumping a recipe release and setting compiler variables such as:

```toml
[build.env]
CC = "/usr/local/bin/gcc"
CXX = "/usr/local/bin/g++"
AR = "/usr/local/bin/ar"
RANLIB = "/usr/local/bin/ranlib"
```

That second pass is the clean way to rebuild the bootstrap libraries with the freshly installed compiler, and then rebuild `gcc` with itself.

Each successful `sloppkg build` now emits:

- `manifest.json`
- `pkg-info.toml`
- a per-build log under `state/logs/builds/<transaction>-<package>.log`
- a cached archive in `state/packages/<name>/*.sloppkg.tar.zst`
- a refreshed binary repo metadata file at `state/packages/repo.toml`
- a refreshed binary repo index at `state/packages/repodata/index.sqlite.zst`

The CLI now also reports that log path directly in the build summary, and failed
build transactions write a JSON record under `state/db/transactions/` with the
failure `status`, the captured `log_path`, and the surfaced error string. That
gives the later guest-native rebuild workflow a stable place to look for build
forensics instead of relying on transient terminal output.

Install/upgrade/remove transactions now use the same directory for durable
status records too. A successful package commit is no longer marked complete
until the post-success maintenance pass finishes; if runtime-hook refresh,
repo-publish, or cleanup fails after package contents were already applied, the
transaction record is left in `status = "maintenance-failed"` with a
`maintenance.error` field instead of pretending the transaction completed
cleanly.

You can also regenerate the binary repo metadata explicitly with:

```bash
cd linux-vm && ./scripts/sloppkg.sh repo index
```

Cached packages can be applied into a target root with:

```bash
cd linux-vm && ./scripts/sloppkg.sh install hello-stage --root /path/to/root
cd linux-vm && ./scripts/sloppkg.sh upgrade --root /path/to/root
cd linux-vm && ./scripts/sloppkg.sh remove hello-stage --root /path/to/root
```

To move the working self-hosted toolchain under package-manager control without breaking the earlier bootstrap slice, the workspace now also includes a managed self-host package set:

- `selfhost-gmp/6.3.0-1`
- `selfhost-mpfr/4.1.1-1`
- `selfhost-mpc/1.3.1-1`
- `selfhost-binutils/2.45.1-1`
- `selfhost-gcc-stage2/14.3.0-1`
- `selfhost-glibc/2.43-1`
- `selfhost-gcc/14.3.0-1`
- `selfhost-toolchain/14.3.0-1`

These recipes intentionally keep the older `/usr/local` bootstrap recipes intact. The self-host package set tracks the versions that are actually cached and proven in the guest today, especially:

- `binutils 2.45.1`
- `mpfr 4.1.1`

`sloppkg install` is no longer limited to `/usr/local`. It now honors each package's `owned_prefixes`, which allows managed packages to own:

- stable wrappers under `/usr/bin` and `/usr/local/bin`
- the self-hosted toolchain trees under `/Volumes/slopos-data/toolchain/*`

Because `sloppkg` still does not inject build dependencies into an isolated build sysroot, the self-host toolchain recipes now declare a bootstrap pre-pass directly in `selfhost-toolchain` instead of relying on an external wrapper script. The bootstrap-aware install flow is:

```bash
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg install selfhost-toolchain --root /
```

During that install, `sloppkg` detects the recipe's `[bootstrap]` section and:

- plans named bootstrap stages from recipe metadata
- builds stage packages in dependency order
- materializes each stage onto the guest root without recording it as a normal installed package yet
- writes resume stamps under `state/db/bootstrap-stamps/selfhost-toolchain/`
- skips completed stages on re-run as long as their cached archives still exist
- returns to the normal cache-backed install transaction once the bootstrap stages finish

Bootstrap builds can leave large transaction work trees under `state/build/`, especially for the GCC stages. `sloppkg cleanup` now prunes that state directly from the package manager:

```bash
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg cleanup builds
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg cleanup repos
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg cleanup published
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg cleanup
```

`cleanup builds` removes transaction-scoped build directories whose transactions are already terminal, `cleanup repos` removes stale unified-repo snapshot revisions while keeping the active cached revision for each configured repo/channel, and `cleanup published` prunes old exported HTTP revisions under `state/published/` while keeping the current live revision plus the configured retention window.

The current `selfhost-toolchain` stages are:

- `stage1-libs` for `selfhost-gmp`, `selfhost-mpfr`, and `selfhost-mpc`
- `stage2-binutils` for `selfhost-binutils`
- `stage3-gcc-stage2` for the transitional `selfhost-gcc-stage2`
- `stage4-glibc` for `selfhost-glibc`
- `stage5-final-gcc` for `selfhost-gcc`
- `stage6-world` to emit the world package archive itself

`selfhost-gcc-stage2` is intentionally still a managed transitional package. It exists so the rebuild of `glibc` and the final `gcc/g++` can be expressed inside `sloppkg`, but it is not the desired steady-state compiler entrypoint. The stable guest wrappers are owned by `selfhost-binutils` and `selfhost-gcc`.

Once the full chain is built and installed, `selfhost-toolchain` can be used as the world package that tracks the steady-state self-hosted stack for upgrades. `sloppkg upgrade --root /` now reruns bootstrap pre-passes for bootstrap-enabled world packages before the normal cache-backed reinstall step, instead of trying to rebuild leaf stage packages like `selfhost-binutils` out of bootstrap context:

```bash
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg install selfhost-toolchain --root /
cd linux-vm && ./scripts/sloppkg.sh --state-root /Volumes/slopos-data/pkg upgrade --root /
```

The bootstrap metadata currently uses:

- one growing toolchain sysroot at `/Volumes/slopos-data/toolchain/selfhost-sysroot`
- explicit stage environment variables declared in the recipe, rather than implicit sysroot injection
- the existing native glibc stage at `/Volumes/slopos-data/toolchain/glibc-stage` as the transitional sysroot for `selfhost-gcc-stage2`

Bootstrap-aware installs currently require `--root /`, because the stage pre-pass needs to materialize toolchains onto the live guest filesystem before later stages can execute.

The legacy `scripts/build-selfhost-*.sh` helpers are intentionally no longer the recommended path here. They remain useful as narrow reproduction tools, but the architecture goal is that the guest toolchain lifecycle is expressed through `selfhost-toolchain` and `sloppkg`, not through a hand-run shell-script sequence.

The current transaction path:

- resolves runtime dependencies from recipe metadata
- optionally runs the bootstrap pre-pass for recipes that declare `[bootstrap]`
- reuses cached archives only when the cached entry still matches the current recipe hash, otherwise rebuilds the package into cache before install/upgrade
- installs cached archives in dependency order
- records explicit packages in the world set and marks transitive packages as `auto`
- rejects direct removal of packages that still have installed dependents
- autoremoves no-longer-needed auto dependencies on `remove`
- reevaluates the world set on `upgrade`
- upgrades cached packages in place and drops stale files from older manifests
- unpacks the cached `.sloppkg.tar.zst`
- only commits managed paths declared in each package's `owned_prefixes`
- records installed package and file ownership metadata in SQLite
- allows rerunning the same install as a repair/reinstall for that package

What is still missing:

- recipe-repo sync and fetch from remote repositories
- richer upgrade policy features such as holds, pins, and provider-switch handling

### Unified remote recipe-repo model

`sloppkg` now has a first working remote recipe sync path for a single canonical repo served over static HTTP.

Repository configuration now distinguishes:

- local filesystem repos such as the workspace checkout: `kind = "recipe"` with `sync_strategy = "file"`
- future remote served repos: `kind = "unified"` with `sync_strategy = "static-http"`
- a selected recipe `channel` such as `stable`
- `trust_policy = "digest-pinned"` for remote metadata verified by SHA-256 digests

The intended remote layout is TOML all the way down:

```toml
# repo.toml
format_version = 1
name = "slopos-main"
kind = "unified"
generated_at = "2026-01-01T00:00:00Z"
default_channel = "stable"
capabilities = ["recipes"]

[recipes.channels.stable]
current_revision = "2026.01.01"
index_path = "recipes/index/stable.toml"
index_sha256 = "..."

[trust]
mode = "digest-pinned"
signatures = "none"
```

```toml
# recipes/index/stable.toml
format_version = 1
repo_name = "slopos-main"
channel = "stable"
revision = "2026.01.01"
generated_at = "2026-01-01T00:00:00Z"

[[recipes]]
name = "gcc"

[[recipes.versions]]
version = "14.3.0"
release = "1"
manifest_path = "recipes/by-name/gcc/14.3.0-1/manifest.toml"
manifest_sha256 = "..."
```

```toml
# recipes/by-name/gcc/14.3.0-1/manifest.toml
format_version = 1
package_name = "gcc"
version = "14.3.0"
release = "1"

[[files]]
path = "package.toml"
sha256 = "..."

[[files]]
path = "build.sh"
sha256 = "..."
```

That shape now drives `sloppkg update`:

- `sloppkg repo add --kind unified --url http://... --channel stable`
- `sloppkg update` fetching `repo.toml`, the active channel index, each referenced recipe manifest, and each listed recipe file
- the synced snapshot being materialized locally under `state/repos/snapshots/<repo>/<channel>/<revision>/`
- the active channel pointer being recorded under `state/repos/<repo>/`
- later `resolve`, `build`, and `install` loading from that cached local snapshot rather than requiring a Git checkout in the guest

To serve the current workspace repo over static HTTP:

```bash
cd linux-vm && ./scripts/sloppkg.sh repo export --output /tmp/sloppkg-repo --channel stable --revision local
cd /tmp/sloppkg-repo && python3 -m http.server 8080
```

Then, from the guest:

```bash
sloppkg repo add --name main --kind unified --url http://HOST_IP:8080 --channel stable
sloppkg update
sloppkg resolve sloppkg
```

The export step is important: the raw local `packages/` tree is a development recipe repo, while `sloppkg update` consumes the unified static-HTTP layout produced by `repo export`.

`sloppkg` now also has a first-class publish step for the served-repo side of that workflow:

```bash
cd linux-vm && ./scripts/sloppkg.sh repo publish --name workspace --channel stable
cd linux-vm && ./scripts/sloppkg.sh repo publish --name workspace-candidate --channel candidate --no-remember
cd linux-vm && ./scripts/sloppkg.sh repo promote --source-name workspace-candidate --source-channel candidate --target-name workspace --target-channel stable
```

That writes immutable exported revisions under `state/published/<repo>/revisions/<channel>/`, updates `state/published/<repo>/live` to the newest revision, and records the publish settings so later successful `install` and `upgrade` runs can republish automatically. Candidate publishes should use a separate repo name such as `workspace-candidate`, not just a different channel, because the live served view is tracked per repo. `--no-remember` keeps those candidate publishes out of the automatic post-transaction republish path, and `repo promote` copies an exact already-published candidate revision into the stable repo view instead of re-exporting from whatever the recipe tree contains later.

For the running guest, the host helper:

```bash
slopos-publish-http-repo
```

publishes the guest recipe tree at `/Volumes/slopos-data/packages/` through `sloppkg repo publish`, serves `state/published/workspace/live` on the guest loopback `python3 -m http.server` at `127.0.0.1:18083`, records the unified repo in the guest config, and runs `sloppkg update` so the configured snapshot stays current.

It also now supports:

- `--no-remember` for candidate publishes that must not become auto-republish state
- `--skip-repo-config` for one-off served views used only during rebuild validation
- `--serve-only` to expose an already-promoted live root without exporting it again

From the host, the thin convenience wrapper:

```bash
cd linux-vm && ./scripts/publish-guest-http-repo.sh
```

just stages the checked-in guest helper into the VM and invokes it over SSH.

### Managed guest sloppkg runtime

The guest runtime is now meant to be package-managed too.

The checked-in recipe `packages/sloppkg/0.1.0-1/package.toml` installs the managed binary at `/Volumes/slopos-data/opt/sloppkg/current/bin/sloppkg`, and `board/normal-rootfs-tree/etc/init.d/S16persistent-sloppkg` exposes it back at `/usr/local/bin/sloppkg` on each boot. That keeps `sloppkg` available after a root reset as long as the persistent disk survives.

The host helper:

```bash
cd linux-vm && ./scripts/install-sloppkg-guest-package.sh
```

does three things:

- cross-builds the current guest `sloppkg` binary on the host
- seeds that binary into the guest recipe repo at `/Volumes/slopos-data/packages/sloppkg/0.1.0-1/`
- seeds a temporary bootstrap copy at `/tmp/sloppkg-bootstrap` so the handoff no longer depends on an already-working root copy
- uses the guest package manager with `--recipe-root /Volumes/slopos-data/packages` so the freshly seeded local recipe overrides any configured repo snapshots during the self-update handoff
- rebuilds `sloppkg` into the guest cache when the cached archive is missing or the recipe content changed, then reinstalls it on the persistent disk and refreshes `/usr/local/bin/sloppkg`
- republishes the guest unified HTTP repo afterward so normal in-guest `update`/`upgrade` runs can stay purely snapshot-backed

After that handoff, the guest records `sloppkg` itself as an explicitly installed package, so later refreshes can be handled by the package manager instead of a one-off copied binary.

The intended steady-state guest workflow is now:

```bash
slopos-publish-http-repo
sloppkg update
sloppkg upgrade --root /
```

with no `--recipe-root` override needed during ordinary operation, as long as the configured unified repo has been refreshed from the guest recipe tree.

Once `repo publish` has been run at least once for that guest repo, successful `sloppkg install ... --root /` and `sloppkg upgrade --root /` runs also republish the served repo automatically and run `cleanup` maintenance afterward. Those successful root transactions now rerun the boot-time reconnection hooks that package upgrades can affect: `S14persistent-dropbear`, `S15local-lib-links`, `S16persistent-sloppkg`, `S17persistent-getty`, `S19persistent-sh`, and `S20managed-userland-links`. That means persistent Dropbear exposure, the `/usr/local/bin/sloppkg` handoff, the managed `agetty` handoff, the managed `dash` handoff, the live `/usr/lib64` linker view, and the selected non-boot-critical userland path handoffs and stale-link cleanup are refreshed immediately after a successful transaction instead of waiting for the next reboot.

For candidate rebuild validation, the package manager also now supports `install`, `upgrade`, and `remove` with `--skip-publish-maintenance`. That still refreshes the runtime reconnection hooks, but it suppresses remembered repo republish so local recipe-root testing cannot accidentally mutate the stable served repo.

### Ordinary upgrades vs bootstrap events

The steady-state operator flow is:

```bash
sloppkg update
sloppkg upgrade --root /
```

Treat that as the normal path for world/package-manager evolution when you are changing recipes or versions inside the current managed shape: `sloppkg` itself, `selfhost-world`, the `selfhost-{base,devel,network}` slices, and ordinary leaf/runtime libraries such as `curl`, `sqlite`, `openssl`, `ncurses`, `dash`, or `util-linux`.

Treat an upgrade as a bootstrap/toolchain event when it changes the bootstrap-enabled compiler stack or the assumptions that stack is built around, especially:

- `selfhost-toolchain`
- `selfhost-binutils`
- `selfhost-glibc`
- `selfhost-gcc`
- bootstrap stage definitions, sysroot layout, or compiler-wrapper layout

For that class of change, the supported path remains explicit toolchain convergence first, then a normal world upgrade:

```bash
sloppkg install selfhost-toolchain --root /
sloppkg upgrade --root /
```

`sloppkg upgrade --root /` already reruns bootstrap pre-passes for bootstrap-enabled world packages, so routine world upgrades stay consistent once the intended toolchain state has been selected.

### Known-good reseed restore set

After a root reset, the persistent disk still carries the current recipe repo, package cache, managed `sloppkg`, persistent Dropbear, and the selfhost toolchain. The current known-good restore target is the meta-package-defined world:

- `selfhost-base` for the core managed runtime and userland
- `selfhost-devel` for the build/development stack
- `selfhost-network` for the managed network tools
- `selfhost-toolchain` for the persistent self-host compiler stack
- `selfhost-world` for the full intended guest profile

The validated replay flow for an already-seeded persistent state is:

```bash
cd linux-vm && ./scripts/sync-guest-world.sh
cd linux-vm && ./scripts/ssh-guest.sh 'reboot'
```

That flow was validated after a fresh `RESET_ROOT_DISK=1` reseed against a rebuilt seed image that already contained the guest orchestration helpers. The fresh boot exposed `/usr/sbin/slopos-publish-http-repo`, `/usr/sbin/slopos-sync-world`, seeded `shadow` `/bin/login`, seeded `/bin/dash`, seeded `/sbin/getty -> /sbin/agetty`, and persistent `sloppkg`; running `slopos-sync-world` in-guest then replayed the 76-package world from persistent state, republished the unified repo, reran the bootstrap pre-pass for `selfhost-toolchain`, restored `/sbin/getty -> /usr/local/sbin/agetty`, restored `/bin/sh -> /usr/local/bin/dash`, kept the seeded `shadow` `/bin/login` binary in place, and left `/bin/ash` absent without live guest surgery. A follow-up reboot proved the recovered guest came back with the guest helpers still present, persistent Dropbear still exposed, no BusyBox `ash`/`login`/`sh` applets, and `sloppkg doctor` still clean at 76 packages. When bootstrapping a new package-manager state rather than replaying an existing one, `selfhost-world` is the canonical full-system package target to install, and the guest-side helper accepts that explicitly:

```bash
slopos-sync-world --install-target selfhost-world

If no world packages are recorded yet, `slopos-sync-world` now treats that
empty-state case as a bootstrap event automatically and installs the canonical
target `selfhost-world` by default before returning to ordinary `upgrade`
behavior on later runs.
```

There is now a checked-in proof script for that contract too:

```bash
cd linux-vm && ./scripts/validate-reset-to-world.sh
```

It boots an isolated temporary VM with a fresh Buildroot root disk and a cloned
persistent data disk, verifies the reset seed already exposes the guest
orchestration helpers, stages the current checked-in `slopos-publish-http-repo`
and `slopos-sync-world` helpers plus a host-built current `sloppkg` binary into
that temporary guest, runs the in-guest replay flow, reboots, and then confirms
the managed `dash`, managed `agetty`, persistent Dropbear handoff, and
`sloppkg doctor` state all survive the replay. Because it works from an
isolated cloned data disk, it also prunes stale published/build/snapshot state
on that clone before replaying the world so an overfull persistent disk does
not block the proof, and it now fails early if the cloned persistent cache is
not ready for the current `selfhost-world` recipe set (currently observed as
`package cache is not ready for libuv: stale`).

For the next managed-world rebuild phase, the normal seed now also carries a
guest-side readiness probe:

```bash
slopos-validate-rebuild-readiness --package hello-stage --world-target selfhost-world
```

That helper checks the persistent mountpoint, recipe-root presence, managed
`sloppkg`, the final selfhost compiler wrappers, writable `state_root`,
distfiles, and build-log directories, then optionally runs `sloppkg resolve`
plus `sloppkg fetch` for the requested targets. The intended build-log location
for rebuild work is `state/logs/builds/`.

The first guest-side rebuild workflow now lives in:

```bash
slopos-validate-managed-world --world-target selfhost-world
slopos-rebuild-world --package hello-stage
slopos-rebuild-world --package hello-stage --install-target hello-stage
slopos-rebuild-world --slice selfhost-world --prefetch-only
slopos-rebuild-world --package openssl --with-installed-dependents
slopos-rebuild-world --package openssl --with-installed-dependents --force-rebuild
slopos-rebuild-world --slice selfhost-devel
slopos-promote-rebuild --source-name workspace-candidate --source-channel candidate --target-name workspace --target-channel stable
cd linux-vm && ./scripts/validate-guest-world.sh --world-target selfhost-world
cd linux-vm && ./scripts/rebuild-guest-world.sh --package hello-stage
cd linux-vm && ./scripts/promote-guest-world.sh
```

`slopos-rebuild-world` runs the readiness probe, ensures one or more selected
packages are ready in the guest package cache, publishes a candidate unified
repo snapshot, and then either installs explicit targets or reuses the normal
world-convergence path through `slopos-sync-world`. During that convergence it
loads packages directly from `--recipe-root /Volumes/slopos-data/packages` and
passes `--skip-publish-maintenance`, so the rebuilt guest is tested against the
current candidate recipe tree without mutating the remembered stable served repo.
By default it first checks `sloppkg cache-status` and reuses an existing package
archive when the current recipe hash is already packaged; `--force-rebuild`
bypasses that and restages every selected package. `--prefetch-only` exposes the
readiness step as a supported workflow for larger waves: resolve the expanded
target set, fetch or verify their distfiles up front, and stop before any
publish/install work. That keeps rebuild logic guest-resident while the host
wrapper remains only an SSH transport convenience. The helper now also
serializes itself with `state/locks/rebuild-world.lock` and writes a workflow log
under `state/logs/rebuilds/`, so later publish/install failures still leave a
durable phase trace. Successful install/upgrade flows now also run
`slopos-validate-managed-world` before they report success unless
`--no-validate` is requested explicitly, and successful runs print the explicit
`repo promote` command needed to move the candidate revision into the stable
repo view.

`slopos-validate-managed-world` is the canonical guest-side smoke suite for the
current managed world. It validates the expected managed command resolution,
rechecks the seeded shell/init scripts with `dash -n`, exercises gzip/tar and
representative coreutils paths, runs a root-only util-linux bind-mount round
trip, compiles and runs a tiny C program through the current `gcc`/`make`
toolchain, checks `file`, `perl`, `prove`, and `pod2man`, republishes the guest
HTTP repo, and then validates the managed networking surface with `ip`, `ss`,
`ping`, `traceroute`, `nc`, `wget`, and `curl`. Validation logs land under
`state/logs/validations/`. The thin host wrapper `scripts/validate-guest-world.sh`
stages that checked-in helper and runs it over SSH.

The supported operator story is now explicit:

- **leaf rebuilds** use `--package` and optionally `--install-target`; they keep
  the simple batch behavior and are the right tool for rebuilding one package
  or a small hand-picked set
- **coordinated rebuild waves** use `--with-installed-dependents` and/or
  `--slice`; those modes expand the affected package set, order it through
  `sloppkg resolve`, and rerun `slopos-sync-world --skip-publish --recipe-root ... --skip-publish-maintenance`
  after each rebuilt package so later builds see the refreshed managed root
- the current named slice targets are the meta-packages `selfhost-base`,
  `selfhost-devel`, `selfhost-network`, `selfhost-toolchain`, and
  `selfhost-world`
- **promotion** is a separate explicit step: candidate publishes are not
  remembered and do not rewrite the stable repo until `slopos-promote-rebuild`
  or `sloppkg repo promote` is run

For inspection, `sloppkg dependents --json --transitive <package>` now reports
the installed reverse-dependency set that coordinated rebuild waves expand from,
and `sloppkg cache-status --json <package>` reports whether the currently
selected recipe already has a matching cached package archive.

### Guest-native kernel artifacts

The next boundary below full guest-native image assembly is now a supported
kernel-artifact workflow:

```bash
slopos-build-kernel-artifacts
cd linux-vm && ./scripts/build-guest-kernel-artifacts.sh
cd linux-vm && ./scripts/promote-guest-kernel-candidate.sh
cd linux-vm && KERNEL_IMAGE=artifacts/guest-kernel-candidate/current/Image ./scripts/run-phase2.sh
cd linux-vm && ./scripts/validate-guest-combined-boot-candidate.sh
```

That workflow still keeps the default boot path conservative. The authoritative
normal boot kernel remains `artifacts/buildroot-output/images/Image`, and the
recovery flow still comes from `artifacts/buildroot-recovery-output/`, but the
latest guest-built kernel can now be copied into a host-side candidate path for
explicit opt-in testing with `KERNEL_IMAGE=...`.

Instead, `scripts/build-guest-kernel-artifacts.sh` parses the current normal
Buildroot defconfig to discover the kernel version, checked-in kernel config,
and board patch directory, stages those exact inputs plus the matching
`buildroot-src/dl/linux/linux-<version>.tar.*` archive into
`/Volumes/slopos-data/kernel/input/current`, and then invokes the checked-in
guest helper `/usr/sbin/slopos-build-kernel-artifacts`.

The guest helper builds `Image` and modules natively with the current managed
toolchain, validates that the built `Image` exists and that module installation
produced a non-empty `lib/modules/<kernelrelease>/` tree, packages that module
tree as `modules.tar.xz`, records the staged input files alongside the output,
writes a schema-3 manifest plus build log, and updates
`/Volumes/slopos-data/kernel/artifacts/current` to the latest successful build.

`scripts/promote-guest-kernel-candidate.sh` then copies the current guest
artifact's `Image`, `modules.tar.xz`, `System.map`, resolved `linux.config`,
and manifest back to `artifacts/guest-kernel-candidate/<artifact>/`, records
host-side provenance, and refreshes `artifacts/guest-kernel-candidate/current` for later boot
handoff testing.

The resulting persistent layout is:

- `input/current/` for the staged Buildroot-derived kernel inputs
- `artifacts/<kernelrelease>-<timestamp>/` for a versioned validated output set
- `artifacts/current` as the latest successful artifact pointer
- `logs/` for durable guest-native kernel build logs

This keeps kernel config and patch ownership aligned with the existing normal
Buildroot defconfig while making the actual compile step guest-native. The
default normal boot kernel remains Buildroot-owned, but there is now a
host-visible candidate handoff path for later explicit boot validation.

### Guest-native rootfs artifacts

There is now also a first guest-native rootfs/image assembly path:

```bash
slopos-build-rootfs-artifacts
cd linux-vm && ./scripts/build-guest-rootfs-artifacts.sh
cd linux-vm && ./scripts/audit-guest-ext4-sealing.sh
cd linux-vm && ./scripts/validate-guest-mke2fs-d-support.sh
cd linux-vm && ./scripts/validate-guest-rootfs-artifacts.sh
cd linux-vm && ./scripts/validate-guest-rootfs-boot-candidate.sh
cd linux-vm && ./scripts/validate-guest-combined-boot-candidate.sh
cd linux-vm && RESET_ROOT_DISK=1 ROOTFS_SOURCE_IMAGE=artifacts/guest-rootfs-candidate/current/rootfs.ext4 ./scripts/run-phase2.sh
```

This path still keeps the current ownership boundary honest. The normal bootable
rootfs surface is still mostly Buildroot-owned, so the host wrapper first
extracts the current Buildroot `rootfs.ext4` into a staged plain tar archive
and ships that base tree into a versioned
`/Volumes/slopos-data/rootfs/input/<bundle>/` directory alongside the checked-in
`board/normal-post-fakeroot.sh`, `board/normal-rootfs-tree/`, a synthesized
`rootfs-overlay/` projection containing only the manifest-declared
`mutable_overlay_paths` entries from `board/rootfs-overlay/`, the current
normal defconfig, the bootstrap manifest, and a `rootfs-inputs.toml`
provenance file before advancing `input/current` to that explicit staged
bundle.

The guest helper `/usr/sbin/slopos-build-rootfs-artifacts` then reruns the same
normal-image assembly hook in-guest, normalizes the extracted base tree back to
`root:root` ownership so host UID/GID values do not leak into the rebuilt
image, clears transient `run/` and `tmp/` contents, archives the assembled tree
as `rootfs-tree.tar`, and on the current rebuilt seed image now seals
`rootfs.ext4` directly in-guest with `mke2fs -t ext4 -d` using the defconfig’s
label and size. The tar staging path stays intentionally uncompressed so the
seeded guest-native builder does not depend on a seeded `gzip` binary or Python
compression stdlib modules. The host/Lima wrapper still retains the old sealing
path as a compatibility fallback for older guests that have not yet been
reseeded onto that new image, but that fallback is now explicit: set
`ALLOW_HOST_ROOTFS_SEAL_FALLBACK=0` to fail instead of silently resealing on
the host. Before the helper applies the repo-owned assembly hook, it now also
checks the extracted base archive against the manifest-declared
`buildroot_seed_surface.critical_paths` plus `disallowed_paths` so the current
stage0 substrate is explicit instead of implicit.

The guest rootfs artifact manifest now records more of that contract directly:

- the staged `rootfs-inputs.toml` provenance file and a deterministic
  `input-root.manifest` for the full staged input bundle
- the staged `normal-post-fakeroot.sh` assembly hook and its SHA-256
- deterministic manifests for the staged `normal-rootfs-tree/` and synthesized
  `rootfs-overlay/` inputs
- both the guest-produced seal state (`staged_seal_method`) and the final seal
  state (`seal_method`), so host fallback remains auditable instead of implicit

That rootfs artifact manifest is now `schema_version = 3`, matching the shift
from implicit `input/current` assumptions to explicit staged-input provenance.

The checked-in ext4 audit path now makes the transition boundary concrete:

- the rebuilt seed now includes `e2fsprogs`, so the intended guest-native path
  is `mke2fs -d`, not loop-mounted image population
- managed util-linux `losetup` and `mount` are already present in the guest, but
  the checked-in kernel config still does not enable `CONFIG_BLK_DEV_LOOP`
- older guests that have not yet been reseeded still show the old blocker set:
  BusyBox `mke2fs` without `-d`, no `/dev/loop*` nodes, `modprobe loop`
  failing, and `mount -o loop` failing

That transition is now proven end to end:

1. reseed onto the rebuilt image that carries `e2fsprogs`
2. run `scripts/validate-guest-mke2fs-d-support.sh` to prove the temporary
   guest audit reports `guest_native_ext4_ready: yes`
3. confirm `scripts/build-guest-rootfs-artifacts.sh` records
   `seal_method = "guest-mke2fs-d"` while `ALLOW_HOST_ROOTFS_SEAL_FALLBACK=0`
   forbids the host rescue path
4. keep kernel loop support only as a separate later option if the project
   still wants a second in-guest image-population strategy beyond `mke2fs -d`

The validated guest-built image is still a host-side handoff artifact first.
`scripts/validate-guest-rootfs-artifacts.sh` copies the latest guest-built image
back to the host, runs the existing BusyBox-less/isolated-boot checks against
it, and promotes the validated result into
`artifacts/guest-rootfs-candidate/current/`. That handoff directory now also
includes `host-handoff.toml`, which records the copied image/manifest SHA-256
values, the guest manifest `schema_version`, and both the final
`seal_method` plus the original `staged_seal_method`. A host boot can then opt into that
candidate explicitly with
`ROOTFS_SOURCE_IMAGE=artifacts/guest-rootfs-candidate/current/rootfs.ext4` plus
`RESET_ROOT_DISK=1`. `scripts/validate-guest-rootfs-boot-candidate.sh` is the
targeted proof for that explicit host handoff path: it boots a temporary root
disk through `run-phase2.sh`, verifies that the reseed came from the candidate
image, and then reruns the live normal-seed contract checks over SSH. The
validator now also refuses to boot when the copied candidate hashes or schema
metadata do not match the handoff file.

`scripts/validate-guest-combined-boot-candidate.sh` extends that proof to the
full combined handoff path. It boots a temporary VM through `run-phase2.sh`
with both `ROOTFS_SOURCE_IMAGE=artifacts/guest-rootfs-candidate/current/rootfs.ext4`
and `KERNEL_IMAGE=artifacts/guest-kernel-candidate/current/Image`, verifies the
temporary root disk reseed and selected kernel path from the boot log, checks
that `uname -r` matches the guest-kernel candidate manifest, and then reruns
the live normal-seed contract over SSH. Before boot, it now rejects stale
rootfs/kernel handoff metadata so the host-side candidate pair stays auditable.
On the kernel side that now includes the candidate `System.map`, resolved
`linux.config`, and the schema-2 kernel input provenance entries.

Once that explicit combined handoff is trusted, `scripts/promote-guest-boot-default.sh`
can copy the current host-side candidates into
`artifacts/guest-boot-promoted/current/` as a paired default boot source without
overwriting `artifacts/buildroot-output/images/`. From that point on,
`ensure-root-disk.sh` will seed new or reset root disks from the resolved
promoted `rootfs.ext4` and record that exact rootfs+kernel generation in a
sibling `*.boot-selection.toml` file. `run-phase2.sh` reuses that recorded
kernel for later boots of the same root disk, so the promoted default behaves
like one atomic handoff instead of two independent lookups. The companion
`scripts/validate-promoted-boot-default.sh` boots a temporary VM with no
explicit boot overrides and proves from the boot log that the promoted default
pair was selected. The promoted directory also carries forward
`rootfs.host-handoff.toml`, `kernel.host-handoff.toml`, and a `promotion.toml`
whose hash fields must match the copied promoted artifacts, including the
promoted kernel `System.map` and resolved `linux.config`. `scripts/promote-guest-boot-default.sh --clear`
removes the current promoted symlink so future reseeds return to the Buildroot
rootfs and kernel artifacts, while already-seeded root disks keep using their
recorded pair until they are reset. `scripts/validate-promoted-boot-default.sh`
checks both the boot selection and the recorded root-disk metadata contract.
`scripts/validate-promoted-boot-rollback.sh` uses an isolated temporary
`HOST_GUEST_PROMOTED_BOOT_ROOT`, proves the promoted pair boots as the default,
clears that isolated promotion, and then proves a fresh no-override boot falls
back to `artifacts/buildroot-output/images/`.

## System ownership boundary

The current contract is:

- Buildroot target output plus the repo-owned seed assembly own the **seed image**
- `sloppkg` owns the **managed world**
- `/Volumes/slopos-data` owns the durable **persistent data/toolchain state**

The most important decision for the current roadmap is that **`/usr/local` remains the managed root prefix for now**. Moving package ownership deeper into `/usr` may happen later, but that is an explicit future boundary change, not part of the current baseline.

### Seed image

The seed image is still responsible for the things that must work before the managed world can repair or replace anything else:

- the kernel, seeded ext4 rootfs, and recovery initramfs
- init, device bring-up, and first-boot shell/network behavior
- HTTPS bootstrap transport (Python `_ssl`, CA certificates)
- the boot glue in `board/normal-rootfs-tree/etc/init.d/S11...S16`

In other words: Buildroot still owns **bootability and reconnection**, not the long-term ownership of every userspace tool.

#### Current normal seed assembly boundary

The normal ext4 seed image is the main unresolved ownership boundary heading into
Phase 12.

Today, the built `rootfs.ext4` shows that:

- Buildroot still emits the directory skeleton and most of `/bin`, `/sbin`, `/usr`, `/lib*`, plus the baseline `/etc` files and directories now listed under `etc_ownership.buildroot_provided_paths`
- the checked-in normal seed tree currently contributes `/init`, `/etc/inittab`, `/etc/profile.d/00-managed-path.sh`, `/etc/resolv.conf.static`, `/usr/sbin/slopos-publish-http-repo`, `/usr/sbin/slopos-rebuild-world`, `/usr/sbin/slopos-sync-world`, `/usr/sbin/slopos-validate-managed-world`, `/usr/sbin/slopos-validate-rebuild-readiness`, and the `S11`-`S20` boot glue
- `board/normal-post-fakeroot.sh` is now the explicit final-assembly hook for the normal image: it installs the checked-in seed tree, imports mutable `/root/.ssh/authorized_keys` data when present, consumes the checked-in `/usr/share/slopos/normal-post-fakeroot-prune.toml` contract to remove stale BusyBox leftovers and the unused `/linuxrc` path, rewires `/bin/sh -> dash`, `/sbin/getty -> /sbin/agetty`, `/sbin/{ifup,ifdown} -> /usr/sbin/*`, and prunes a few stale init hooks when direct providers are present
- `board/rootfs-overlay/root/.ssh/authorized_keys` is now the only mutable host-injected build input under `board/rootfs-overlay/`; the checked-in static seed files live under `board/normal-rootfs-tree/` instead, and `scripts/build-guest-rootfs-artifacts.sh` now rejects unexpected extra files there when it synthesizes the staged mutable overlay bundle
- `rootfs/bootstrap-manifest.toml` now also names the minimum `buildroot_seed_surface.critical_paths` that the extracted base archive must provide, plus the stage0 paths such as `/usr/bin/wget`, `/usr/bin/git`, `/usr/bin/file`, `/usr/bin/make`, `/usr/bin/patch`, `/usr/bin/perl`, and `/usr/bin/rsync` that are now intentionally absent before the guest helper is allowed to apply repo-owned normal-rootfs assembly
- a fresh seed image currently does **not** ship a populated `/usr/local`; managed `/usr/local` ownership is reintroduced later from persistent state by `sloppkg` and the boot-time reconnection hooks

That means the normal seed image is already BusyBox-free and boot-stable, but it
is still fundamentally a Buildroot-produced root filesystem with repo-owned
boot glue layered onto it. Phase 12 starts from making that boundary explicit so
the normal image can eventually follow recovery's lead and become a
deliberately repo-owned final tree too.

`rootfs/bootstrap-manifest.toml` now mirrors that boundary in machine-readable
form through `buildroot_owned_prefixes`, `buildroot_seed_surface`, `etc_ownership`,
`repo_owned_paths`, `mutable_overlay_paths`, `compatibility_symlinks`, and
`expected_empty_managed_prefixes`, so the rootfs validators can consume the same
ownership contract instead of hardcoding it.

### Managed world

The managed world is whatever `sloppkg` is authoritative for.

Today that means:

- root-owned package installs under `/usr/local`
- persistent service payloads under `/Volumes/slopos-data/opt/...`
- the canonical `selfhost-*` meta-packages and the installed `selfhost-world` target
- the selfhost toolchain stack as the long-term compiler authority

That is why packages such as `curl`, `sqlite`, `ncurses`, and friends install under `/usr/local`, while persistent service payloads like `dropbear` and `sloppkg` live on the data disk and get surfaced back into the root filesystem at boot.

### Persistent data/toolchain state

`/Volumes/slopos-data` is the durable handoff between root reseeds.

The important paths are:

- `/Volumes/slopos-data/packages` for the live recipe repo
- `/Volumes/slopos-data/pkg` for package-manager state, caches, built archives, and published repos
- `/Volumes/slopos-data/toolchain` for the selfhost compiler stack
- `/Volumes/slopos-data/opt/dropbear/current` for the persistent SSH payload
- `/Volumes/slopos-data/opt/sloppkg/current` for the persistent package-manager binary
- `/Volumes/slopos-data/ssh` for durable SSH authorization and host-key material

When `RESET_ROOT_DISK=1` is used, this data disk is expected to survive intact. The root image is allowed to be reseeded; the data disk is not.

### Minimum recoverable base world

The current recoverable package-manager targets are the named `selfhost-*`
profiles:

- `selfhost-base`
- `selfhost-network`
- `selfhost-devel`
- `selfhost-toolchain`
- `selfhost-world`

`selfhost-base` is the minimum named managed runtime profile; `selfhost-world`
is the canonical full guest profile and the default bootstrap target when a new
package-manager state has no recorded world entries yet. The validated reseed
replay now restores the full `selfhost-world` state from persistent guest data
without live guest surgery.

### Next handoff toward guest-native rebuilds

Phase 12 makes the seed boundary explicit, but it does **not** mean the guest
can already rebuild the whole bootable machine from inside itself.

The current host-owned/buildroot-owned responsibilities are still:

- `scripts/build-phase2-lima.sh` and `scripts/build-phase2-linux.sh` driving the
  Buildroot build, kernel compile, and seeded ext4 image production
- `scripts/build-recovery-lima.sh` and the recovery Buildroot flow producing the
  recovery kernel and initramfs artifacts
- `scripts/ensure-root-disk.sh`, `scripts/ensure-persistent-disk.sh`, and
  `scripts/run-phase2.sh` seeding disk images and launching QEMU
- `configs/slopos_aarch64_virt_defconfig` and
  `configs/slopos_aarch64_virt_recovery_defconfig` remaining the authority for
  the seeded kernel, rootfs package set, and recovery package set
- `configs/host-guest.env` remaining the authority for host/QEMU/Lima settings

The smallest realistic next phase is therefore **not** "guest-native ext4 image
production." It is:

1. keep using the current seed image and recovery image as the bootable host
   substrate
2. prove that the guest can rebuild the managed `sloppkg` world from source
   using the already-packaged selfhost toolchain and the current `/usr/local`
   ownership model
3. add a guest-native kernel build path that emits a testable kernel artifact
   into persistent state without yet replacing the host-built boot kernel
4. only then start designing guest-native rootfs/image assembly, once the
   remaining Buildroot-owned `/bin`, `/sbin`, `/usr`, and `/lib*` boundary is
   intentionally retired rather than implicitly bypassed

The main blockers for promising full guest-native ext4 production today are:

- there is no guest-native image builder or ext4 assembly flow yet
- there is no package-managed kernel build/install path yet
- kernel/modules/initramfs coupling is still owned by the Buildroot build
- the normal seed still inherits most of `/bin`, `/sbin`, `/usr`, `/lib*`, and
  base `/etc` from Buildroot rather than from a guest-native package closure
- persistent payload cutovers such as `sloppkg` and Dropbear still rely on the
  current boot-glue handoff model and need an explicit atomic replacement story
  before they become outputs of a larger guest-native image build pipeline

## Runtime linker model

The current runtime ABI contract is intentionally simple:

- managed root-owned libraries still install under `/usr/local/lib` and `/usr/local/lib64`
- the guest dynamic linker still searches `/usr/lib64`, not `/usr/local/lib`
- `board/normal-rootfs-tree/etc/init.d/S15local-lib-links` bridges that gap by mirroring shared-library names from `/usr/local/lib*` into `/usr/lib64`

This is now treated as a **current contract**, not an accidental workaround.

That means:

- packages should continue to install root-owned shared libraries under `/usr/local` unless the ownership boundary is intentionally changed later
- boot must run `S15local-lib-links` before managed binaries that depend on `/usr/local` shared libraries are expected to work
- successful `sloppkg install --root /`, `sloppkg upgrade --root /`, and `sloppkg remove --root /` runs now rerun `S14persistent-dropbear`, `S15local-lib-links`, `S16persistent-sloppkg`, `S17persistent-getty`, `S19persistent-sh`, and `S20managed-userland-links` automatically so the live runtime handoffs and stale legacy-link cleanup are refreshed immediately, not only after reboot

The `S15` script also clears stale `/usr/lib64` symlinks that previously pointed at `/usr/local/lib*` before rebuilding the live view. That keeps removed or renamed managed libraries from leaving dead loader entries behind.

## Recommended mental model

Treat the project like this:

- Buildroot defines the seed image and recovery path
- `slopos-root.img` is the reseedable long-lived VM root filesystem
- `slopos-data.img` is the durable state disk that survives root resets
- the overlay scripts are the glue that reconnects persistent components at boot
- `sloppkg` is the authority for the managed world, currently rooted in `/usr/local` plus persistent payloads on the data disk

That model is the foundation for the next layer of work, such as a source-based package manager or other persistent guest tooling.
