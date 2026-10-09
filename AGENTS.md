# linux-gaokun-buildbot

## Project Overview

This repository builds ARM64 Linux kernel packages and installable disk images for the Huawei MateBook E Go 2023 (`gaokun3`, Qualcomm Snapdragon 8cx Gen 3 / `SC8280XP`). It is a build and device-integration repository, not a complete Linux kernel checkout. The downstream kernel, including device enablement, lives in `gaokun3/linux` on GitHub.

The implementation uses Bash, GitHub Actions YAML, kernel C/DTS patches, Debian package templates, RPM specs, Python utilities, systemd services, ALSA UCM, and WirePlumber configuration. The touchscreen tuner uses PyGObject with GTK 4 and libadwaita. There is no `package.json`, `pyproject.toml`, `Cargo.toml`, Go module, or repository Makefile; kernel `make` commands run in an external kernel tree. Python tests use standard-library `unittest`.

## Configuration and Source Boundaries

- `build.env` is the reviewed source input for local and CI builds. It pins `KERNEL_REPOSITORY=gaokun3/linux`, naming label `KERNEL_TAG=gaokun3`, and exact `KERNEL_COMMIT=73033564068250603f5b2150c408554faaf22d66`; Fedora and Ubuntu releases are 44 and 26.04. Change reviewed inputs with adaptation notes.
- `KERNEL_EL2_COMMIT` is reserved and empty. Kernel EL2 builds apply patches rather than checking out a separate EL2 commit. Keep the field available because image workflows read it under `set -u`.
- `scripts/lib/kernel_source.sh:prepare_kernel_source` fetches the exact 40-character commit with `--depth=1` and checks out detached HEAD. Existing source directories must match the commit, be clean (including untracked files), and contain `arch/arm64/configs/gaokun3_defconfig`; the helper refuses mismatches instead of resetting them.
- `KERNEL_BASE=mainline` means the pinned downstream tree in `build.sh` and package CI. The legacy local helper instead resolves a mainline tag. Check which entry point is being changed before interpreting this name.
- `KERNEL_BASE=xanmod` selects `https://gitlab.com/xanmod/linux.git` at `KERNEL_XANMOD_TAG` (default `7.2.9-xanmod1`). `build.sh` refuses to re-clone an existing XanMod source directory and records the fetched commit. Set `KERNEL_TAG` to the intended artifact label; local builds preserve a caller-provided label, and package CI checks that the XanMod label matches its source tag.
- `.editorconfig` defines formatting. `.github/workflows/` defines runner dependencies, workflow inputs, release behavior, and CI checks; package templates under `packaging/` define installed-file and upgrade contracts.

## Repository Organization

- `build.sh`: local `kernel`, `debs`, and `rpms` entry point; loads reviewed inputs, prepares source, exports stage variables, and invokes the build/package scripts.
- `scripts/ci/20_build_kernel_variants.sh`: prepares patches and KernelSU, checks device parity, configures/builds standard and optional EL2 kernels, and records kernel releases.
- `scripts/ci/lib/select_base.sh`: source-base selection, same-name patch overrides, ordered series discovery, and already-applied checks.
- `scripts/ci/lib/toolchain.sh`: shared GCC/Clang, link-time optimization, CPU tuning, compiler probes, and generated-config checks. Kernel and package scripts share its `KERNEL_MAKE_ARGS` array.
- `scripts/ci/lib/kernelsu.sh`: opt-in pinned KernelSU cloning, integration, and configuration checks; the pin is documented in `patches/kernelsu/PINNED_REVISION.md`.
- `scripts/ci/70_build_package_{debs,rpms}.sh`: stage kernels, modules, development trees, and firmware; render `packaging/` templates; emit packages, `package-manifest.json`, and `package-release-body.md` into `ARTIFACT_DIR`.
- `scripts/ci/30_bootstrap_rootfs.sh`: Fedora rootfs bootstrap through privileged Fedora Docker and `dnf --installroot`. Debian bootstrap (`debootstrap`) and Ubuntu bootstrap (downloaded `ubuntu-base` tarball) remain in their workflows.
- `scripts/ci/50_make_image_{debian,fedora,ubuntu}.sh`: disk partitioning, filesystem setup, rootfs copying, initramfs and boot configuration. `scripts/ci/lib/common_image.sh` installs shared device assets and optional EL2 EFI payloads.
- `scripts/ci/60_package_release_{debian,fedora,ubuntu}.sh`: compress images with zstd, split compressed files at the 2 GiB threshold, and generate release metadata.
- `scripts/local/build_kernel.sh`: legacy interactive Ubuntu/Fedora host build/install helper, independent of the `build.env` pin. README documents its non-interactive overrides.
- `patches/upstream/`, `patches/others/`, `patches/media/`, and `patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch`: device series applied to XanMod by the CI kernel stage. The pinned downstream tree already contains its device files and does not replay this series.
- `patches/el2/`: optional EL2 series. `patches/xanmod/`: same-basename replacements and additional patches for XanMod, including EL2 overrides.
- `dts/` and `defconfig/`: review mirrors of the files embedded in `patches/0099`; keep mirror content synchronized with the patch. The kernel build uses the prepared kernel tree, not these directories directly.
- `drivers/touchscreen-hx83121a/`: tracked touchscreen C/header sources (`himax-spi-core.c`, `hx-algo.c`, `hx-algo.h`). They are not imported by the current CI build stage; compilable device drivers are in the external kernel tree.
- `firmware/`: device firmware packaged and copied into images. `tools/el2/`: binary EFI payloads and implementation notes.
- `tools/audio/`, `tools/bluetooth/`, `tools/image-assets/`, `tools/touchscreen-tuner/`: audio configuration, Bluetooth address patcher/service, module and monitor configuration, and touchscreen GUI/launcher assets.
- `tests/`: source-protection, patch-selection, and real systemd boot-entry tests. `docs/`: English/Chinese installation guides, migration notes, kernel audit, and hardware acceptance checklist.

## Build Commands and Pipeline

Install the build tools before invoking `build.sh`; it uses the host toolchain and package builders. CI workflow dependency steps and the local helper list the concrete distro packages. Kernel builds need Git, make, GCC or Clang/LLVM, bc, bison, flex, OpenSSL/libelf development files, pahole, and related kernel tools; packaging additionally uses `dpkg-deb` or `rpmbuild`. Non-AArch64 hosts default to `CROSS_COMPILE=aarch64-linux-gnu-`.

```bash
./build.sh --help
./build.sh kernel
./build.sh debs
./build.sh rpms
KERNEL_TOOLCHAIN=clang BUILD_KERNELSU=true ./build.sh kernel
KERNEL_TAG=7.2.9-xanmod1 KERNEL_BASE=xanmod ./build.sh kernel
```

`WORKDIR` defaults to `./build`, with `linux`, `kernel-out`, `kernel-out-el2`, and `artifacts` beneath it. `KERN_SRC`, `KERN_SRC_BASE`, `KERN_OUT`, `KERN_OUT_EL2`, and `ARTIFACT_DIR` control source, snapshot, build, and artifact locations. Builds write `kernel-release.txt` and optionally `kernel-release-el2.txt` in `WORKDIR`.

The kernel stage applies the XanMod series when selected, checks prepared device parity, optionally integrates KernelSU, and runs `gaokun3_defconfig`, `olddefconfig`, parallel `make -j$(nproc)`, and `modules_prepare` with out-of-tree `O=` output. Package stages reuse the same toolchain for `modules_install`.

`BUILD_EL2=true` builds both variants. In the `build.sh` flow, the standard source is copied to `KERN_SRC_BASE` after the standard build, then EL2 patches modify the original tree (`KERN_SRC_EL2=KERN_SRC`). Standard packaging reads the preserved snapshot. The EL2 source changes are committed inside the external checkout, and its local version defaults to `-gaokun3-el2` (`KERN_LOCALVERSION_EL2` can override it). The resulting source may no longer satisfy the clean pinned-source guard on a subsequent invocation; use dedicated build checkouts and inspect their state before reuse.

Toolchain controls:

- `KERNEL_TOOLCHAIN=gcc` is the default and uses no LLVM arguments; `KERNEL_LTO` resolves to `none`.
- `KERNEL_TOOLCHAIN=clang` (also accepts `llvm`) selects `LLVM=1 LLVM_IAS=1 LD=ld.lld` and defaults to `KERNEL_LTO=thin`. `KERNEL_LTO=none` disables the ThinLTO configuration step; GCC rejects `thin`.
- `KERNEL_TUNE=sc8280xp` (aliases `8cx-gen3`, `8cxgen3`) adds `KCFLAGS=-march=armv8.4-a+crypto -mtune=cortex-x1c`. Other values add only `-mtune=<cpu>`. Existing `KCFLAGS` are preserved and a compiler probe rejects unsupported tuning before configuration. Unset tuning leaves the portable baseline.
- `BUILD_KERNELSU=true` clones and wires the pinned upstream revision before configuration for both requested variants; CI/local pinned builds default to false. The legacy interactive helper has different prompt defaults, documented in README.

Direct stage callers must satisfy each script's `: "${VAR:?message}"` guards. Kernel builds require `GAOKUN_DIR`, `WORKDIR`, and `KERN_SRC`; packaging additionally requires artifact paths, prepared source/output paths, `KERNEL_TAG`, `KERNEL_COMMIT`, and `PACKAGE_RELEASE_TAG`. Preserve these contracts when editing the pipeline.

## Packages, Images, and Runtime

DEBs provide versioned kernel image, modules, and headers packages plus shared `linux-firmware-gaokun3`. RPMs provide `kernel-gaokun3`, `kernel-modules-gaokun3`, `kernel-devel-gaokun3`, and `linux-firmware-gaokun3`. EL2 adds a second kernel package set. The manifest records source/build metadata and package filenames used by image workflows.

DEB image installation invokes `update-initramfs`; distro systemd-boot hooks refresh boot entries. RPM kernel `%posttrans` runs dracut and `kernel-install add`; the standard kernel updates the boot default, while EL2 remains an explicit boot-menu choice. Firmware packages put repository Adreno files in `firmware/updates/qcom/` so they take precedence without colliding with distro firmware paths. Preserve firmware paths and initramfs/dracut hooks together.

Images use GPT with a 1 GiB FAT EFI system partition and one root partition. Debian uses Btrfs subvolumes `@`, `@home`, and `@var`; Ubuntu and Fedora use ext4. Boot uses `systemd-boot`, `kernel-install`, and Boot Loader Specification (BLS) entries. Current image scripts persist distribution entry tokens in `/etc/kernel/entry-token`: `debian`, `ubuntu`, or `fedora`. Entries are `loader/entries/<token>-<kernel-release>.conf`, with kernel/initrd/DTB files beneath `<token>/<kernel-release>/` on the EFI partition. Older docs still describe Debian machine-ID tokens; consult the current scripts when changing boot behavior.

`/etc/kernel/cmdline` and `/etc/kernel/devicetree` drive boot-entry creation. Compatibility DTB copies remain under `/boot`; DEBs also stage DTBs under `/usr/lib/linux-image-<release>/qcom/`, and Fedora uses `/usr/lib/modules/<release>/dtb/qcom/`. Shared assets install Bluetooth service files, ALSA/WirePlumber configuration, module loading rules, portrait-panel monitor configuration, and touchscreen tuning tools. EL2 adds `slbounceaa64.efi`, `qebspilaa64.efi`, `tcblaunch.exe`, and DSP/GPU firmware on the EFI partition.

## CI and Release Process

- `checks.yml` runs on `ubuntu-24.04` for pull requests and pushes to `main`/`next`: shell syntax, selected ShellCheck files, toolchain-selection contract checks, Python tests, DSC patch-series checks, and device-parity series preflight.
- `gaokun3-package-{debs,rpms}.yml` support manual dispatch and reusable `workflow_call`, run on `ubuntu-24.04-arm`, and default `publish_release` to false. RPM assembly uses a Fedora container selected by `FEDORA_RELEASE`.
- `validate-packages.yml` runs manually or on build-related pushes to `next`; it calls both package workflows with release publishing disabled.
- `debian-gaokun3-release.yml`, `ubuntu-gaokun3-release.yml`, and `fedora-gaokun3-release.yml` manually assemble ARM64 images using rebuilt packages or existing package releases. Fedora can also consume package Actions artifacts by `package_run_id` and defaults to non-publishing validation; inspect each workflow's actual publish condition before running it.
- Image workflows check package manifests and select package filenames from them. Preserve tag, source-commit, EL2, and KernelSU compatibility checks on the applicable download/build paths. Release operations target `${GITHUB_REPOSITORY}` and require `contents: write`.

The Fedora and Ubuntu image workflows currently reject `BUILD_EL2=true` when `KERNEL_EL2_COMMIT` is empty, despite patch-based EL2 support in the kernel/package stages. Debian has no equivalent guard. A successful kernel build alone does not establish that every image workflow supports that profile or that the device boots it.

## Testing and Verification

Run the checks relevant to the changed scripts, then use the standard suite for integration review:

```bash
bash -n build.sh build.env
find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck -S warning build.sh scripts/lib/kernel_source.sh scripts/ci/20_build_kernel_variants.sh scripts/ci/lib/toolchain.sh scripts/local/build_kernel.sh
python3 -m unittest discover -s tests -v
scripts/ci/check_display_dsc_fix.sh --series
scripts/ci/check_device_parity.sh --series
```

`tests/test_kernel_source.py` checks source mismatch/dirty guards, XanMod DSC anchors, and the EL2 local-version contract. `tests/test_boot_entries.py` exercises actual `kernel-install inspect` and `90-loaderentry.install` in temporary trees, including token persistence, copied boot artifacts, and entry removal. It requires a systemd version supporting the invoked options and `/usr/lib/kernel/install.d/90-loaderentry.install`; CI installs `systemd-boot`.

The DSC checker also accepts a prepared kernel tree; read its usage before checking applied source. Device parity is checked inside the kernel stage before standard and EL2 configuration. Series preflight and syntax checks do not compile a kernel or validate a bootable image. Full package/image verification requires the corresponding ARM64 workflow, actual artifacts, and matching manifest metadata. Hardware acceptance remains separate; record device results using `docs/hardware-checklist.md`.

## Development Conventions and Safety

Follow `.editorconfig`: UTF-8, LF, final newline, no trailing whitespace, two spaces for shell/Python/YAML/Markdown, and tabs for C/header/DTS files. Shell entry points use Bash with `set -euo pipefail`, quote paths, and explicitly require stage variables. Keep shared toolchain arguments consistent across all kernel make calls and module packaging. Comments should explain non-obvious boot, firmware, or source compatibility behavior and stay current.

Preserve staged script boundaries and patch filenames. Shared patches are processed in filename order, substituting same-basename overrides; base-only patches follow the shared series. A patch is considered already applied only after reverse-apply validation or its supported fixed-string post-image anchors all match, not merely because application conflicts. For kernel patch generation, use a narrowly scoped detached temporary worktree, fetch missing objects only, generate a format-patch from the source change, verify with `git apply --check` or reverse-check, and remove the temporary worktree. Keep unrelated changes out of patch-generation tasks.

Image creation and local installation use sudo, privileged containers, loop devices, mounts, chroots, and host boot/module paths. Review `WORKDIR`, snapshot destinations, `ROOTFS_DIR`, `IMAGE_FILE`, and mount paths before executing: snapshot/output stages remove destination directories. Keep generated builds outside tracked source paths. Preserve checked-in firmware and EFI payload destinations; boot and firmware hooks depend on them. Keep tokens out of logs and release permissions limited to their documented purpose.

Ubuntu and Debian images create the account `user` with password `user` and passwordless sudo. Fedora creates no account and uses GNOME initial setup on first boot. Treat images as development artifacts and change credentials before normal use. Read `docs/migration.md` and `docs/kernel-audit.md` before claiming migration, hardware support, or EL2 readiness; historical CI results there may concern a different kernel commit.

## Further Reading

Read `README.md` for current entry-point examples, legacy-helper overrides, package outputs, and upstream sources. For boot-entry changes, read `docs/boot-layout.md` alongside current scripts. For compiler changes, read `docs/clang-thinlto.md` and the shared toolchain implementation. For kernel/display changes, read `docs/kernel-audit.md` and `docs/display-debug.md`. For installation and dual boot, use the English/Chinese dual-boot guides. Fedora 44, Ubuntu 26.04, and EL2 guides include historical source/patch instructions; verify them against current build inputs before applying them.
