English | [中文](docs/README_zh.md)

# linux-gaokun-buildbot

Build scripts, tools, and firmware for Linux images targeting the Huawei MateBook E Go 2023 (codename `gaokun3`) based on Qualcomm Snapdragon 8cx Gen3 (`SC8280XP`). The kernel sources, drivers, device trees, and `gaokun3_defconfig` are maintained in the separate downstream kernel repository [`gaokun3/linux`](https://github.com/gaokun3/linux).

The image pipeline now uses `systemd-boot` by default and can optionally build a second EL2 kernel variant with `CONFIG_LOCALVERSION="-gaokun3-el2"`. Builds can also opt into the KernelSU integration with `BUILD_KERNELSU`.

### Pinned kernel input

`build.env` pins the exact kernel input, and `./build.sh kernel|debs|rpms` is the local entry point that consumes it:

```bash
KERNEL_REPOSITORY=gaokun3/linux
KERNEL_TAG=gaokun3
KERNEL_COMMIT=73033564068250603f5b2150c408554faaf22d66
KERNEL_EL2_COMMIT=
FEDORA_RELEASE=44
UBUNTU_RELEASE=26.04
```

`scripts/lib/kernel_source.sh` clones exactly that commit (`git fetch --depth=1`, detached HEAD) and refuses to continue when the checkout is at another commit or contains local edits or untracked files. `KERNEL_TAG` is only a naming label; the commit is what is checked out. The pinned Gaokun3 tree already contains device drivers, DTS files, and `gaokun3_defconfig`, so the build does not replay the legacy device patch series on it. `KERNEL_BASE=xanmod` selects the separate XanMod tree at `KERNEL_XANMOD_TAG` (default `7.2.9-xanmod1`) and applies the repository patch series with XanMod overrides. EL2 is patch-based; `KERNEL_EL2_COMMIT` remains empty and is not required for `BUILD_EL2=true`.

## What is included

### Repository layout

- `build.sh`: local build entry point (`./build.sh kernel|debs|rpms`); sources `build.env` and prepares the pinned kernel checkout
- `build.env`: reviewed, pinned build inputs (kernel repository, tag, commit, EL2 commit, distro releases)
- `patches/`: device patches applied to XanMod, EL2 patches, and the pinned KernelSU revision
- `defconfig/`, `dts/`: review mirrors of the device files maintained in the pinned `gaokun3/linux` tree
- `docs/`: bilingual usage/build guides and platform notes
- `firmware/`: minimal firmware bundle used by the image build
- `packaging/`: distro kernel and firmware package templates and metadata
- `scripts/ci/`: workflow build, image creation, and packaging scripts
- `scripts/lib/`: pinned-source preparation and guards
- `scripts/local/`: legacy interactive on-device build helper
- `tests/`: Python unit tests for the source guards and for `kernel-install` entry-token/BLS behavior
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

### Kernel patches

The pinned Gaokun3 kernel contains its device drivers, DTS, and defconfig. The build applies the legacy device patch series only to XanMod; the pinned Gaokun3 build does not replay those patches. For XanMod, the series are applied in filename order:

- `patches/upstream/*`: Gaokun3 UCSI, EC, ADSP, and HI846 support adapted to the XanMod source.
- `patches/others/*`: display clock, SPI GSI, fbdev, DSC interface width, and panel orientation fixes.
- `patches/media/*`: SC8280XP Venus resources, adapted from the [jhovold/linux](https://github.com/jhovold/linux/commits/wip/sc8280xp-6.16) Venus series.
- `patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch`: imports the device DTS and `gaokun3_defconfig` for XanMod.
- `patches/el2/*`: remoteproc restart of detached remoteprocs and Qualcomm SCM shared-memory bridge changes, with XanMod-specific EL2 overrides.
- `patches/xanmod/*`: base-specific replacements and additions, including the bonded DSI PLL fix, touchscreen PDC mapping fix, and Venus DTS adaptation. A patch is skipped only when reverse-apply validation or a patch-specific set of target-file anchors confirms that its change is already present.

With `BUILD_EL2=true`, the EL2 series is applied to a separate source snapshot so standard packages use the unmodified standard tree.
- **[Optional]** `patches/kernelsu/PINNED_REVISION.md`: records the pinned upstream KernelSU revision. KernelSU is not vendored; when `BUILD_KERNELSU=true` the build clones `https://github.com/tiann/KernelSU.git` at `v3.3.0` (`932014ab5b2c9b74a3d11e2ec4d17dd10fc9442e`) and wires it into the kernel tree before configuration, so both the standard and EL2 variants include KernelSU.

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

For a reproducible, pinned build use `./build.sh` (see [Pinned kernel input](#pinned-kernel-input)); it also honors `BUILD_KERNELSU=true` and `BUILD_EL2=true`.

The legacy on-device helper `scripts/local/build_kernel.sh` clones mainline and applies the patch series itself. It can integrate KernelSU. It is interactive by default, but every prompt has a non-interactive override, so it can also run unattended:

```bash
export KERNEL_TAG=7.2.9-xanmod1   # real XanMod tag
export KERNEL_BASE=xanmod
export BUILD_KERNELSU=true       # clone and wire pinned KernelSU
export BUILD_EL2=true            # build the standard kernel and the EL2 kernel
export INSTALL_KERNEL=false      # build only, do not install
scripts/local/build_kernel.sh < /dev/null
```

With stdin closed and the overrides above set, the run is fully non-interactive: the remaining prompts (toolchain install, kernel pull, mirror) fall back to their documented defaults instead of aborting.

Overrides and defaults:

| Variable | Purpose | Default when unset |
| -------- | ------- | ------------------ |
| `BUILD_KERNELSU` | Wire the pinned KernelSU into the kernel | prompt, defaults to yes |
| `EL2_CHOICE` | `y` (EL2 only), `n` (standard only), `both` | prompt, defaults to `n` |
| `BUILD_EL2` | Convenience alias for `EL2_CHOICE=both` | unset |
| `INSTALL_DEPS` | Install the minimal build toolchain | prompt, defaults to no |
| `PULL_KERNEL` | Pull the kernel and apply patches when the tree is missing | prompt, defaults to no |
| `USE_MIRROR` | Use the Chinese kernel mirror (mainline base only) | prompt, defaults to yes |
| `INSTALL_KERNEL` | Install each built kernel after it compiles | prompt per kernel, defaults to yes |
| `KERNSU_URL` / `KERNSU_REF` / `KERNSU_COMMIT` / `KERNSU_SRC` | KernelSU clone source, pinned ref and commit, clone directory | `tiann/KernelSU.git`, `v3.3.0`, the pinned commit, `$WORKDIR/kernelsu-src` |

Notes:

- `BUILD_EL2`/`EL2_CHOICE` preserve the original selection semantics: `EL2_CHOICE=y` builds only EL2, `n` only standard, `both` (or `BUILD_EL2=true`) both.
- KernelSU is cloned at the pinned revision and wired into the source tree before `gaokun3_defconfig`, so both the standard (`$KERN_OUT`) and the EL2 (`$KERN_OUT_EL2`) variants include KernelSU; the EL2 variant keeps its `-gaokun3-el2` `CONFIG_LOCALVERSION` suffix and the DTB name is unchanged.
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

- [gaokun3/linux](https://github.com/gaokun3/linux) : The downstream kernel tree pinned by `build.env`; it carries the device enablement, DTS, drivers, and `gaokun3_defconfig` that this repository previously applied as patches.
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
