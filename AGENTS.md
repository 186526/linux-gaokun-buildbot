# linux-gaokun-buildbot

## Project Overview

This repository builds Linux kernel packages and installable images for the Huawei MateBook E Go 2023 (`gaokun3`), based on Qualcomm Snapdragon 8cx Gen 3 (`SC8280XP`). It does not contain a complete Linux kernel tree. It contains the device-specific patch series, kernel configuration, device-tree and driver source mirrors, firmware, image-build scripts, package templates, and helper tools that are applied to an external Linux kernel checkout.

The supported image boot path uses `systemd-boot`, `kernel-install`, and Boot Loader Specification (BLS) entries. The standard kernel can be accompanied by an optional EL2 kernel variant with `CONFIG_LOCALVERSION` set to `-gaokun3-el2` and additional EL2 EFI payloads.

The repository has no `package.json`, `pyproject.toml`, `Cargo.toml`, Go module, Makefile, or project-local unit-test suite. The implementation is primarily Bash, Linux kernel C/DTS source, Debian control templates, RPM spec templates, Python utilities, systemd units, and GitHub Actions workflows.

## Repository Layout

- `patches/upstream/`: patches intended for the mainline Linux base.
- `patches/others/`: additional device, display, touchscreen, Bluetooth, clock, SPI, and EC changes.
- `patches/media/`: SC8280XP Qualcomm Venus media support patches.
- `patches/el2/`: optional EL2 boot and remoteproc/rpmsg/QRTR/SCM/SHM patches.
- `patches/xanmod/`: base-local overrides used when `KERNEL_BASE=xanmod`.
- `patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch`: imports the repository's local DTS and defconfig into the kernel tree.
- `defconfig/gaokun3_defconfig`: local arm64 kernel configuration imported by the patch series.
- `drivers/gaokun-ec/`: Huawei Gaokun EC, battery, and UCSI driver sources.
- `drivers/panel-hx83121a/`: Himax HX83121A display-panel support sources.
- `drivers/touchscreen-hx83121a/`: Himax HX83121A SPI touchscreen driver and tuning algorithm sources.
- `dts/`: Gaokun3 device-tree sources, including the camera include file.
- `firmware/`: the minimal firmware bundle copied into image roots and firmware packages.
- `packaging/deb/`: Debian package staging templates and maintainer scripts for kernel image, modules, headers, and firmware packages.
- `packaging/rpm/`: RPM spec templates for kernel, modules, devel, and firmware packages.
- `scripts/ci/lib/select_base.sh`: resolves `mainline` or `xanmod` kernel bases and selects base-specific patch overrides.
- `scripts/ci/lib/common_image.sh`: installs shared device assets and optional EL2 EFI payloads into an image root.
- `scripts/ci/20_build_kernel_variants.sh`: applies patches, builds the standard kernel, snapshots its source tree, and optionally builds the EL2 variant.
- `scripts/ci/50_make_image_{debian,fedora,ubuntu}.sh`: creates a GPT disk image, partitions and formats it, copies the root filesystem, installs assets, and configures `systemd-boot`/BLS inside a chroot.
- `scripts/ci/60_package_release_{debian,fedora,ubuntu}.sh`: compresses image artifacts, optionally splits compressed files larger than 2 GiB, and writes release metadata files.
- `scripts/ci/70_build_package_debs.sh`: builds arm64 DEB packages and `package-manifest.json`.
- `scripts/ci/70_build_package_rpms.sh`: builds RPM packages and `package-manifest.json`, normally inside the Fedora container used by CI.
- `scripts/local/build_kernel.sh`: interactive local kernel build/install helper for Ubuntu or Fedora hosts.
- `tools/audio/`: ALSA UCM configuration.
- `tools/bluetooth/`: Bluetooth NVM BDADDR patcher and service.
- `tools/monitors/`: GDM monitor synchronization script and service.
- `tools/touchscreen-tuner/`: touchscreen tuning utility, GTK desktop entry, and icon.
- `tools/el2/`: EL2 EFI payloads and implementation notes.
- `docs/`: English and Chinese build guides, dual-boot instructions, EL2 notes, and platform references.
- `.github/workflows/`: manually dispatched image-release and package-release workflows.

## Build Architecture

The build is a staged shell pipeline:

1. A workflow selects a kernel tag, `mainline` or `xanmod` base, distribution release, rootfs package set, and optional EL2 build.
2. The package workflow clones the selected Linux source at `KERNEL_TAG` and installs kernel-build tools on an `ubuntu-24.04-arm` runner.
3. `scripts/ci/20_build_kernel_variants.sh` applies `upstream`, `others`, `media`, and `0099` patches. It skips a patch when `git apply --reverse --check` shows that the patch is already present. With `BUILD_EL2=true`, it applies the EL2 series to the source tree, commits the temporary change as `Apply EL2 patches`, and builds a second output directory with `-gaokun3-el2`.
4. The kernel build uses `make ... gaokun3_defconfig`, `olddefconfig`, a parallel default build using `-j$(nproc)`, and `modules_prepare`. Outputs are out-of-tree builds under `KERN_OUT` and, when enabled, `KERN_OUT_EL2`.
5. The DEB or RPM package script stages the kernel image, `System.map`, `.config`, DTB, modules, development tree, and firmware. It emits package files, `package-manifest.json`, and `package-release-body.md` under `ARTIFACT_DIR`.
6. Image workflows either rebuild those packages or locate an existing package release by a tag prefix, verify the manifest's kernel tag and EL2 state, and download the package assets.
7. The image workflow bootstraps an arm64 rootfs for Debian, Ubuntu, or Fedora, installs the selected desktop and extra packages, installs the Gaokun packages, and invokes the matching `50_make_image_*.sh` script.
8. The image script creates a 12 GiB default GPT image with a 1024 MiB EFI partition. Debian and Fedora use Btrfs subvolumes `@`, `@home`, and `@var`; Ubuntu uses ext4. It configures firmware hooks, initramfs/dracut, `/etc/kernel/cmdline`, `/etc/kernel/devicetree`, `bootctl`, and `kernel-install` BLS entries.
9. The matching `60_package_release_*.sh` script creates a `.zst` image or numbered `.zst.part-*` files when the compressed image reaches the 2 GiB split threshold, then the workflow uploads artifacts and publishes a GitHub Release.

The package and image workflows run on `ubuntu-24.04-arm`. RPM package assembly runs in a `fedora:44` Docker container. Image creation requires loop devices, partitioning and filesystem tools, mounts, `chroot`, and `sudo`.

## Local Kernel Build

The supported local helper is `scripts/local/build_kernel.sh`. It is interactive and supports only hosts whose `/etc/os-release` reports `ubuntu` or `fedora`. It defaults to:

```bash
KERNEL_TAG=v7.2-rc2
KERNEL_BASE=mainline
GAOKUN_DIR=$HOME/gaokun/linux-gaokun-buildbot
KERN_SRC=$HOME/gaokun/mainline-linux
KERN_OUT=$HOME/gaokun/kernel-out
KERN_OUT_EL2=$HOME/gaokun/kernel-out-el2
```

Run it from a prepared checkout with:

```bash
chmod +x scripts/local/build_kernel.sh
scripts/local/build_kernel.sh
```

The helper can install the minimal Ubuntu or Fedora kernel toolchain, chooses `aarch64-linux-gnu-` automatically on non-arm64 hosts, asks whether to build the standard kernel, the EL2 kernel, or both, applies the repository patches, builds with an out-of-tree output directory, and optionally installs the kernel and DTB. Installation modifies `/boot`, `/lib/modules`, `/etc/kernel`, initramfs state, and BLS entries and therefore requires `sudo`.

For reproducible non-interactive CI-style stages, provide the variables required by the relevant script. The kernel-variant script requires `GAOKUN_DIR`, `WORKDIR`, and `KERN_SRC`; package scripts additionally require `ARTIFACT_DIR`, `KERNEL_TAG`, and `PACKAGE_RELEASE_TAG`. `BUILD_EL2=true` requires the EL2 output and source paths used by the workflow.

## Workflows and Release Process

The package workflows are manually dispatchable and reusable through `workflow_call`:

- `.github/workflows/gaokun3-package-debs.yml` builds arm64 kernel image, modules, headers, and firmware DEBs.
- `.github/workflows/gaokun3-package-rpms.yml` builds `kernel-gaokun3`, `kernel-modules-gaokun3`, `kernel-devel-gaokun3`, and `linux-firmware-gaokun3` RPMs.

The image workflows are manually dispatchable:

- `ubuntu-gaokun3-release.yml` creates an Ubuntu ext4 image.
- `debian-gaokun3-release.yml` creates a Debian Btrfs image.
- `fedora-gaokun3-release.yml` creates a Fedora Btrfs image.

Each image workflow accepts a distribution release, kernel tag, kernel base, desktop package selection, extra packages, and `build_el2`. It can either rebuild package artifacts first or resolve an existing package release. Successful runs upload workflow artifacts and publish a GitHub Release. Release workflows need `contents: write` and use the GitHub token for release lookup and asset download.

Package release tags encode the package type, sanitized kernel tag, optional `-xanmod`, standard/EL2 profile, and a UTC timestamp. Image release tags encode the distribution release, kernel release, optional `-el2`, and a UTC timestamp.

## Runtime and Boot Details

The image scripts install the standard kernel and, when requested, the EL2 kernel side by side. `kernel-install` generates BLS entries using the machine ID and kernel release. The scripts keep a DTB compatibility copy under `/boot`; Ubuntu also uses `/usr/lib/linux-image-<kernel-release>/qcom/`, while Fedora uses `/usr/lib/modules/<kernel-release>/dtb/qcom/` for `kernel-install` lookup.

The shared image assets install device-specific systemd services, the Bluetooth address patcher, monitor synchronization, ALSA UCM data, and touchscreen tuner files. EL2 images additionally install `slbounceaa64.efi`, `qebspilaa64.efi`, `tcblaunch.exe`, and selected DSP/GPU firmware under the EFI system partition.

The image scripts currently create a default `user` account with password `user` and passwordless sudo/wheel access inside generated images. Treat generated images as development artifacts and change credentials before production use.

## Validation and Testing

There is no repository test runner or automated unit/integration test suite. Before changing shell scripts, run syntax checks over all shell sources:

```bash
find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

For workflow or packaging changes, inspect required-variable contracts and validate generated shell/YAML syntax with the tools available on the host. The authoritative end-to-end validation is the corresponding GitHub Actions workflow because image and package builds require an arm64 runner, an external Linux kernel checkout, distribution rootfs repositories, package builders, containers, and privileged filesystem operations.

Do not claim an image or package build succeeded from a syntax check alone. A full validation must produce the expected package files or compressed image artifacts and, for package builds, a manifest whose kernel tag and `build_el2` value match the requested inputs.

## Development Conventions

- Shell scripts use Bash with `set -euo pipefail`, quote paths, require mandatory environment variables with `: "${VAR:?message}"`, and use out-of-tree kernel builds.
- Preserve the existing staged script order and environment-variable contracts when changing the pipeline.
- Keep patch order and patch filenames stable. Mainline and XanMod overrides are selected by matching the same patch basename under `patches/xanmod/`.
- Kernel and DTS files follow the repository's `.editorconfig`: tabs for `*.c`, `*.h`, `*.dts`, and `*.dtsi`; spaces and two-space indentation for shell, YAML, Markdown, and Python.
- Use LF line endings, UTF-8, a final newline, and no trailing whitespace.
- Use comments for non-obvious kernel/image behavior, especially boot ordering, firmware placement, or base-tree compatibility. Keep comments synchronized with behavior.
- Keep generated build trees and artifacts outside tracked source paths where possible. The CI workflows use `build-*` directories and package manifests under their workspaces.
- Delegate small kernel patch-generation tasks with a narrow, fixed workflow: assign one target file or patch, use a detached temporary worktree, fetch only missing Git objects, make the source change, run `git commit` and `git format-patch`, verify with `git apply --check` or `git apply --reverse --check`, and remove the worktree.
- Do not ask a subagent handling a small patch to clone or fully check out the kernel, replay unrelated patch series, run a full build, perform broad repository searches, edit patch text directly, modify the main kernel worktree, or touch files outside its assigned scope. The subagent must return the target path, temporary commit ID, fetch status, and verification result promptly.

## Security and Operational Constraints

Image creation and local installation execute `sudo`, mount filesystems, create loop devices, enter chroots, write boot files, and can modify the host's `/boot`, `/etc/kernel`, initramfs, and module directories. Review `IMAGE_FILE`, `ROOTFS_DIR`, `WORKDIR`, and mount paths before running image scripts.

The workflows grant `contents: write` because they publish GitHub Releases. Do not broaden permissions or print tokens. Keep package and release downloads tied to the expected manifest, kernel tag, and EL2 state; the existing workflows reject mismatches before installing downloaded package artifacts.

Firmware and binary EFI payloads are checked into the repository under `firmware/` and `tools/el2/`. Preserve their expected destination paths when changing packaging or image assembly, because initramfs hooks, dracut configuration, and EL2 boot entries depend on those paths.

## Further Documentation

Use the English and Chinese documents under `docs/` for device installation, dual boot, EL2 implementation, Fedora 44 manual builds, and Ubuntu 26.04 manual builds. `README.md` is the concise source of truth for repository contents, package outputs, boot artifact layout, patch sources, and external references.
