English | [中文](docs/README_zh.md)

# linux-gaokun-buildbot

Build scripts, tools, and firmware for Linux images targeting the Huawei MateBook E Go 2023 (codename `gaokun3`) based on Qualcomm Snapdragon 8cx Gen3 (`SC8280XP`). The kernel is the XanMod fork [`186526/linux-xanmod-gaokun3`](https://gitlab.com/186526/linux-xanmod-gaokun3), which carries the device drivers, device trees, `gaokun3_defconfig`, and the EL2 series as ordinary commits. This repository fetches that tree, builds it, and packages the result; it no longer carries or replays device patches.

The image pipeline now uses `systemd-boot` by default and can build a second EL2 kernel variant with `CONFIG_LOCALVERSION="-gaokun3-el2"`. The CI workflows default to that EL2 variant and to the pinned KernelSU integration; `./build.sh` keeps both opt-in through `BUILD_EL2` and `BUILD_KERNELSU`.

### Default build combination

New CI dispatches and reusable `workflow_call` runs default to the reviewed default profile:

```text
kernel_ref=gaokun3
build_el2=true     build_kernelsu=true
kernel_toolchain=clang   kernel_tune=sc8280xp
```

`kernel_toolchain=clang` selects Clang/LLVM with ThinLTO (`LLVM=1 LLVM_IAS=1 LD=ld.lld`, `CONFIG_LTO_CLANG_THIN`); `kernel_tune=sc8280xp` appends `KCFLAGS=-march=armv8.4-a+crypto -mtune=cortex-x1c`, and `build_el2=true`/`build_kernelsu=true` include the `-gaokun3-el2` package set and the pinned KernelSU revision in both variants. Every one of these remains an input: set `build_el2=false`, `build_kernelsu=false`, `kernel_toolchain=gcc`, or an empty `kernel_tune` to fall back to the portable/standard behaviour. `kernel_ref` selects the branch or tag of the kernel fork; the EL2 variant is always fetched from `KERNEL_EL2_REF` (`gaokun3-el2`). `kernel_tune` is not honoured by the workflow inputs of `build.sh`; pass `KERNEL_TUNE` in the environment there.

The package release tag encodes the combination, so an image workflow only finds a package set built the same way: `gaokun3-debs-gaokun3-std-el2-ksu-clang-<ts>` (and the `gaokun3-rpms-...` equivalent). A Clang or EL2/KernelSU suffix the image run does not expect causes the prefix lookup to miss, and a manifest whose `kernel_tag`/`build_el2`/`build_kernelsu` disagrees with the request is rejected.

### Kernel input

`build.env` names the kernel source, and `./build.sh kernel|debs|rpms` is the local entry point that consumes it:

```bash
KERNEL_REPOSITORY=186526/linux-xanmod-gaokun3
KERNEL_TAG=gaokun3
KERNEL_EL2_REF=gaokun3-el2
KERNEL_COMMIT=
KERNEL_EL2_COMMIT=
FEDORA_RELEASE=44
UBUNTU_RELEASE=26.04
```

`KERNEL_TAG` is both the ref fetched from `KERNEL_REPOSITORY` and the naming label the packages carry. `KERNEL_COMMIT` and `KERNEL_EL2_COMMIT` are optional exact pins: leave them empty to follow the branch tips, or set them to make a release reproducible, in which case `fetch_kernel_tree` refuses a ref that resolves to another commit.

`scripts/ci/lib/kernel_tree.sh` fetches the ref with `--depth=1` into a detached checkout and refuses to reuse a directory that has local edits. It then reads `gaokun3-manifest.json` from the tree root, which names the release strings, defconfig, and DTBs the packaging stage expects, so no script here hardcodes device file names.

A local run reuses an existing checkout when `KERNEL_SRC` is set, or `~/git/linux-xanmod-gaokun3` when it exists, instead of fetching:

```bash
KERNEL_TOOLCHAIN=clang KERNEL_TUNE=sc8280xp BUILD_EL2=true BUILD_KERNELSU=true ./build.sh debs
```

With `BUILD_EL2=true`, the EL2 variant is fetched from `KERNEL_EL2_REF` into its own checkout (`KERN_SRC_EL2`, default `$WORKDIR/linux-el2`) and built separately, so the standard variant is never patched in place.

## What is included

### Repository layout

- `build.sh`: local build entry point (`./build.sh kernel|debs|rpms`); sources `build.env` and prepares the kernel checkout
- `build.env`: reviewed build inputs (kernel repository, ref, optional commit pins, distro releases)
- `docs/`: bilingual usage/build guides and platform notes
- `firmware/`: minimal firmware bundle used by the image build
- `packaging/`: distro kernel and firmware package templates, metadata, and the pinned KernelSU revision
- `scripts/ci/`: kernel build, image creation, and packaging scripts
- `scripts/ci/lib/`: kernel fetch and manifest reader, toolchain selection, KernelSU integration, package manifest reader, release-tag rendering
- `tests/`: Python unit tests for `kernel-install` entry-token/BLS behavior
- `tools/`: device-specific helper scripts, service files, image assets, and EL2 EFI payloads

### Package outputs

The package pipeline builds and installs dedicated package sets:

- **Fedora (RPM)**: `kernel-gaokun3`, `kernel-modules-gaokun3`, `kernel-devel-gaokun3`, `linux-firmware-gaokun3`
- **Ubuntu (DEB)**: kernel image, module, and header packages include the exact kernel release in their package names, allowing multiple Gaokun3 kernels to be installed side by side; `linux-firmware-gaokun3` provides shared firmware.
- **Optional EL2 variants**: `*-gaokun3-el2` package set for the second EL2 kernel build
- Debian/Ubuntu kernel image packages run `update-initramfs` during install/upgrade, which in turn refreshes the BLS entry through the distro `systemd-boot` hook. Versioned package names allow diagnostic and current kernels to remain installed together.
- Fedora kernel RPMs now ship a matching `dracut.conf.d` snippet and run `dracut` + `kernel-install add` in `%posttrans`, so installing or upgrading the package refreshes the initramfs and BLS entry automatically.
- `linux-firmware-gaokun3` (DEB and RPM) ships the repository's Adreno `qcom/a660_gmu.bin` and `qcom/a660_sqe.fw` under `updates/qcom/`. The kernel firmware loader searches `updates/` before `/lib/firmware`, so these copies win over the distribution's `firmware-qcom-soc` / `linux-firmware-qualcomm-graphics` / `qcom-firmware` without colliding with their paths. This is required for the display: `msm` loads `qcom/a660_sqe.fw` before the panel comes up, and a missing file fails with `msm_dpu ... failed to load qcom/a660_sqe.fw` and a corrupted screen.

### Releases

- Fedora, Debian, and Ubuntu image releases contain compressed installable images.
- Gaokun RPM and DEB releases contain the standalone kernel and firmware package sets used by the image workflows.

### Kernel content

The device work is committed in the kernel fork, not replayed here:

- `gaokun3` branch: the device series (UCSI, EC, ADSP, HI846, display clock, SPI GSI, fbdev, DSC timing, panel orientation, MHI firmware retention), the device tree and its camera dtsi, and `gaokun3_defconfig`.
- `gaokun3-el2` branch: `gaokun3` plus the EL2 series (SMP2P, remoteproc restart of detached remoteprocs, Qualcomm SCM shared-memory bridge), the non-restartable-remoteproc guard, and `CONFIG_LOCALVERSION="-gaokun3-el2"`. The EL2 DTB is the upstream `sc8280xp-el2.dtbo` overlay applied to the device tree.
- `gaokun3-manifest.json` at the tree root: release strings, defconfig, and DTB names the packaging stage reads.

- **[Optional]** `packaging/kernelsu/PINNED_REVISION.md`: records the pinned upstream KernelSU revision. KernelSU is not vendored; when `BUILD_KERNELSU=true` the build clones `https://github.com/tiann/KernelSU.git` at `v3.3.0` (`932014ab5b2c9b74a3d11e2ec4d17dd10fc9442e`) and wires it into the kernel tree before configuration, so both the standard and EL2 variants include KernelSU. `packaging/kernelsu/*.patch` carries the source transformations applied to that checkout.

### Tool Sources

- `tools/audio`, `tools/bluetooth`: adapted from [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- `tools/el2/qebspilaa64.efi`: sourced from [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
- `tools/el2/slbounceaa64.efi`: sourced from [TravMurav/slbounce](https://github.com/TravMurav/slbounce)
- `tools/touchscreen-tuner`: adapted from [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux), with GTK4 GUI improvements in this repository

## Boot artifact layout

The image and local-install workflows now follow the standard `kernel-install` + BLS flow instead of hand-writing `systemd-boot` entries.

- BLS entries use the distribution name on Fedora and Ubuntu: `loader/entries/fedora-<kernel-release>.conf` or `loader/entries/ubuntu-<kernel-release>.conf`. `/etc/kernel/entry-token` persists that name for package upgrades and initramfs hooks; explicit calls use `--entry-token=os-id`. Debian uses the machine ID instead, producing `loader/entries/<machine-id>-<kernel-release>.conf`.
- Kernel, initrd/initramfs, and DTB files are placed under `fedora/<kernel-release>/` or `ubuntu/<kernel-release>/` on the ESP. Debian keeps the machine-ID directory name. The system machine ID remains separate.
- Existing machine-ID entries are retained as fallback entries during migration. After booting and verifying the new entry, old entries can be removed deliberately. Two installations of the same distribution sharing an ESP need distinct tokens. See [boot layout](docs/boot-layout.md).
- A compatibility copy of the DTB is also kept in `/boot` so users can switch to GRUB more easily later.
- Ubuntu DTBs are installed in `/usr/lib/linux-image-<kernel-release>/qcom/` for `kernel-install`, plus `/boot/dtb-<kernel-release>` as a compatibility copy.
- Fedora DTBs are installed in `/usr/lib/modules/<kernel-release>/dtb/qcom/` for `kernel-install`, plus `/boot/dtb-<kernel-release>/qcom/` as a compatibility copy.
- The Gaokun3 image scripts provide `/etc/kernel/cmdline` and `/etc/kernel/devicetree`, then call `kernel-install add` to populate the final BLS entry.

## Local builds with KernelSU

For a reproducible, pinned build use `./build.sh` (see [Kernel input](#kernel-input)); it also honors `BUILD_KERNELSU=true` and `BUILD_EL2=true`.

`./build.sh` integrates KernelSU when `BUILD_KERNELSU=true`. The relevant overrides:

| Variable | Purpose | Default when unset |
| -------- | ------- | ------------------ |
| `BUILD_KERNELSU` | Wire the pinned KernelSU into both variants | `false` |
| `BUILD_EL2` | Also build the EL2 variant from `KERNEL_EL2_REF` | `false` |
| `KERNEL_SRC` | Existing kernel checkout to build instead of fetching | `~/git/linux-xanmod-gaokun3` when present |
| `KERNEL_TAG` / `KERNEL_EL2_REF` | Kernel fork refs to fetch | `build.env` |
| `KERNSU_URL` / `KERNSU_REF` / `KERNSU_COMMIT` / `KERNSU_SRC` | KernelSU clone source, pinned ref and commit, clone directory | `tiann/KernelSU.git`, `v3.3.0`, the pinned commit, `$WORKDIR/kernelsu-src` |

Notes:

- KernelSU is cloned at the pinned revision and wired into each variant's source tree before its defconfig, so the standard (`$KERN_OUT`) and EL2 (`$KERN_OUT_EL2`) variants both include it; the EL2 branch keeps its `-gaokun3-el2` `CONFIG_LOCALVERSION` suffix and the DTB name is unchanged.
- A KernelSU build needs network access to `github.com` at build time (the clone). No extra packages are required. The helper enables `CONFIG_KPROBES`, `CONFIG_FTRACE`, and `CONFIG_KSU` and verifies `CONFIG_KSU=y`/`CONFIG_KPROBES=y`/`CONFIG_TRACEPOINTS=y` in each variant's `.config`.
- If the clone or checkout fails, the helper fails with an explicit message instead of silently building a kernel without KernelSU. Set `BUILD_KERNELSU=false` to opt out.

## Getting started

- Release: <https://github.com/186526/linux-gaokun-buildbot/releases>
- Pinned-kernel migration record and blockers: [migration.md](docs/migration.md)
- Dual-boot guide: [English](docs/dual_boot_guide_en.md) | [中文](docs/dual_boot_guide_zh.md)
- Historical EL2 implementation notes: [English](docs/el2_kvm_guide_en.md) | [中文](docs/el2_kvm_guide_zh.md)
- Awesome Gaokun3: [English](docs/awesome_gaokun3_en.md) | [中文](docs/awesome_gaokun3_zh.md)
- Historical build guide – Fedora 44: [English](docs/matebook_ego_build_guide_fedora44_en.md) | [中文](docs/matebook_ego_build_guide_fedora44_zh.md)
- Historical build guide – Ubuntu 26.04: [English](docs/matebook_ego_build_guide_ubuntu26.04_en.md) | [中文](docs/matebook_ego_build_guide_ubuntu26.04_zh.md)

## Feature Support

For an overview of hardware support status on the device, see [right-0903/linux-gaokun `## Feature Support`](https://github.com/right-0903/linux-gaokun?tab=readme-ov-file#feature-support).

## References

- [186526/linux-xanmod-gaokun3](https://gitlab.com/186526/linux-xanmod-gaokun3) : The XanMod fork named by `build.env`; it carries the device enablement, DTS, drivers, `gaokun3_defconfig`, and the EL2 branch that this repository builds and packages.
- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun) : The main source of the kernel patches and device support work, with detailed commit messages and explanations.
- [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun) : Another fork of the kernel patches and device support work, with some unique commits and explanations for Touchscreen and EC.
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux) : The earliest repo to fix panel backlight problem, with some additional resources and modifications for Gaokun3 Linux support.
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun) : Several AUR packages built for Gaokun3, including kernel and firmware packages.
- [chenxuecong2/firmware-huawei-gaokun3](https://github.com/chenxuecong2/firmware-huawei-gaokun3) : A firmware bundle repository for Gaokun3.
- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux) : The upstream source for the directly integrated Himax HX83121A Linux touchscreen driver and tuning algorithm in this repository.
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev) : The original Windows-side touchscreen algorithm project referenced by EGoTouchRev-Linux, and an important upstream reference for the Gaokun3 touchscreen tuning pipeline.
- [TravMurav/slbounce](https://github.com/TravMurav/slbounce) : A UEFI application that enables EL2 support and Secure Launch on Gaokun3.
- [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd) : A Linux kernel tree with some useful patches for EL2 support on sc8280xp platforms.
- [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil) : A UEFI application that pre-launches the DSP firmware on Qualcomm platforms, which can be used in the boot chain before launching Linux.

Kernel audit and remaining work: [kernel-audit.md](docs/kernel-audit.md).
