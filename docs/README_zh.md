[English](../README.md) | 中文

# linux-gaokun-buildbot

面向华为 MateBook E Go 2023（代号 `gaokun3`）、基于高通骁龙 8cx Gen3（`SC8280XP`）平台的 Linux 镜像构建脚本、工具和固件。内核源码、驱动、设备树及配置在 XanMod 分支 [186526/linux-xanmod-gaokun3](https://gitlab.com/186526/linux-xanmod-gaokun3) 维护，以普通提交形式存在于 `gaokun3` 与 `gaokun3-el2` 两个分支；本仓库只负责获取该内核树、构建并打包。

**迁移草案，尚不可发布。** 本仓库为 [186526/linux-gaokun-buildbot](https://github.com/186526/linux-gaokun-buildbot)；Iris/Himax/EC 候选已通过完整内核编译、DEB/RPM 打包及 Fedora 镜像构建，仍待实机验收。参见 [迁移记录与检查项](migration.md)。

`build.env` 指定内核仓库、分支与发行版版本；`./build.sh kernel|debs|rpms` 是本地入口，镜像组装暂仍由 CI 执行。

### 内核输入

```bash
KERNEL_REPOSITORY=186526/linux-xanmod-gaokun3
KERNEL_TAG=gaokun3
KERNEL_EL2_REF=gaokun3-el2
KERNEL_COMMIT=
KERNEL_EL2_COMMIT=
FEDORA_RELEASE=44
UBUNTU_RELEASE=26.04
```

`KERNEL_TAG` 既是从 `KERNEL_REPOSITORY` 获取的分支，也是软件包携带的命名标签。`KERNEL_COMMIT` 与 `KERNEL_EL2_COMMIT` 是可选的精确提交固定值：留空表示跟随分支尖端，填写后 `fetch_kernel_tree` 会拒绝解析到其他提交的分支。

`scripts/ci/lib/kernel_tree.sh` 以 `--depth=1` 获取该分支到分离检出目录，并拒绝复用有本地改动的目录。随后它读取内核树根的 `gaokun3-manifest.json`，其中给出打包阶段需要的 release 字符串、defconfig 与 DTB 名称，因此本仓库的脚本不硬编码设备文件名。

本地运行时会优先复用已有检出：设置了 `KERNEL_SRC` 就用它，否则若 `~/git/linux-xanmod-gaokun3` 存在就用它，都不存在才去获取。

`BUILD_EL2=true` 时，EL2 变体从 `KERNEL_EL2_REF` 取到独立检出目录（`KERN_SRC_EL2`，默认 `$WORKDIR/linux-el2`）单独编译，标准变体不会被就地打补丁。

### 默认构建组合

CI 的 `workflow_dispatch` 与可复用 `workflow_call` 默认使用经审阅的默认组合：

```text
kernel_ref=gaokun3
build_el2=true     build_kernelsu=true
kernel_toolchain=clang   kernel_tune=sc8280xp
```

`kernel_toolchain=clang` 选择 Clang/LLVM + ThinLTO；`kernel_tune=sc8280xp` 追加 `KCFLAGS=-march=armv8.4-a+crypto -mtune=cortex-x1c`；`build_el2=true`/`build_kernelsu=true` 在标准与 EL2 两个变体中包含 `-gaokun3-el2` 包集与固定版本的 KernelSU。这些仍是输入：改回 `build_el2=false`、`build_kernelsu=false`、`kernel_toolchain=gcc` 或将 `kernel_tune` 留空即可回到便携/标准行为。`kernel_ref` 选择内核分支或 tag；EL2 变体固定从 `KERNEL_EL2_REF`（`gaokun3-el2`）获取。`build.sh` 不读取工作流输入，本地需通过环境变量 `KERNEL_TUNE` 传入。

## 包含内容

### 仓库结构

- `build.sh`：本地构建入口（`./build.sh kernel|debs|rpms`），读取 `build.env` 并准备内核检出
- `build.env`：经审阅的构建输入（内核仓库、分支、可选提交固定、发行版版本）
- `docs/`：中英文使用/构建指南与平台说明
- `firmware/`：镜像构建使用的最小固件集
- `packaging/`：各发行版内核和固件包的打包模板、元数据，以及固定版本的 KernelSU 修订记录
- `scripts/ci/`：内核构建、镜像创建和打包脚本
- `scripts/ci/lib/`：内核获取与 manifest 读取、工具链选择、KernelSU 接入、包 manifest 读取、发布 tag 渲染
- `tests/`：`kernel-install` entry-token/BLS 行为的 Python 单元测试
- `tools/`：设备专属辅助脚本、服务文件、镜像资产和 EL2 EFI 载荷

### 软件包产物

软件包流水线会构建并安装专用软件包集：

- **Fedora (RPM)**：`kernel-gaokun3`、`kernel-modules-gaokun3`、`kernel-devel-gaokun3`、`linux-firmware-gaokun3`
- **Ubuntu (DEB)**：`linux-image-gaokun3`、`linux-modules-gaokun3`、`linux-headers-gaokun3`、`linux-firmware-gaokun3`
- **EL2 变体**：`build_el2=true` 时额外构建 `*-gaokun3-el2` 包集（CI 默认开启）。
- Ubuntu 内核镜像包在安装/升级时运行 `update-initramfs`，进而通过发行版的 `systemd-boot` 钩子刷新 BLS 条目。
- Fedora 内核 RPM 现自带匹配的 `dracut.conf.d` 片段，并在 `%posttrans` 中运行 `dracut` + `kernel-install add`，因此安装或升级软件包会自动刷新 initramfs 和 BLS 条目。
- `linux-firmware-gaokun3`（DEB 与 RPM）把仓库自带的 Adreno 固件 `qcom/a660_gmu.bin`、`qcom/a660_sqe.fw` 安装到 `updates/qcom/`。内核固件加载器先搜索 `updates/` 再搜索 `/lib/firmware`，因此仓库副本优先生效，又不与发行版的 `firmware-qcom-soc` / `linux-firmware-qualcomm-graphics` / `qcom-firmware` 争抢路径。这是显示正常所必需的：`msm` 在点亮面板前加载 `qcom/a660_sqe.fw`，缺失时会报 `msm_dpu ... failed to load qcom/a660_sqe.fw` 并导致花屏。

### Release 产物

- Fedora、Debian 和 Ubuntu 镜像 release 包含压缩后的可安装镜像。
- Gaokun RPM 和 DEB release 包含镜像工作流所使用的独立内核与固件软件包集合。

### 内核内容

设备适配以提交形式存在于内核 fork 中，本仓库不再重放补丁：

- `gaokun3` 分支：设备补丁序列（UCSI、EC、ADSP、HI846、显示时钟、SPI GSI、fbdev、DSC 时序、面板方向、MHI 固件保留）、设备树与相机 dtsi、`gaokun3_defconfig`。
- `gaokun3-el2` 分支：`gaokun3` 加上 EL2 序列（SMP2P、detached remoteproc 重启、Qualcomm SCM 共享内存桥）、不可重启 remote 的守卫，以及 `CONFIG_LOCALVERSION="-gaokun3-el2"`。EL2 DTB 由上游 `sc8280xp-el2.dtbo` overlay 叠加到设备树生成。
- 内核树根的 `gaokun3-manifest.json`：打包阶段读取的 release 字符串、defconfig 与 DTB 名称。

- **[可选]** `packaging/kernelsu/PINNED_REVISION.md`：记录固定的上游 KernelSU 版本。KernelSU 不内联；当 `BUILD_KERNELSU=true` 时，构建会克隆 `https://github.com/tiann/KernelSU.git` 的 `v3.3.0`（`932014ab5b2c9b74a3d11e2ec4d17dd10fc9442e`）并在配置前接入内核树，因此标准与 EL2 两个变体都会包含 KernelSU。`packaging/kernelsu/*.patch` 保存对该检出的源码修改。

### Tools 来源

- `tools/audio`、`tools/bluetooth`：来自 [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- `tools/el2/qebspilaa64.efi`：来自 [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
- `tools/el2/slbounceaa64.efi`：来自 [TravMurav/slbounce](https://github.com/TravMurav/slbounce)
- `tools/touchscreen-tuner`：来自 [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)，本仓库对其做了 GTK4 GUI 改进

## 启动产物布局

镜像和本地安装工作流现遵循标准 `kernel-install` + BLS 流程，而非手动编写 `systemd-boot` 条目。

- BLS 条目在 Fedora 与 Ubuntu 上使用发行版名称：`loader/entries/fedora-<kernel-release>.conf` 或 `loader/entries/ubuntu-<kernel-release>.conf`。`/etc/kernel/entry-token` 持久保存名称，供升级及 initramfs 钩子读取；显式调用使用 `--entry-token=os-id`。Debian 改用 machine-id，生成 `loader/entries/<machine-id>-<kernel-release>.conf`。
- ESP 上的内核、initrd/initramfs 和 DTB 放在 `fedora/<kernel-release>/` 或 `ubuntu/<kernel-release>/`；Debian 保留 machine-id 目录名。与系统自身的 machine-id 分开。
- 迁移时保留旧的 machine-id 启动项供回退，确认新项可启动后再清理。同一 ESP 上安装两份同发行版系统时，需要不同标识。详见 [启动布局](boot-layout.md)。
- 在 `/boot` 中还会保留一份 DTB 的兼容副本，方便用户后续切换到 GRUB。
- Ubuntu DTB 安装在 `/usr/lib/linux-image-<kernel-release>/qcom/` 供 `kernel-install` 使用，另有 `/boot/dtb-<kernel-release>` 兼容副本。
- Fedora DTB 安装在 `/usr/lib/modules/<kernel-release>/dtb/qcom/` 供 `kernel-install` 使用，另有 `/boot/dtb-<kernel-release>/qcom/` 兼容副本。
- Gaokun3 镜像脚本提供 `/etc/kernel/cmdline` 和 `/etc/kernel/devicetree`，然后调用 `kernel-install add` 填充最终的 BLS 条目。

## 快速开始

- Release：<https://github.com/186526/linux-gaokun-buildbot/releases>
- 固定内核迁移记录与阻塞项：[migration.md](migration.md)
- 双系统引导指南：[English](dual_boot_guide_en.md) | [中文](dual_boot_guide_zh.md)
- EL2 实现说明：[English](el2_kvm_guide_en.md) | [中文](el2_kvm_guide_zh.md)
- Awesome Gaokun3：：[English](awesome_gaokun3_en.md) | [中文](awesome_gaokun3_zh.md)
- 历史构建指南 – Fedora 44：[English](matebook_ego_build_guide_fedora44_en.md) | [中文](matebook_ego_build_guide_fedora44_zh.md)
- 历史构建指南 – Ubuntu 26.04：[English](matebook_ego_build_guide_ubuntu26.04_en.md) | [中文](matebook_ego_build_guide_ubuntu26.04_zh.md)
- Clang/ThinLTO 构建说明：[clang-thinlto.md](clang-thinlto.md)

## 功能支持

设备硬件工作情况可参考 [right-0903/linux-gaokun 的 `## Feature Support`](https://github.com/right-0903/linux-gaokun?tab=readme-ov-file#feature-support)。

## 参考

- [186526/linux-xanmod-gaokun3](https://gitlab.com/186526/linux-xanmod-gaokun3)：`build.env` 指定的 XanMod fork；设备使能、DTS、驱动、`gaokun3_defconfig` 与 EL2 分支都由它维护，本仓库只获取并打包。
- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)：内核补丁和设备支持工作的主要来源，附有详细的提交信息和说明。
- [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun)：内核补丁和设备支持工作的另一个分支，包含触摸屏和 EC 相关的独特提交和说明。
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)：最早修复面板背光问题的仓库，包含一些额外的 Gaokun3 Linux 支持资源和修改。
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun)：为 Gaokun3 构建的多个 AUR 软件包，包括内核和固件包。
- [chenxuecong2/firmware-huawei-gaokun3](https://github.com/chenxuecong2/firmware-huawei-gaokun3)：Gaokun3 固件集合仓库。
- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)：内置 `himax_hx83121a_spi` 内核模块的上游触摸屏驱动和算法仓库。
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev)：EGoTouchRev-Linux 参考的 Windows 侧触控算法项目，也是 Gaokun3 触摸屏调参流水线的重要上游参考。
- [TravMurav/slbounce](https://github.com/TravMurav/slbounce)：在 Gaokun3 上启用 EL2 支持和安全启动的 UEFI 应用程序。
- [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd)：包含一些 sc8280xp 平台 EL2 支持补丁的 Linux 内核树。
- [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)：在高通平台上预启动 DSP 固件的 UEFI 应用程序，可在引导链中用于启动 Linux 之前。

内核逐项审计与剩余工作：[kernel-audit.md](kernel-audit.md)。
