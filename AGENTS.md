# linux-gaokun-buildbot

## Project Overview

This repository builds ARM64 Linux kernel packages and installable disk images for the Huawei MateBook E Go 2023 (`gaokun3`, Qualcomm Snapdragon 8cx Gen 3 / `SC8280XP`). It is a build and packaging repository, not a complete Linux kernel checkout. The kernel, including device enablement, lives in the XanMod fork `186526/linux-xanmod-gaokun3` on GitLab, which carries the device work as commits on the `gaokun3` and `gaokun3-el2` branches.

The implementation uses Bash, GitHub Actions YAML, Debian package templates, RPM specs, Python utilities, systemd services, ALSA UCM, and WirePlumber configuration. The touchscreen tuner uses PyGObject with GTK 4 and libadwaita. There is no `package.json`, `pyproject.toml`, `Cargo.toml`, Go module, or repository Makefile; kernel `make` commands run in an external kernel tree. Python tests use standard-library `unittest`.

## Configuration and Source Boundaries

- `build.env` is the reviewed source input for local and CI builds. It names `KERNEL_REPOSITORY=186526/linux-xanmod-gaokun3`, the ref `KERNEL_TAG=gaokun3`, the EL2 ref `KERNEL_EL2_REF=gaokun3-el2`, and optional exact commit pins `KERNEL_COMMIT`/`KERNEL_EL2_COMMIT` (empty means follow the branch tip); Fedora and Ubuntu releases are 44 and 26.04. Change reviewed inputs with adaptation notes.
- `KERNEL_TAG` is both the ref fetched from `KERNEL_REPOSITORY` and the naming label the packages carry. `KERNEL_EL2_COMMIT` is read by the image workflows under `set -u`, so keep the field defined even when empty.
- `scripts/ci/lib/kernel_tree.sh:fetch_kernel_tree` fetches the ref with `--depth=1` into a detached checkout and refuses a directory with local edits, a ref that resolves to a different commit than the pin, or a missing `.git`. `read_kernel_manifest` reads `gaokun3-manifest.json` from the tree root and exports `KERNEL_RELEASE`, `KERNEL_RELEASE_EL2`, `KERNEL_DEFCONFIG`, `KERNEL_DTB`, and `KERNEL_DTB_EL2`; `assert_kernel_output` refuses a build output whose `kernel.release` or DTB does not match the manifest.
- The kernel tree owns the device file names. Do not reintroduce hardcoded `gaokun3_defconfig`, DTB names, or release strings in this repository; read them from the manifest.
- `.editorconfig` defines formatting. `.github/workflows/` defines runner dependencies, workflow inputs, release behavior, and CI checks; package templates under `packaging/` define installed-file and upgrade contracts.

## Repository Organization

- `build.sh`: local `kernel`, `debs`, and `rpms` entry point; loads reviewed inputs, resolves or fetches the kernel checkout, reads the manifest, exports stage variables, and invokes the build/package scripts.
- `scripts/ci/20_build_kernel.sh`: optionally integrates KernelSU, then configures and builds the standard variant and, when `BUILD_EL2=true`, fetches `KERNEL_EL2_REF` into its own checkout and builds the EL2 variant. It records nothing outside the kernel output directories.
- `scripts/ci/lib/kernel_tree.sh`: kernel fetch, manifest reader, and build-output assertion.
- `scripts/ci/lib/package_manifest.sh`: `read_package_releases` reads `KERNEL_RELEASE`/`KERNEL_RELEASE_EL2` from `package-manifest.json` for the image and release stages.
- `scripts/ci/lib/toolchain.sh`: shared GCC/Clang, link-time optimization, CPU tuning, compiler probes, and generated-config checks. Kernel and package scripts share its `KERNEL_MAKE_ARGS` array.
- `scripts/ci/lib/kernelsu.sh`: opt-in pinned KernelSU cloning, integration, and configuration checks; the pin is documented in `packaging/kernelsu/PINNED_REVISION.md` and source transformations live in `packaging/kernelsu/*.patch`.
- `scripts/ci/70_build_package_{debs,rpms}.sh`: stage kernels, modules, development trees, and firmware; render `packaging/` templates; emit packages, `package-manifest.json`, and `package-release-body.md` into `ARTIFACT_DIR`.
- `scripts/ci/30_bootstrap_rootfs.sh`: Fedora rootfs bootstrap through privileged Fedora Docker and `dnf --installroot`. Debian bootstrap (`debootstrap`) and Ubuntu bootstrap (downloaded `ubuntu-base` tarball) remain in their workflows.
- `scripts/ci/50_make_image_{debian,fedora,ubuntu}.sh`: disk partitioning, filesystem setup, rootfs copying, initramfs and boot configuration. `scripts/ci/lib/common_image.sh` installs shared device assets and optional EL2 EFI payloads.
- `scripts/ci/60_package_release_{debian,fedora,ubuntu}.sh`: compress images with zstd, split compressed files at the 2 GiB threshold, and generate release metadata.
- `firmware/`: device firmware packaged and copied into images. `tools/el2/`: binary EFI payloads and implementation notes.
- `tools/audio/`, `tools/bluetooth/`, `tools/image-assets/`, `tools/touchscreen-tuner/`: audio configuration, Bluetooth address patcher/service, module and monitor configuration, and touchscreen GUI/launcher assets.
- `tests/`: real systemd boot-entry tests. `docs/`: English/Chinese installation guides, migration notes, kernel audit, and hardware acceptance checklist.

## Build Commands and Pipeline

Install the build tools before invoking `build.sh`; it uses the host toolchain and package builders. CI workflow dependency steps and the local helper list the concrete distro packages. Kernel builds need Git, make, GCC or Clang/LLVM, bc, bison, flex, OpenSSL/libelf development files, pahole, and related kernel tools; packaging additionally uses `dpkg-deb` or `rpmbuild`. Non-AArch64 hosts default to `CROSS_COMPILE=aarch64-linux-gnu-`.

```bash
./build.sh --help
./build.sh kernel
./build.sh debs
./build.sh rpms
KERNEL_TOOLCHAIN=clang BUILD_KERNELSU=true ./build.sh kernel
KERNEL_TAG=gaokun3-el2 BUILD_EL2=true ./build.sh kernel
```

`WORKDIR` defaults to `./build`, with `linux`, `linux-el2`, `kernel-out`, `kernel-out-el2`, and `artifacts` beneath it. `KERN_SRC`, `KERN_SRC_EL2`, `KERN_OUT`, `KERN_OUT_EL2`, and `ARTIFACT_DIR` control source, build, and artifact locations. A local run reuses `KERNEL_SRC` when set, or `~/git/linux-xanmod-gaokun3` when it exists, instead of fetching; a checkout with local changes is refused.

The kernel stage optionally integrates KernelSU, then runs the manifest's defconfig, `olddefconfig`, parallel `make -j$(nproc)`, the manifest's DTB, and `modules_prepare` with out-of-tree `O=` output. Package stages reuse the same toolchain for `modules_install`.

`BUILD_EL2=true` builds both variants from separate checkouts: the standard variant from `KERN_SRC`, the EL2 variant from `KERNEL_EL2_REF` fetched into `KERN_SRC_EL2`. The EL2 branch carries its own `CONFIG_LOCALVERSION="-gaokun3-el2"` and DTB name, so no script sets either. The two checkouts must differ; the stage refuses `KERN_SRC_EL2` equal to `KERN_SRC`.

Toolchain controls:

- `KERNEL_TOOLCHAIN=gcc` is the default and uses no LLVM arguments; `KERNEL_LTO` resolves to `none`.
- `KERNEL_TOOLCHAIN=clang` (also accepts `llvm`) selects `LLVM=1 LLVM_IAS=1 LD=ld.lld` and defaults to `KERNEL_LTO=thin`. `KERNEL_LTO=none` disables the ThinLTO configuration step; GCC rejects `thin`.
- `KERNEL_TUNE=sc8280xp` (aliases `8cx-gen3`, `8cxgen3`) adds `KCFLAGS=-march=armv8.4-a+crypto -mtune=cortex-x1c`. Other values add only `-mtune=<cpu>`. Existing `KCFLAGS` are preserved and a compiler probe rejects unsupported tuning before configuration. Unset tuning leaves the portable baseline.
- `BUILD_KERNELSU=true` clones and wires the pinned upstream revision before configuration for both requested variants; CI and local builds default to false.

Direct stage callers must satisfy each script's `: "${VAR:?message}"` guards. Kernel builds require `GAOKUN_DIR`, `WORKDIR`, and `KERN_SRC`; packaging additionally requires artifact paths, prepared source/output paths, `KERNEL_TAG`, `KERNEL_COMMIT`, and `PACKAGE_RELEASE_TAG`. Preserve these contracts when editing the pipeline.

## Packages, Images, and Runtime

DEBs provide versioned kernel image, modules, and headers packages plus shared `linux-firmware-gaokun3`. RPMs provide `kernel-gaokun3`, `kernel-modules-gaokun3`, `kernel-devel-gaokun3`, and `linux-firmware-gaokun3`. EL2 adds a second kernel package set. The manifest records source/build metadata and package filenames used by image workflows.

DEB image installation invokes `update-initramfs`; distro systemd-boot hooks refresh boot entries. RPM kernel `%posttrans` runs dracut and `kernel-install add`; the standard kernel updates the boot default, while EL2 remains an explicit boot-menu choice. Firmware packages put repository Adreno files in `firmware/updates/qcom/` so they take precedence without colliding with distro firmware paths. Preserve firmware paths and initramfs/dracut hooks together.

Images use GPT with a 1 GiB FAT EFI system partition and one root partition. Debian uses Btrfs subvolumes `@`, `@home`, and `@var`; Ubuntu and Fedora use ext4. Boot uses `systemd-boot`, `kernel-install`, and Boot Loader Specification (BLS) entries. Current image scripts persist distribution entry tokens in `/etc/kernel/entry-token`: `debian`, `ubuntu`, or `fedora`. Entries are `loader/entries/<token>-<kernel-release>.conf`, with kernel/initrd/DTB files beneath `<token>/<kernel-release>/` on the EFI partition. Older docs still describe Debian machine-ID tokens; consult the current scripts when changing boot behavior.

`/etc/kernel/cmdline` and `/etc/kernel/devicetree` drive boot-entry creation. Compatibility DTB copies remain under `/boot`; DEBs also stage DTBs under `/usr/lib/linux-image-<release>/qcom/`, and Fedora uses `/usr/lib/modules/<release>/dtb/qcom/`. Shared assets install Bluetooth service files, ALSA/WirePlumber configuration, module loading rules, portrait-panel monitor configuration, and touchscreen tuning tools. EL2 adds `slbounceaa64.efi`, `qebspilaa64.efi`, `tcblaunch.exe`, and DSP/GPU firmware on the EFI partition.

## CI and Release Process

- `checks.yml` runs on `ubuntu-24.04` for pull requests and pushes to `main`/`next`: shell syntax, selected ShellCheck files, toolchain-selection and package-tag contract checks, and Python boot-entry tests.
- `gaokun3-package-{debs,rpms}.yml` support manual dispatch and reusable `workflow_call`, run on `ubuntu-24.04-arm`, and default `publish_release` to false. Their `kernel_ref` input selects the kernel fork ref (default `gaokun3`); the EL2 variant is always fetched from `KERNEL_EL2_REF`. RPM assembly uses a Fedora container selected by `FEDORA_RELEASE`.
- `validate-packages.yml` runs manually or on build-related pushes to `next`; it calls both package workflows with release publishing disabled.
- `debian-gaokun3-release.yml`, `ubuntu-gaokun3-release.yml`, and `fedora-gaokun3-release.yml` manually assemble ARM64 images using rebuilt packages or existing package releases. Fedora can also consume package Actions artifacts by `package_run_id` and defaults to non-publishing validation; inspect each workflow's actual publish condition before running it.
- Image workflows check package manifests and select package filenames from them. Preserve tag, source-commit, EL2, and KernelSU compatibility checks on the applicable download/build paths. Release operations target `${GITHUB_REPOSITORY}` and require `contents: write`.

The image workflows no longer gate `BUILD_EL2=true` on `KERNEL_EL2_COMMIT`: the EL2 variant is a separate branch fetched from `KERNEL_EL2_REF`, and the commit pin is optional. A successful kernel build alone does not establish that every image workflow supports that profile or that the device boots it.

## Testing and Verification

Run the checks relevant to the changed scripts, then use the standard suite for integration review:

```bash
bash -n build.sh build.env
find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck -S warning build.sh scripts/ci/20_build_kernel.sh scripts/ci/lib/kernel_tree.sh scripts/ci/lib/package_manifest.sh scripts/ci/lib/toolchain.sh scripts/ci/lib/package_tag.sh scripts/ci/lib/kernelsu.sh
python3 -m unittest discover -s tests -v
```

`tests/test_boot_entries.py` exercises actual `kernel-install inspect` and `90-loaderentry.install` in temporary trees, including token persistence, copied boot artifacts, and entry removal. It requires a systemd version supporting the invoked options and `/usr/lib/kernel/install.d/90-loaderentry.install`; CI installs `systemd-boot`.

To verify the kernel itself, build the fork directly: `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- gaokun3_defconfig && make -j"$(nproc)" Image modules qcom/sc8280xp-huawei-gaokun3.dtb`. Syntax checks and the boot-entry tests do not compile a kernel or validate a bootable image. Full package/image verification requires the corresponding ARM64 workflow, actual artifacts, and matching manifest metadata. Hardware acceptance remains separate; record device results using `docs/hardware-checklist.md`.

## Development Conventions and Safety

Follow `.editorconfig`: UTF-8, LF, final newline, no trailing whitespace, two spaces for shell/Python/YAML/Markdown, and tabs for C/header/DTS files. Shell entry points use Bash with `set -euo pipefail`, quote paths, and explicitly require stage variables. Keep shared toolchain arguments consistent across all kernel make calls and module packaging. Comments should explain non-obvious boot, firmware, or source compatibility behavior and stay current.

Preserve staged script boundaries. Device changes belong in the kernel fork as commits, not as patches in this repository. When a kernel-side change is needed, make it in `186526/linux-xanmod-gaokun3` and update `gaokun3-manifest.json` there if the release string, defconfig, or DTB name changes.

Image creation and local installation use sudo, privileged containers, loop devices, mounts, chroots, and host boot/module paths. Review `WORKDIR`, snapshot destinations, `ROOTFS_DIR`, `IMAGE_FILE`, and mount paths before executing: snapshot/output stages remove destination directories. Keep generated builds outside tracked source paths. Preserve checked-in firmware and EFI payload destinations; boot and firmware hooks depend on them. Keep tokens out of logs and release permissions limited to their documented purpose.

Ubuntu and Debian images create the account `user` with password `user` and passwordless sudo. Fedora creates no account and uses GNOME initial setup on first boot. Treat images as development artifacts and change credentials before normal use. Read `docs/migration.md` and `docs/kernel-audit.md` before claiming migration, hardware support, or EL2 readiness; historical CI results there may concern a different kernel commit.

## Further Reading

Read `README.md` for current entry-point examples, package outputs, and upstream sources. For boot-entry changes, read `docs/boot-layout.md` alongside current scripts. For compiler changes, read `docs/clang-thinlto.md` and the shared toolchain implementation. For kernel/display changes, read `docs/kernel-audit.md` and `docs/display-debug.md`. For installation and dual boot, use the English/Chinese dual-boot guides. The Fedora 44, Ubuntu 26.04, and EL2 guides include historical source/patch instructions that no longer match this repository; verify them against current build inputs before applying them.
