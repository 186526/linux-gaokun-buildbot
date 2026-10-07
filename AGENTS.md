# linux-gaokun-buildbot

## Project Overview

This repository builds Linux kernel packages and installable images for the Huawei MateBook E Go 2023 (`gaokun3`), based on Qualcomm Snapdragon 8cx Gen 3 (`SC8280XP`). It does not contain a complete Linux kernel tree. It contains the device-specific patch series, kernel configuration, device-tree mirror, firmware, image-build scripts, package templates, and helper tools that are applied to an external, pinned Linux kernel checkout.

The kernel input is pinned in `build.env`:

```bash
KERNEL_REPOSITORY=gaokun3/linux
KERNEL_TAG=gaokun3
KERNEL_COMMIT=73033564068250603f5b2150c408554faaf22d66
KERNEL_EL2_COMMIT=
```

`scripts/lib/kernel_source.sh:prepare_kernel_source` clones exactly that commit (`git fetch --depth=1`, detached) and refuses to continue when the checkout is at a different commit or contains local edits or untracked files. The pinned Gaokun3 tree already contains device drivers, DTS files, and `gaokun3_defconfig`; build scripts do not replay the legacy device patch series on it. `KERNEL_BASE=xanmod` instead fetches XanMod at `KERNEL_XANMOD_TAG` (default `7.2.9-xanmod1`) and applies repository patches with the XanMod overrides.

The supported image boot path uses `systemd-boot`, `kernel-install`, and Boot Loader Specification (BLS) entries. The standard kernel can be accompanied by an optional EL2 kernel variant with `CONFIG_LOCALVERSION` set to `-gaokun3-el2` and additional EL2 EFI payloads. EL2 is patch-based: `BUILD_EL2=true` applies `patches/el2` and does not require `KERNEL_EL2_COMMIT`.

The repository has no `package.json`, `pyproject.toml`, `Cargo.toml`, Go module, or Makefile. It does have a small Python unit-test suite under `tests/`. The implementation is primarily Bash, Linux kernel C/DTS source, Debian control templates, RPM spec templates, Python utilities, systemd units, and GitHub Actions workflows.

## Repository Layout

- `build.sh`: local build entry point (`./build.sh kernel|debs|rpms`); sources `build.env` and `scripts/lib/kernel_source.sh`, prepares the pinned source tree, then runs the kernel-variant and package scripts.
- `build.env`: reviewed, pinned build inputs (kernel repository, tag, commit, EL2 commit, distro releases). Change it in a commit together with adaptation notes.
- `patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch`: imports local DTS and defconfig files into XanMod; the pinned `gaokun3/linux` tree already contains these files.
- `patches/upstream/`: Gaokun3 UCSI, EC, ADSP, and HI846 changes applied to XanMod.
- `patches/others/`: display clock, SPI GSI, fbdev, DSC interface width, and panel fixes applied to XanMod.
- `patches/media/`: SC8280XP Qualcomm Venus support patches applied to XanMod.
- `patches/el2/`: optional EL2 boot and remoteproc/SCM patches; XanMod-specific replacements are under `patches/xanmod/el2/`.
- `patches/kernelsu/PINNED_REVISION.md`: records the pinned upstream KernelSU revision. KernelSU is not vendored.
- `patches/xanmod/`: base-local overrides used when `KERNEL_BASE=xanmod`. A file with the same basename replaces the shared patch; extra files exist only for XanMod.
- `defconfig/gaokun3_defconfig`: arm64 kernel configuration mirror. It must match the `gaokun3_defconfig` embedded in `patches/0099`; the patch, not this directory, is what the build applies.
- `dts/`: Gaokun3 device-tree mirror (`sc8280xp-huawei-gaokun3.dts` and the camera include `sc8280xp-huawei-gaokun3-camera.dtsi` it includes). It must match the DTS files embedded in `patches/0099`.
- `firmware/`: the minimal firmware bundle copied into image roots and firmware packages.
- `packaging/deb/`: Debian package staging templates and maintainer scripts for kernel image, modules, headers, and firmware packages.
- `packaging/rpm/`: RPM spec templates for kernel, modules, devel, and firmware packages.
- `scripts/ci/lib/select_base.sh`: resolves `mainline` or `xanmod` kernel bases and selects base-specific patch overrides.
- `scripts/ci/lib/kernelsu.sh`: opt-in pinned KernelSU integration and assertions.
- `scripts/ci/lib/common_image.sh`: installs shared device assets and optional EL2 EFI payloads into an image root.
- `scripts/ci/20_build_kernel_variants.sh`: applies the patch series to the pinned tree, builds the standard kernel, snapshots its source tree, and optionally builds the EL2 variant.
- `scripts/ci/30_bootstrap_rootfs.sh`: bootstraps a Debian, Ubuntu, or Fedora arm64 rootfs.
- `scripts/ci/50_make_image_{debian,fedora,ubuntu}.sh`: creates a GPT disk image, partitions and formats it, copies the root filesystem, installs assets, and configures `systemd-boot`/BLS inside a chroot.
- `scripts/ci/60_package_release_{debian,fedora,ubuntu}.sh`: compresses image artifacts, optionally splits compressed files larger than 2 GiB, and writes release metadata files.
- `scripts/ci/70_build_package_debs.sh`: builds arm64 DEB packages and `package-manifest.json`.
- `scripts/ci/70_build_package_rpms.sh`: builds RPM packages and `package-manifest.json`, normally inside the Fedora container used by CI.
- `scripts/lib/kernel_source.sh`: pinned-source preparation and dirty/mismatch guards.
- `scripts/local/build_kernel.sh`: legacy interactive local kernel build/install helper for Ubuntu or Fedora hosts (clones mainline and applies the same patch series; not the pinned `build.sh` flow).
- `tests/`: Python unit tests for the source-preparation guards and for systemd's entry-token/BLS behavior.
- `tools/audio/`: ALSA UCM configuration.
- `tools/bluetooth/`: Bluetooth NVM BDADDR patcher and service.
- `tools/el2/`: EL2 EFI payloads and implementation notes.
- `tools/image-assets/`: modules-load, modprobe, and monitor configuration installed into image roots.
- `tools/touchscreen-tuner/`: touchscreen tuning utility, GTK desktop entry, and icon.
- `docs/`: English and Chinese build guides, dual-boot instructions, EL2 notes, and platform references.
- `.github/workflows/`: manually dispatched image-release and package-release workflows plus the `checks.yml` validation workflow.

Note: `drivers/` and `tools/monitors/` no longer exist; the EC, panel, and touchscreen driver sources are maintained in the pinned kernel tree, and monitor configuration lives under `tools/image-assets/`.

## Build Architecture

The build is a staged shell pipeline:

1. `./build.sh <action>` sources `build.env`, prepares the pinned kernel checkout, and exports the environment consumed by the CI scripts.
2. `scripts/ci/20_build_kernel_variants.sh` builds pinned `gaokun3/linux` directly because that tree already contains device drivers, DTS files, and `gaokun3_defconfig`. With `KERNEL_BASE=xanmod`, it applies `patches/upstream`, `patches/others`, `patches/media`, and `patches/0099`; same-name files under `patches/xanmod/` replace shared patches. Known XanMod changes are skipped only when their target file contains all defined fixed-string anchors. With `BUILD_KERNELSU=true`, the pinned KernelSU revision is wired into the tree before configuration. With `BUILD_EL2=true`, it snapshots the prepared source, applies the EL2 series to that separate tree, commits the temporary change as `Apply EL2 patches`, and builds a second output directory with `-gaokun3-el2`; `KERNEL_EL2_COMMIT` is unused for the patch-based EL2 variant.
3. The kernel build uses `make ... gaokun3_defconfig`, `olddefconfig`, a parallel default build using `-j$(nproc)`, and `modules_prepare`. Outputs are out-of-tree builds under `KERN_OUT` and, when enabled, `KERN_OUT_EL2`.
4. The DEB or RPM package script stages the kernel image, `System.map`, `.config`, DTB, modules, development tree, and firmware. It emits package files, `package-manifest.json`, and `package-release-body.md` under `ARTIFACT_DIR`.
5. Image workflows either rebuild those packages or locate an existing package release by a tag prefix, verify the manifest's kernel tag/commit and EL2 state, and download the package assets.
6. The image workflow bootstraps an arm64 rootfs for Debian, Ubuntu, or Fedora, installs the selected desktop and extra packages, installs the Gaokun packages, and invokes the matching `50_make_image_*.sh` script.
7. The image script creates a GPT image with a 1 GiB EFI partition (`EFI_END_MIB=1025`) and a single root partition. Debian uses Btrfs subvolumes `@`, `@home`, and `@var`; Ubuntu and Fedora use ext4. It configures firmware hooks, initramfs/dracut, `/etc/kernel/cmdline`, `/etc/kernel/devicetree`, `bootctl`, and `kernel-install` BLS entries.
8. The matching `60_package_release_*.sh` script creates a `.zst` image or numbered `.zst.part-*` files when the compressed image reaches the 2 GiB split threshold, then the workflow uploads artifacts and publishes a GitHub Release.

The package and image workflows run on `ubuntu-24.04-arm`. RPM package assembly runs in a `fedora:44` Docker container. Image creation requires loop devices, partitioning and filesystem tools, mounts, `chroot`, and `sudo`.

## Local Kernel Build

The pinned entry point is `build.sh`:

```bash
./build.sh kernel   # build the standard kernel (and EL2 if configured)
./build.sh debs     # build the kernel and arm64 DEB packages
./build.sh rpms     # build the kernel and RPM packages
```

Inputs come from `build.env`. `WORKDIR` selects the output directory (default `./build`); for the default base, `KERN_SRC` must match the pinned commit exactly and be clean. With `KERNEL_BASE=xanmod`, `build.sh` fetches `KERNEL_XANMOD_TAG` (default `7.2.9-xanmod1`) and refuses to overwrite an existing source directory. `KERN_SRC_EL2`, `KERN_OUT`, and `KERN_OUT_EL2` override the EL2 and output paths. `BUILD_EL2=true` uses the reviewed patch series and does not require `KERNEL_EL2_COMMIT`. `BUILD_KERNELSU=true` wires the pinned KernelSU revision into the tree.

The legacy interactive helper `scripts/local/build_kernel.sh` still exists for on-device Ubuntu or Fedora hosts. It defaults to:

```bash
KERNEL_TAG=v7.2-rc2
KERNEL_BASE=mainline
GAOKUN_DIR=$HOME/gaokun/linux-gaokun-buildbot
KERN_SRC=$HOME/gaokun/mainline-linux
KERN_OUT=$HOME/gaokun/kernel-out
KERN_OUT_EL2=$HOME/gaokun/kernel-out-el2
```

It installs the minimal toolchain, chooses `aarch64-linux-gnu-` on non-arm64 hosts, asks whether to build the standard kernel, the EL2 kernel, or both, applies the same repository patch series, and optionally installs the kernel and DTB. Installation modifies `/boot`, `/lib/modules`, `/etc/kernel`, initramfs state, and BLS entries and therefore requires `sudo`. Prefer `build.sh` for a reproducible, pinned build.

For reproducible non-interactive CI-style stages, provide the variables required by the relevant script. The kernel-variant script requires `GAOKUN_DIR`, `WORKDIR`, and `KERN_SRC`; the package scripts additionally require `ARTIFACT_DIR`, `KERNEL_TAG`, `KERNEL_COMMIT`, and `PACKAGE_RELEASE_TAG`; `BUILD_EL2=true` requires the EL2 output and source paths used by the workflow.

## Workflows and Release Process

The package workflows are manually dispatchable and reusable through `workflow_call`:

- `.github/workflows/gaokun3-package-debs.yml` builds arm64 kernel image, modules, headers, and firmware DEBs.
- `.github/workflows/gaokun3-package-rpms.yml` builds `kernel-gaokun3`, `kernel-modules-gaokun3`, `kernel-devel-gaokun3`, and `linux-firmware-gaokun3` RPMs.

The image workflows are manually dispatchable:

- `ubuntu-gaokun3-release.yml` creates an Ubuntu ext4 image.
- `debian-gaokun3-release.yml` creates a Debian Btrfs image.
- `fedora-gaokun3-release.yml` creates a Fedora ext4 image.

Each image workflow accepts a distribution release, kernel tag, kernel base, desktop package selection, extra packages, and `build_el2`. It can either rebuild package artifacts first or resolve an existing package release. Successful runs upload workflow artifacts and publish a GitHub Release. Release workflows need `contents: write` and use the GitHub token for release lookup and asset download.

Release and asset operations target `${GITHUB_REPOSITORY}` — the repository the workflow runs in — rather than a hard-coded slug. In this checkout that is the `origin` remote (`186526/linux-gaokun-buildbot`); `upstream` points at `KawaiiHachimi/linux-gaokun-buildbot` and a `gaokun3` remote points at `gaokun3/build.git`.

Package release tags encode the package type, sanitized kernel tag, optional `-xanmod`, standard/EL2 profile, and a UTC timestamp. Image release tags encode the distribution release, kernel release, optional `-el2`, and a UTC timestamp.

## Runtime and Boot Details

The image scripts install the standard kernel and, when requested, the EL2 kernel side by side. `kernel-install` generates BLS entries. Fedora and Ubuntu use an `os-id` entry token (`fedora`/`ubuntu`) and record it in `/etc/kernel/entry-token`; Debian uses a `machine-id` entry token. `loader.conf` default entries follow the same token (`fedora-<krel>.conf`, `ubuntu-<krel>.conf`, or `<machine-id>-<krel>.conf`).

The scripts keep a DTB compatibility copy under `/boot`; Ubuntu also uses `/usr/lib/linux-image-<kernel-release>/qcom/`, while Fedora uses `/usr/lib/modules/<kernel-release>/dtb/qcom/` for `kernel-install` lookup.

The shared image assets install device-specific systemd services, the Bluetooth address patcher, ALSA UCM data, monitor configuration, and touchscreen tuner files. EL2 images additionally install `slbounceaa64.efi`, `qebspilaa64.efi`, `tcblaunch.exe`, and selected DSP/GPU firmware under the EFI system partition.

Account behavior differs by distribution. Ubuntu and Debian create a `user` account with password `user` and passwordless `sudo` access. Fedora creates no account; GDM runs `gnome-initial-setup` on first boot. Treat generated images as development artifacts and change credentials before production use.

## Validation and Testing

`tests/` contains Python unit tests. `tests/test_kernel_source.py` checks that source preparation never overwrites a mismatched or dirty tree. `tests/test_boot_entries.py` exercises systemd's entry-token resolution and the `90-loaderentry.install` BLS plugin and requires systemd with `kernel-install` installed. Run them with:

```bash
python3 -m unittest discover -s tests -v
```

The `checks.yml` workflow runs on `ubuntu-24.04` for pull requests and pushes to `main`/`next`. It checks shell syntax over `build.sh`, `build.env`, and every `scripts/**/*.sh`; runs `shellcheck -S warning` on `build.sh`, `scripts/lib/kernel_source.sh`, `scripts/ci/20_build_kernel_variants.sh`, and `scripts/local/build_kernel.sh`; then runs the unit tests.

Before changing shell scripts, run syntax checks locally:

```bash
bash -n build.sh build.env
find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

For workflow or packaging changes, inspect required-variable contracts and validate generated shell/YAML syntax with the tools available on the host. The authoritative end-to-end validation is the corresponding GitHub Actions workflow because image and package builds require an arm64 runner, an external Linux kernel checkout, distribution rootfs repositories, package builders, containers, and privileged filesystem operations.

Do not claim an image or package build succeeded from a syntax check alone. A full validation must produce the expected package files or compressed image artifacts and, for package builds, a manifest whose kernel tag, kernel commit, and `build_el2` value match the requested inputs.

## Development Conventions

- Shell scripts use Bash with `set -euo pipefail`, quote paths, require mandatory environment variables with `: "${VAR:?message}"`, and use out-of-tree kernel builds.
- Preserve the existing staged script order and environment-variable contracts when changing the pipeline.
- Keep patch order and patch filenames stable. Mainline and XanMod overrides are selected by matching the same patch basename under `patches/xanmod/`.
- `defconfig/gaokun3_defconfig` and the DTS files under `dts/` are mirrors of the files embedded in `patches/0099`. Keep them byte-identical to the patch content so the patch remains the authoritative, reviewable source; the build itself does not read these directories.
- Kernel and DTS files follow the repository's `.editorconfig`: tabs for `*.c`, `*.h`, `*.dts`, and `*.dtsi`; spaces and two-space indentation for shell, YAML, Markdown, and Python.
- Use LF line endings, UTF-8, a final newline, and no trailing whitespace.
- Use comments for non-obvious kernel/image behavior, especially boot ordering, firmware placement, or base-tree compatibility. Keep comments synchronized with behavior.
- Keep generated build trees and artifacts outside tracked source paths where possible. The CI workflows use `build-*` directories and package manifests under their workspaces.
- Delegate small kernel patch-generation tasks with a narrow, fixed workflow: assign one target file or patch, use a detached temporary worktree, fetch only missing Git objects, make the source change, run `git commit` and `git format-patch`, verify with `git apply --check` or `git apply --reverse --check`, and remove the worktree.
- Do not ask a subagent handling a small patch to clone or fully check out the kernel, replay unrelated patch series, run a full build, perform broad repository searches, edit patch text directly, modify the main kernel worktree, or touch files outside its assigned scope. The subagent must return the target path, temporary commit ID, fetch status, and verification result promptly.

## Security and Operational Constraints

Image creation and local installation execute `sudo`, mount filesystems, create loop devices, enter chroots, write boot files, and can modify the host's `/boot`, `/etc/kernel`, initramfs, and module directories. Review `IMAGE_FILE`, `ROOTFS_DIR`, `WORKDIR`, and mount paths before running image scripts.

The workflows grant `contents: write` because they publish GitHub Releases. Do not broaden permissions or print tokens. Keep package and release downloads tied to the expected manifest, kernel tag/commit, and EL2 state; the existing workflows reject mismatches before installing downloaded package artifacts.

Firmware and binary EFI payloads are checked into the repository under `firmware/` and `tools/el2/`. Preserve their expected destination paths when changing packaging or image assembly, because initramfs hooks, dracut configuration, and EL2 boot entries depend on those paths.

## Further Documentation

Use the English and Chinese documents under `docs/` for device installation, dual boot, EL2 implementation, Fedora 44 manual builds, and Ubuntu 26.04 manual builds. The Fedora 44 and Ubuntu 26.04 guides are historical: their patch paths and clone steps describe the pre-migration tree. `README.md` is the concise source of truth for repository contents, package outputs, boot artifact layout, patch sources, and external references; `docs/migration.md` records the pinned-kernel migration and its current blockers.
