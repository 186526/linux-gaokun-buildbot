[English](../README.md) | 中文

# linux-gaokun-buildbot

面向华为 MateBook E Go 2023（代号 `gaokun3`）、基于高通骁龙 8cx Gen3（`SC8280XP`）平台的 Linux 镜像构建脚本、工具和固件。内核源码、驱动、设备树及配置在独立的下游内核仓库维护。

**迁移草案，尚不可发布。** 内核源码在独立下游仓库 [gaokun3/linux](https://github.com/gaokun3/linux) 维护，本仓库为 [186526/linux-gaokun-buildbot](https://github.com/186526/linux-gaokun-buildbot)；Iris/Himax/EC 候选已通过完整内核编译、DEB/RPM 打包及 Fedora 镜像构建，仍待实机验收，EL2 已禁用。参见 [迁移记录与检查项](migration.md)。

`build.env` 固定内核 SHA 与发行版版本；`./build.sh kernel|debs|rpms` 是本地入口，镜像组装暂仍由 CI 执行。

## 包含内容

### 仓库结构

- `build.sh`：本地构建入口（`./build.sh kernel|debs|rpms`），读取 `build.env` 并准备固定版本的内核检出
- `build.env`：经审阅的固定构建输入（内核仓库、tag、commit、EL2 commit、发行版版本）
- `patches/`：叠加在固定内核之上的设备补丁序列，以及 `patches/kernelsu/PINNED_REVISION.md`
- `defconfig/`、`dts/`：`patches/0099` 内嵌 DTS 与 `gaokun3_defconfig` 的镜像副本（构建实际应用的是补丁，而非这两个目录）
- `docs/`：中英文使用/构建指南与平台说明
- `firmware/`：镜像构建使用的最小固件集
- `packaging/`：各发行版内核和固件包的打包模板和元数据
- `scripts/ci/`：工作流构建、镜像创建和打包脚本
- `scripts/lib/`：固定源码的准备与守卫
- `scripts/local/`：保留的设备端交互式构建脚本（旧路径）
- `tests/`：源码守卫与 `kernel-install` entry-token/BLS 行为的 Python 单元测试
- `tools/`：设备专属辅助脚本、服务文件、镜像资产和 EL2 EFI 载荷

### 软件包产物

软件包流水线会构建并安装专用软件包集：

- **Fedora (RPM)**：`kernel-gaokun3`、`kernel-modules-gaokun3`、`kernel-devel-gaokun3`、`linux-firmware-gaokun3`
- **Ubuntu (DEB)**：`linux-image-gaokun3`、`linux-modules-gaokun3`、`linux-headers-gaokun3`、`linux-firmware-gaokun3`
- **EL2 暂停构建**：等待独立迁移与验证；请求 EL2 构建会提前报错。
- Ubuntu 内核镜像包在安装/升级时运行 `update-initramfs`，进而通过发行版的 `systemd-boot` 钩子刷新 BLS 条目。
- Fedora 内核 RPM 现自带匹配的 `dracut.conf.d` 片段，并在 `%posttrans` 中运行 `dracut` + `kernel-install add`，因此安装或升级软件包会自动刷新 initramfs 和 BLS 条目。

### Release 产物

- Fedora、Debian 和 Ubuntu 镜像 release 包含压缩后的可安装镜像。
- Gaokun RPM 和 DEB release 包含镜像工作流所使用的独立内核与固件软件包集合。

### 内核补丁

固定内核已包含大部分设备使能内容，构建在其之上按序列、按文件名顺序应用剩余补丁：

- `patches/upstream/*`（`0024`、`0025`）：USB UCSI `huawei_gaokun` 端口初始化与事件处理，以及 Gaokun3 ADSP heap 与设备支持修正。
- `patches/others/*`（`0007`–`0012`）：SC8280XP 显示时钟 parking 与 rate-parent 修复、`spi-qcom-geni` 的强制 GSI 模式属性、fbdev 屏幕缓冲区虚拟化、DPU DSC 接口数据宽度，以及 `himax-hx83121a` 面板方向上报。
- `patches/media/*`（`0001`、`0004`、`0005`、`0007`）：SC8280XP Venus 资源结构，改编自 [jhovold/linux](https://github.com/jhovold/linux/commits/wip/sc8280xp-6.16) 的 Venus 系列。
- `patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch`：导入本仓库的 DTS 文件与 `gaokun3_defconfig`。该补丁自包含，是 `dts/` 与 `defconfig/` 的权威副本。
- `patches/el2/*`（`0006`、`0011`）：detached remoteproc 重启，以及 Qualcomm SCM 共享内存桥 VMID 绑定。改编自 [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd)，当前暂停。
- `patches/xanmod/*`：当以 [XanMod](https://gitlab.com/xanmod/linux) 内核作为基础（`kernel_base=xanmod`）时的本地覆盖。同名文件会替换共享补丁（例如 `patches/xanmod/0099-...`）；无共享对应项的文件（`patches/xanmod/upstream/0018-...`、`patches/xanmod/others/0018-...`、`patches/xanmod/media/0006-...`、`patches/xanmod/el2/0009,0010,0016-...`）仅在该基础下应用。`git apply --reverse --check` 成功即视为已存在于基线，会自动跳过。
- **[可选]** `patches/kernelsu/PINNED_REVISION.md`：记录固定的上游 KernelSU 版本。KernelSU 不内联；当 `BUILD_KERNELSU=true` 时，构建会克隆 `https://github.com/tiann/KernelSU.git` 的 `v3.3.0`（`932014ab5b2c9b74a3d11e2ec4d17dd10fc9442e`）并在配置前接入内核树，因此标准与 EL2 两个变体都会包含 KernelSU。

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

## 功能支持

设备硬件工作情况可参考 [right-0903/linux-gaokun 的 `## Feature Support`](https://github.com/right-0903/linux-gaokun?tab=readme-ov-file#feature-support)。

## 参考

- [gaokun3/linux](https://github.com/gaokun3/linux)：`build.env` 固定的下游内核树；设备使能、DTS、驱动与 `gaokun3_defconfig` 都由它维护，本仓库此前以补丁形式引入。
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
