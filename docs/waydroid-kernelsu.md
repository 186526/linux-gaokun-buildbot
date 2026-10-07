# Waydroid KernelSU 修复记录

本文记录 Gaokun3 Linux 上 Waydroid 使用 KernelSU Manager 时，`libksud.so` 被 seccomp 终止的问题及修复方法。

## 环境

目标机为 `real186@192.168.2.231`，已确认运行环境如下：

```text
Kernel:       7.2.9-gaokun3-el2-xanmod1
Architecture: aarch64
Waydroid:     Android 16 / SDK 36
Manager:      me.weishu.kernelsu v3.3.0
```

当前内核已经内建 KernelSU：

```text
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KPROBE_EVENTS=y
```

运行时还能在 `/proc/kallsyms` 中找到以下符号：

```text
kernelsu_init
ksu_supercall_handle_ioctl
ksu_seccomp_allow_cache
```

因此本问题不属于 KernelSU 内核代码未编译或 `.ko` 模块未加载。

## 故障现象

Waydroid 启动 KernelSU Manager 后，内核日志出现：

```text
comm="libksud.so"
sig=31
arch=c00000b7
syscall=142
```

进程路径为：

```text
/data/app/.../me.weishu.kernelsu/.../lib/arm64/libksud.so
```

arm64 的 syscall `142` 是 `reboot`。KernelSU 用户态通过带 KernelSU 魔数的 `reboot()` 请求内核创建 `[ksu_driver]` 文件描述符，然后通过 ioctl 与内核通信。该调用不是要真正重启主机。

## 根因

Waydroid 使用 LXC 容器级 seccomp 配置：

```text
/var/lib/waydroid/lxc/waydroid/config
```

其中指定了：

```text
lxc.seccomp.profile = /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
```

Waydroid 的 seccomp 文件原本包含：

```text
2
blacklist
...
reboot
...
```

该规则在 KernelSU 的内核 kprobe 之前拦截 `reboot()`，导致 `libksud.so` 收到 `SIGSYS`，KernelSU 无法取得驱动 fd。

需要同时区分两层过滤：

- Waydroid LXC seccomp 作用于整个容器，原始故障由这一层造成。
- Android 应用自身的 seccomp 过滤器由 Android 进程安装，KernelSU 内核代码包含对应的 seccomp allow-cache 支持。

仅将 KernelSU Manager 改为特权应用不能绕过 LXC 容器级 seccomp。

## 修复步骤

修改前应备份模板文件和当前容器文件：

```bash
stamp=$(date +%Y%m%d-%H%M%S)

sudo cp -a \
  /usr/lib/waydroid/data/configs/waydroid.seccomp \
  "/usr/lib/waydroid/data/configs/waydroid.seccomp.bak-$stamp"

sudo cp -a \
  /var/lib/waydroid/lxc/waydroid/waydroid.seccomp \
  "/var/lib/waydroid/lxc/waydroid/waydroid.seccomp.bak-$stamp"
```

只删除单独的 `reboot` 行：

```bash
sudo sed -i '/^reboot$/d' \
  /usr/lib/waydroid/data/configs/waydroid.seccomp

sudo sed -i '/^reboot$/d' \
  /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
```

确认两份文件都不再包含该规则：

```bash
grep -n '^reboot$' \
  /usr/lib/waydroid/data/configs/waydroid.seccomp \
  /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
```

命令无输出即表示修改完成。

重新创建容器进程，使新的 seccomp 配置生效：

```bash
sudo systemctl restart waydroid-container.service
sudo waydroid container stop || true
sudo waydroid container start
```

启动 Waydroid session 后再启动 KernelSU Manager：

```bash
waydroid session start
waydroid app launch me.weishu.kernelsu
```

## 验证结果

修复后重新启动 Waydroid session，内核日志不再出现新的：

```text
comm="libksud.so"
sig=31
syscall=142
```

这证明原先的 LXC seccomp 拦截路径已不再产生同样的 `SIGSYS`。它不能单独证明 KernelSU Manager 已经取得 `[ksu_driver]` 文件描述符或已经成功提供 root；完整验收还需要确认 Manager 状态、`ksud` 进程和实际 `su` 请求。

KernelSU Manager v3.3.0 发布早于 KernelSU 官方 SIGSYS 降级修复。更换包含该修复的 Manager 只能避免 `libksud.so` 因 SIGSYS 直接终止，不能替代放行 LXC `reboot` 规则，也不能单独恢复 root。

## Waydroid Manager 未识别的限制

本次目标机还确认了第二个独立问题。原运行内核的配置为：

```text
CONFIG_KSU=y
# CONFIG_KSU_DEBUG is not set
```

Manager 启动后能够加载 `libksud.so`，但内核日志仍出现：

```text
KernelSU: ksu ioctl: permission denied for cmd=0x4b01 uid=10147
```

`0x4b01` 是 `GRANT_ROOT`。这表示 `me.weishu.kernelsu` 的 appid `10147` 尚未成为 KernelSU manager，不能执行 root 操作。原运行内核没有 `ksu_debug_manager_appid` 参数，因此不能通过运行时文件权限或重装 APK 修复这个状态。

本仓库的 `scripts/ci/lib/kernelsu.sh` 和 `scripts/local/build_kernel.sh` 已经同时启用并检查：

```text
CONFIG_KSU_DEBUG=y
```

本次本地最终构建使用以下内核版本：

```text
standard: 7.2.9-gaokun3-xanmod1
EL2:      7.2.9-gaokun3-el2-ksu-dsi-fix-xanmod1
```

最终 EL2 构建已包含并编译验证以下修复链：

- XanMod `0018-drm-msm-dsi-fix-PLL-init-in-bonded-mode.patch`；
- media Venus 的 SC8280XP resource 使用修复；
- HI846、DSC interface data width 和面板方向修复；
- EL2 remoteproc `0006`、`0009`、`0010`、`0016`，以及补齐 `qcom_q6v5_read_smp2p_state()` 的 Qualcomm detached-state 前置补丁；
- `CONFIG_KSU=y`、`CONFIG_KSU_DEBUG=y`、`CONFIG_KPROBES=y`、`CONFIG_TRACEPOINTS=y`、`CONFIG_FTRACE=y`。

DEB 已在本地生成，manifest 标记为 `build_el2=true` 和 `build_kernelsu=true`。为与目标机已有同名包隔离，本次构建把 EL2 的 `LOCALVERSION` 覆盖为独立后缀，得到 release `7.2.9-gaokun3-el2-ksu-waydroidtest-xanmod1`；`scripts/ci/20_build_kernel_variants.sh` 因此新增 `KERN_LOCALVERSION_EL2` 变量，默认值保持 `-gaokun3-el2`。

该隔离 EL2 内核已安装并启动，实测结果：

- 内核配置含 `CONFIG_KSU_DEBUG=y`；`/sys/module/kernelsu/parameters/ksu_debug_manager_appid` 存在。
- 用 `lxc-attach -u <manager-appid>` 以管理器自身 UID 运行 `libksud.so debug info`，返回 `flags: 0x2`（`MANAGER` 位），说明内核已承认调用方为管理器。
- 以同一 UID 运行 `libksud.so debug su`（无参数，交互式），通过标准输入执行 `id`，输出 `uid=0(root) gid=0(root)`，内核日志同时出现 `KernelSU: allow root for: <manager-appid>`。

`debug su` 必须由管理器 UID 调用。内核 `is_manager()` 判断的是 `uid % 100000 == manager_appid`，因此以 uid 0 直接调用会被拒绝，这是 KernelSU 的正常判定，不代表失败。

管理器的图形界面在本次 Waydroid 中仍无法通过 `am start` 拉起：`Activity` 无法解析，包状态为 `stopped=true`、`notLaunched=true`，解析表内组件存在但查询无结果。该现象属于 Waydroid 侧的应用安装/包扫描状态问题，与内核 KernelSU 的识别和 root 授权是两件事，故本次以 CLI 证据作为内核能力验收。

管理器 UID 会随 APK 重装变化。使用容器命令读取，目标机的 Waydroid Python CLI 会把部分 Android 短参数错误解析为自身参数，因此使用 `lxc-attach`：

```bash
sudo lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \
  /system/bin/sh -c 'grep me.weishu.kernelsu /data/system/packages.list'
sudo cat /sys/module/kernelsu/parameters/ksu_debug_manager_appid
```

将包列表中的 appid 写入参数并重启 Manager：

```bash
sudo sh -c 'printf 10147 > /sys/module/kernelsu/parameters/ksu_debug_manager_appid'
sudo lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \
  /system/bin/am force-stop me.weishu.kernelsu
waydroid app launch me.weishu.kernelsu
```

以管理器 UID 运行 CLI，验证内核识别与实际 root：

```bash
sudo lxc-attach -P /var/lib/waydroid/lxc -n waydroid -u "$appid" -- \
  /system/bin/sh -c "$libksud debug info"
sudo lxc-attach -P /var/lib/waydroid/lxc -n waydroid -u "$appid" -- \
  /system/bin/sh -c "echo id | $libksud debug su"
```

其中 `$appid` 来自 `packages.list`，`$libksud` 是容器内 `me.weishu.kernelsu` 的 `lib/arm64/libksud.so` 绝对路径。验收标准是 `debug info` 的 `flags` 含 `0x2`，且 `debug su` 输出 `uid=0(root)`。只把 `am force-stop` 与 `waydroid app launch` 作为尝试重建管理器进程的手段；若 `Activity` 无法解析，改用上面的 CLI 直接验证内核能力，不要据此判定 KernelSU 失败。

验证内核仍然包含 KernelSU：

```bash
grep CONFIG_KSU /boot/config-$(uname -r)
grep -E 'ksu_supercall|ksu_seccomp|kernelsu_init' /proc/kallsyms
```

本次修复使用的备份后缀为：

```text
20261007-130449
```

修复后曾出现一次 `waydroid app launch` 返回 `-1`，并且 session 状态变为 `Container: FROZEN`。该现象没有伴随新的 `libksud.so` 或 syscall `142` 日志，属于 Waydroid 图形 session 或应用启动状态问题，与原始 KernelSU seccomp 拦截问题分开处理。

## 标准内核编译了 KernelSU 却不可用

目标机保留的标准内核 `7.2.9-gaokun3-xanmod1` 确实编入了 KernelSU，但不可用，原因是构建时间早于开启调试配置的提交：

```text
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_TRACEPOINTS=y
# CONFIG_KSU_DEBUG is not set
```

- 该包内 `config` 文件时间为 `2026-10-07 04:03`，而本仓库给 `scripts/ci/lib/kernelsu.sh` 打开 `CONFIG_KSU_DEBUG=y` 的提交 `1aa0b47` 时间为 `2026-10-07 14:51`。因此该内核是用“只开 `KSU`+`KPROBES`+`FTRACE`、未开 `KSU_DEBUG`”的旧配置构建的。
- 没有 `CONFIG_KSU_DEBUG` 时，`/sys/module/kernelsu/parameters/` 不存在，无法设置 `ksu_debug_manager_appid`；同时 `allow_shell` 编译期为 false，`on_post_fs_data` 触发的管理器自动加冕在这台机上从未出现（启动日志无 `Searching manager`、`Crowning manager`、`Found new base.apk`）。任何 `GRANT_ROOT`（`0x4b01`）都会返回 `permission denied`，管理器因此显示未安装，容器内也没有 `su`。

结论：这是构建配置问题，不是内核代码缺陷。用当前仓库脚本以 `BUILD_KERNELSU=true` 重新构建标准内核即可带上 `CONFIG_KSU_DEBUG=y`，再写入 `ksu_debug_manager_appid` 即可让标准内核同样识别并使用管理器。当前 `scripts/ci/lib/kernelsu.sh` 的 `configure_kernel_su` 已经会启用并断言 `CONFIG_KSU_DEBUG=y`。

## 回滚

使用实际备份后缀恢复两份文件：

```bash
stamp=20261007-130449

sudo cp -a \
  "/usr/lib/waydroid/data/configs/waydroid.seccomp.bak-$stamp" \
  /usr/lib/waydroid/data/configs/waydroid.seccomp

sudo cp -a \
  "/var/lib/waydroid/lxc/waydroid/waydroid.seccomp.bak-$stamp" \
  /var/lib/waydroid/lxc/waydroid/waydroid.seccomp

sudo systemctl restart waydroid-container.service
```

不要删除整个 seccomp 文件，也不要修改 Android 镜像中的 `/system/etc/seccomp_policy`。本次故障来自宿主机 LXC 配置中的单独 `reboot` 黑名单项。

## 参考资料

- [KernelSU `ksucalls.rs`](https://github.com/tiann/KernelSU/blob/main/userspace/ksud/src/ksucalls.rs)：用户态使用 `SYS_reboot` 获取 KernelSU 驱动 fd。
- [KernelSU `supercall.c`](https://github.com/tiann/KernelSU/blob/main/kernel/supercall/supercall.c)：内核侧处理 supercall。
- [KernelSU `setuid_hook.c`](https://github.com/tiann/KernelSU/blob/main/kernel/hook/setuid_hook.c)：Android seccomp allow-cache 处理。
- [Waydroid `waydroid.seccomp`](https://github.com/waydroid/waydroid/blob/main/data/configs/waydroid.seccomp)：Waydroid 默认 LXC seccomp 配置。
- [AOSP 原生崩溃诊断](https://source.android.com/docs/core/tests/debug/native-crash)：`SIGSYS` 和 seccomp 拦截的判定方法。
