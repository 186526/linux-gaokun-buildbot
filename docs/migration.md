# gaokun3 双仓库迁移记录

这是迁移候选，不能作为已验证发行版发布。内核在 XanMod 分支 [186526/linux-xanmod-gaokun3](https://gitlab.com/186526/linux-xanmod-gaokun3) 的 `gaokun3` 与 `gaokun3-el2` 分支维护，`build.env` 指定仓库与分支；buildbot 迁移位于 [186526/linux-gaokun-buildbot](https://github.com/186526/linux-gaokun-buildbot)。原仓库 PR #7 保留迁移评审记录。

## 仓库边界

- `186526/linux-xanmod-gaokun3`：XanMod 内核树，`gaokun3` 分支维护设备提交，`gaokun3-el2` 分支在其上叠加 EL2 序列；DTS、驱动、`gaokun3_defconfig` 与 `gaokun3-manifest.json` 都在内核树内。本仓库不再维护这些文件的可构建副本。
- `186526/linux-gaokun-buildbot`：Bash 构建入口、打包、镜像、固件及用户空间工具。GitHub Actions 负责调度。镜像组装仍包含工作流内联步骤，尚未全部抽成脚本。
- `patches/`、`dts/`、`defconfig/`、`drivers/` 均已删除；设备驱动、设备树与 defconfig 只在内核树内维护，以提交形式存在。补丁序列已逐条落成内核树提交，原件保留在迁移前提交 `315528c028843794ccd0f3d9dab373b03033150f`。

## 固定输入

`build.env` 是本地与 CI 共用的版本来源：

| 输入 | 当前固定值 |
| --- | --- |
| 内核仓库 | `186526/linux-xanmod-gaokun3` |
| 分支 | `KERNEL_TAG=gaokun3` |
| EL2 分支 | `KERNEL_EL2_REF=gaokun3-el2` |
| 提交固定 | `KERNEL_COMMIT`、`KERNEL_EL2_COMMIT` 留空表示跟随分支尖端 |
| Fedora / Ubuntu | 44 / 26.04 |

`scripts/ci/lib/kernel_tree.sh` 以 `git fetch --depth=1` 取 `KERNEL_TAG` 并做分离头检出，已有源码目录含本地改动时拒绝继续；设置 `KERNEL_COMMIT` 后，分支尖端与固定提交不一致会报错退出。检出后读取内核树根的 `gaokun3-manifest.json`，release 字符串、defconfig 与 DTB 名称都来自该文件。正式发布前仍需建立不可变 tag。Ubuntu rootfs 下载失败直接停止，不再回退 beta。

软件包清单记录内核 SHA 与 buildbot SHA；镜像组装核对内核 SHA，防止复用不同源码生成的软件包。

## 内核来源

内核只有一个来源：`KERNEL_REPOSITORY` 指定的 XanMod fork。`KERNEL_TAG` 既是取源码的分支或 tag，也是产物命名标签；EL2 变体固定从 `KERNEL_EL2_REF` 取到独立检出，不再对标准树打补丁。

因此全部镜像工作流与打包工作流的 dispatch 默认均为 `kernel_ref=gaokun3`、`build_el2=true`、`build_kernelsu=true`、`kernel_toolchain=clang`、`kernel_tune=sc8280xp`；只需按需关掉 `build_el2`、`build_kernelsu`，或把 `kernel_toolchain` 改回 `gcc`、`kernel_tune` 留空。

## 本地构建

安装内核构建依赖（Git、make、GCC、bc、bison、flex、OpenSSL/libelf 开发包、pahole、rsync、kmod、jq）；x86 主机还需 AArch64 交叉工具链。DEB 打包需 dpkg-dev，RPM 打包需 rpmbuild 及相应发行版工具。打包和镜像完整流程以原生 arm64 CI 为验证目标。

```bash
./build.sh kernel
./build.sh debs
./build.sh rpms
# 也可使用已有的本地内核检出：
KERNEL_SRC=/absolute/path/to/linux-xanmod-gaokun3 ./build.sh kernel
```

未设置 `KERNEL_SRC` 时，若 `~/git/linux-xanmod-gaokun3` 存在则直接复用，否则按 `KERNEL_TAG` 获取。检出含本地改动时脚本报错退出。`WORKDIR` 可更改输出目录。

## 迁移审查

- 导入原补丁作者信息。PDC 映射补丁通过反向应用确认已在基线中，单独移除；不以“冲突”判定补丁已上游。
- EC 设备树保留上游 GPIO 103 修正，对应 PDC 215。
- 根据原重启规划纠正视频路线：next 去除旧 Venus 系列，移植上游 Iris DTS 并启用 stable Iris 驱动；解码及编码均未实测。补入 right-0903 force-GSI 实现，已吸收 vahiru 的 SPI 重试和预测位置跳点修复，整体算法替换仍待审查。详见 [内核审计](kernel-audit.md)。
- `CONFIG_INPUT_UINPUT=m` 已在配置中；PR #2 的用户空间部分未在本轮引入。
- `9420138` 删除的旧 UCSI、q6apm 改动与新基线冲突，尚待语义审查；不能宣称已上游或功能等价。
- EL2 仅有部分移植工作：remoteproc 异步 attach 与 q6v5 running 状态变更需要继续审查，不能发布。EL2 序列已落成 `gaokun3-el2` 分支的提交，产物是否可用仍需实机验证。
- systemd-boot 使用 `fedora` / `ubuntu` entry token（Debian 用 machine-id）。旧 machine-id 条目保留作回退；详见 [启动布局](boot-layout.md)。

## 已验证与发布门槛

已验证：固定内核的 defconfig 生成、内核 Kbuild 设备树编译，以及 EC、电池驱动对象交叉编译；当前 Iris 全目录对象与 SPI GENI 对象交叉编译通过；Himax 对象 W=1 构建无警告，SPI 故障注入与追踪回归测试通过；systemd 255 的实际 kernel-install / BLS 插件测试通过（`tests/test_boot_entries.py`）。

当前检出是 `build.env` 指定的 `gaokun3` 与 `gaokun3-el2` 分支。此前记录的 `73033564068250603f5b2150c408554faaf22d66`（旧下游树 `gaokun3/linux`）与候选提交 `1ab894b42deae74cc72cc89f2cb436534260faed` 及其 CI 运行记录（见下）都属于迁移前，不再对应当前 `build.env`。

历史记录（迁移前候选 `1ab894b42`）：已通过完整内核及 DEB/RPM CI，并通过 Fedora 44 镜像构建；两个工作流均未发布 release。

Fedora 测试镜像为 `fedora-44-gaokun3.img.zst`，解压后的 raw 磁盘镜像为 12 GiB。它包含 EC GPIO 探测修复，替代更早用于集成验证的 `4a73e255` 镜像。

日志已确认 entry token 为 `fedora`、BLS 条目和对应 ESP 内核目录创建成功、SELinux 文件标签步骤通过。注意：镜像内核命令行并未设置 `lsm=`；`CONFIG_LSM` 默认列表里没有 `selinux`，因此 SELinux 策略不会在启动时被自动选中，仍需实机确认。Ubuntu 完整镜像及两种发行版的设备启动仍未验证；还需实测策略加载、触摸、60/120 Hz、音频、无线、蓝牙、充电、USB-C、休眠唤醒、Iris、升级和回退。

实机结果按 [验收清单](hardware-checklist.md) 记录。先完成上述检查，再合并迁移 PR、发布 release。EL2 单独推进，不作为普通内核已完成的功能。

## 构建验证

`Validate kernel packages` 在 `next` 的构建相关改动后运行，也可手动触发。它复用现有 DEB/RPM 工作流，在原生 ARM64 runner 上编译完整 Image、modules 和 DTB，然后打包。包及源码清单保存在 Actions artifacts 中 7 天。

两个打包工作流的 `publish_release` 默认 `false`。Fedora 镜像工作流同样默认不发布，可通过 `package_run_id` 下载一次打包 CI 的 RPM artifacts，也可设置 `rebuild_package_rpms` 在同一工作流重建；未指定这两项时查找既有 package release。所有路径都核对 manifest 的内核 SHA、标签及 EL2 状态。只有显式启用 `publish_release` 才发布 Fedora 镜像及本次重建的软件包。Ubuntu 镜像仍使用原有发布路径。

例如验证 Fedora 镜像：

```bash
gh workflow run fedora-gaokun3-release.yml --repo 186526/linux-gaokun-buildbot \
  -f package_run_id=PACKAGE_CI_RUN_ID -f publish_release=false
```

EL2 现在由独立的 `gaokun3-el2` 分支提供，`KERNEL_EL2_COMMIT` 只在需要固定提交时填写。镜像工作流核对 manifest 的 `kernel_tag`、`build_el2`、`build_kernelsu`；`kernel_commit` 与 `build.env` 的核对在 `KERNEL_COMMIT` 非空时执行，留空时跟随分支尖端。

Debian Trixie 镜像配合 XanMod、EL2 与 KernelSU 时，先发布对应的软件包 release，再构建镜像（镜像按 release 前缀查找软件包）：

```bash
# 1) 发布 gaokun3 + EL2 + KernelSU 的 DEB 包
gh workflow run gaokun3-package-debs.yml --repo 186526/linux-gaokun-buildbot \
  -f kernel_ref=gaokun3 \
  -f build_el2=true -f build_kernelsu=true -f publish_release=true

# 2) 用同参数构建 Debian Trixie 镜像（rebuild_package_debs=false 走 release 查找）
gh workflow run debian-gaokun3-release.yml --repo 186526/linux-gaokun-buildbot \
  -f debian_release=trixie -f kernel_ref=gaokun3 \
  -f build_el2=true -f build_kernelsu=true -f rebuild_package_debs=false
```

`kernel_ref` 必须与软件包 release 中 manifest 的 `kernel_tag` 一致；镜像任务按 `gaokun3-debs-<kernel_tag>-<profile>-<时间戳>`（profile 为 `std`，依次追加 `-el2`、`-ksu`）前缀查找，找不到即报错退出。`build_el2`、`build_kernelsu` 必须与发布时一致，否则 manifest 校验失败。注意 Debian/Ubuntu 镜像工作流的 `rebuild_package_debs=true` 路径会去 release API 下载重建的 DEB，而经 `workflow_call` 调用的打包任务默认不发布（`publish_release` 默认 `false`），因此该路径当前不可用；Fedora 工作流另有 `package_run_id` / download-artifact 步骤，不受此限。

构建成功不代表设备启动和升级测试通过。

## 2026-09-22：普通 ext4 rootfs 与启动排查

用户反馈 PLL 测试内核看起来已解决花屏，TTY 可切换，但一些服务启动失败、nmtui 不可用。本次只修改镜像构建；尚不能判断运行时服务失败的根因。

Ubuntu 与 Fedora 统一为 GPT + 1 GiB FAT32 ESP + 单个 ext4 根分区。`/home`、`/var` 都是根分区内的普通目录；Fedora 移除子卷创建、子卷挂载和 `rootflags=subvol=@`，initramfs 显式包含 ext4。Debian 仍使用 Btrfs 子卷 `@`、`@home`、`@var`。此改变仅适用于新建镜像，不会原地转换已有 Btrfs 系统。RPM 的 initramfs 配置仍包含 btrfs 驱动以支持已有安装，不再为新镜像创建 Btrfs 分卷。

已确认的问题和修正：

- PLL 测试镜像安装了 NetworkManager / wifi 插件，但未安装 NetworkManager-tui。Fedora 显式安装该包，Ubuntu 显式安装 network-manager（包含 nmtui）和 systemd-resolved。
- 两套镜像不再忽略服务 enable 的错误，明确设置 graphical.target，并在 chroot 中检查 nmcli / nmtui 存在。Ubuntu 使用 gdm3.service。
- rootfs 复制保留数字 UID/GID，排除临时运行目录内容，并将镜像根目录所有者和模式规范为 root:root / 0755，避免继承 CI staging 目录属性。

这些检查不证明服务已成功运行。旧镜像的失败原因还需要 TTY 中的 `systemctl --failed --no-pager`、`sudo journalctl -b -p warning --no-pager` 和 nmtui 的完整报错；不能把改用 ext4 等同于已修复所有启动问题。若出现 AVC 拒绝，再据实际日志修正 SELinux 标签或策略。
